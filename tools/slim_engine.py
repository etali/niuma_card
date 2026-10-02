#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""按项目能力裁剪 macOS Godot 导出模板；标准构建入口不受影响。

仅关闭已知、且扫描确认未使用的模块。核心类不做白名单裁剪：GDScript 的动态调用、
引擎内部依赖无法靠词法扫描穷举。模板、源码、Python 环境和编译中间文件都留在 build/。
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import zipfile

from engine_class_profile import disabled_classes as select_disabled_classes
from project_paths import display_path, redact_paths

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/slim-engine"
SKIP = {".git", ".godot", "build", "__pycache__", ".venv", "node_modules",
        "ref_image", "test_image", "reports", "tmp", ".DS_Store"}
SOURCE_TYPES = {".gd", ".tscn", ".tres", ".gdshader", ".gdshaderinc", ".json", ".import"}
# 未列出的引擎模块保持默认启用，避免把未知依赖猜成未使用。
MODULES = {
    "camera": (("CameraFeed", "CameraServer"), (), ()),
    "csg": (("CSG",), (), ()),
    "gridmap": (("GridMap", "MeshLibrary"), (), ()),
    "gltf": (("GLTF",), (".gltf", ".glb"), ()),
    "fbx": (("FBX",), (".fbx",), ()),
    "enet": (("ENet",), (), ()),
    "webrtc": (("WebRTC",), (), ()),
    "upnp": (("UPNP",), (), ()),
    "jsonrpc": (("JSONRPC",), (), ()),
    "regex": (("RegEx",), (), ()),
    "noise": (("Noise", "FastNoise",), (), ()),
    "interactive_music": (("AudioStreamInteractive", "AudioStreamSynchronized", "AudioStreamPlaylist"), (), ()),
    "mp3": (("AudioStreamMP3",), (".mp3",), ("load_mp3",)),
    "vorbis": (("AudioStreamOggVorbis",), (".ogg",), ("load_ogg",)),
    "theora": (("VideoStreamTheora",), (".ogv",), ()),
    "ogg": (("AudioStreamOggVorbis", "VideoStreamTheora"), (".ogg", ".ogv"), ("load_ogg",)),
    "bmp": ((), (".bmp",), ("load_bmp",)),
    "dds": ((), (".dds",), ("load_dds",)),
    "jpg": ((), (".jpg", ".jpeg"), ("load_jpg", "save_jpg")),
    "tga": ((), (".tga",), ("load_tga",)),
    "hdr": ((), (".hdr",), ("load_hdr",)),
    "tinyexr": ((), (".exr",), ("load_exr", "save_exr")),
    "ktx": ((), (".ktx",), ("load_ktx",)),
    "zip": (("ZIPReader", "ZIPPacker"), (".zip",), ("load_resource_pack",)),
    "visual_shader": (("VisualShader",), (), ()),
    "lightmapper_rd": (("LightmapGI", "LightmapProbe"), (), ()),
    # 这些与玩家拖牌使用的 PhysicsDirectSpaceState3D.intersect_ray 无关。
    "raycast": (("OccluderInstance3D", "Occluder3D", "LightmapGI"), (), ("use_occlusion_culling",)),
    "vhacd": (("MeshConvexDecompositionSettings",), (), ("convex_decompose", "create_multiple_convex_collisions")),
    "meshoptimizer": (("ImporterMesh",), (), ("optimize_indices", "generate_lods",)),
    "svg": ((), (".svg",), ("load_svg", "get_image_from_svg",)),
    # Fallback text server remains enabled even when Advanced Text Server is selected:
    # it is the safe runtime fallback for fonts/locale paths and costs little compared to
    # a broken Chinese UI.
}


class BuildError(RuntimeError):
    pass


def run(cmd, *, cwd=ROOT, env=None, capture=False):
    result = subprocess.run([str(x) for x in cmd], cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None)
    if result.returncode:
        raise BuildError(f"命令失败（{result.returncode}）：{' '.join(map(str, cmd))}\n{result.stdout or ''}")
    if capture and re.search(r"(?m)^(?:SCRIPT ERROR|ERROR):", result.stdout):
        raise BuildError(result.stdout)
    return result.stdout or ""


def project_files(root):
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not d.startswith('.'))
        for name in sorted(files):
            if name not in SKIP:
                yield Path(directory) / name


def inventory(root, capabilities):
    """游戏代码 + 被游戏实际引用的工具（包括 DebugShot），不让离线测试决定引擎能力。"""
    all_files = list(project_files(root))
    runtime = [p for p in all_files if (p.suffix in SOURCE_TYPES or p.name == 'project.godot')
               and p.relative_to(root).parts[0] not in {"tools", "tests"}]
    queue, read = list(runtime), {}
    while queue:
        path = queue.pop()
        if path in read or not path.is_file():
            continue
        text = path.read_text(encoding='utf-8', errors='replace')
        # 去掉纯注释行，保留字符串里的动态类名和资源路径。
        text = re.sub(r'(?m)^\s*#.*$', '', text)
        read[path] = text
        for ref in re.findall(r'res://([^"\s\)]+\.(?:gd|tscn|tres))', text):
            target = (root / ref).resolve()
            if target.is_relative_to(root.resolve()) and target.is_file():
                queue.append(target)
    text = '\n'.join(read.values())
    parents = capabilities['classes']
    used = set(re.findall(r'\b[A-Z][A-Za-z0-9_]*\b', text)) & set(parents)
    ancestors = set(used)
    for cls in used:
        parent = parents.get(cls)
        while parent and parent not in ancestors:
            ancestors.add(parent)
            parent = parents.get(parent)
    resources = {p.suffix.lower() for p in all_files
                 if p.relative_to(root).parts[0] not in {"tools", "tests"}}
    # 脚本也可能使用外置文件或动态组装路径，显式出现的扩展名同样保留解码器。
    resources.update(x.lower() for x in re.findall(r'\.(?:mp3|ogg|ogv|bmp|dds|jpg|jpeg|tga|hdr|exr|ktx|zip|gltf|glb|fbx)\b', text))
    digest = hashlib.sha256()
    for p, body in sorted(read.items()):
        digest.update(str(p.relative_to(root)).encode()); digest.update(body.encode())
    return {'classes': sorted(used), 'ancestors': sorted(ancestors),
            'resources': sorted(resources), 'text': text,
            'files': sorted(str(p.relative_to(root)) for p in read), 'inputs_hash': digest.hexdigest()}


def make_plan(root, capabilities, keep_modules=()):
    used = inventory(root, capabilities)
    classes, ancestors = set(used['classes']), set(used['ancestors'])
    settings = capabilities['settings']
    has_3d = bool(ancestors & {'Node3D', 'RenderingServer', 'PhysicsServer3D', 'PhysicsDirectSpaceState3D'})
    physics_3d = bool(ancestors & {'CollisionObject3D', 'Shape3D', 'PhysicsServer3D', 'PhysicsDirectSpaceState3D'})
    physics_2d = bool(ancestors & {'CollisionObject2D', 'Shape2D', 'PhysicsServer2D', 'PhysicsDirectSpaceState2D'})
    nav2 = any(x.startswith('Navigation') and '2D' in x for x in classes)
    nav3 = any(x.startswith('Navigation') and '3D' in x for x in classes)
    xr = any(x.startswith(('XR', 'OpenXR', 'WebXR')) for x in classes)
    compatibility = settings['renderer'] == 'gl_compatibility'
    physics_engine = settings.get('physics_3d', 'DEFAULT')
    options = {
        'disable_3d': not has_3d, 'disable_physics_2d': not physics_2d,
        'disable_physics_3d': not physics_3d, 'disable_navigation_2d': not nav2,
        'disable_navigation_3d': not nav3, 'disable_xr': not xr,
        # Control 基类的存在就保留全部高级UI，避免误裁选项、录像、颜色选择器。
        'disable_advanced_gui': 'Control' not in ancestors,
        'vulkan': not compatibility, 'metal': not compatibility, 'opengl3': True,
        'angle': False,  # macOS 使用原生 OpenGL，不依赖可选的 ANGLE SDK。
        # PNG 通常被编辑器导入为 WebP/CompressedTexture；字体含系统字体、变体与中文排版。
        'module_gdscript_enabled': True, 'module_webp_enabled': True,
        'module_freetype_enabled': True, 'module_text_server_adv_enabled': True,
        'accesskit': True,  # 保留现有按钮、窗口的无障碍能力。
        'sdl': any(x.startswith(('InputEventJoypad', 'Joypad')) for x in classes),
    }
    reasons = {}
    for module, (prefixes, formats, methods) in MODULES.items():
        evidence = [x for x in used['classes'] if any(x.startswith(p) for p in prefixes)]
        evidence += sorted(set(formats) & set(used['resources']))
        evidence += [name for name in methods if name in used['text']]
        enabled = bool(evidence) or module in keep_modules
        options[f'module_{module}_enabled'] = enabled
        reasons[module] = ', '.join(evidence) if evidence else ('显式保留' if enabled else '未发现相关类、资源或API')
    # 纹理的运行时编码器与 GPU/物理支持独立。只要导入配置使用VRAM/Basis或代码
    # 要求运行时压缩，就保留相关解码/编码器；WAV的compress/mode不能误算作纹理。
    texture_compressed = any(
        'importer="texture"' in (body := (root / name).read_text()) and
        re.search(r'compress/mode\s*=\s*[24]\b', body)
        for name in used['files'] if name.endswith('.import'))
    dynamic_compression = bool(re.search(r'\.(?:compress|compress_from_channels|decompress)\s*\(', used['text']))
    for module in ['astcenc', 'basis_universal']:
        enabled = bool(texture_compressed or dynamic_compression or module in keep_modules)
        options[f'module_{module}_enabled'] = enabled
        reasons[module] = '压缩纹理或运行时编码需求' if enabled else '实际纹理均为PNG/WebP无损导入，无运行时压缩'
    # etcpak试裁后可执行文件未减少，保留以免无收益地缩小可用能力。
    options['module_etcpak_enabled'] = True
    reasons['etcpak'] = '逐项实测无体积收益，保留默认能力'
    msdf = bool(re.search(r"multichannel_signed_distance_field['\"]?\s*(?:=|:|,)\s*true", used['text']) or
                re.search(r'font_set_msdf|set_multichannel_signed_distance_field', used['text']))
    options['module_msdfgen_enabled'] = msdf or 'msdfgen' in keep_modules
    reasons['msdfgen'] = 'MSDF字体配置或运行时设置' if msdf else '当前字体关闭MSDF，继续保留FreeType与高级文本排版'
    # 系统字体可能带SVG字形：显式 --keep-module svg 可保留这种扩展能力。
    network = any(x.startswith(('WebSocket', 'HTTP', 'StreamPeerTLS', 'TLSOptions')) for x in classes)
    for module in ['websocket', 'mbedtls', 'multiplayer']:
        options[f'module_{module}_enabled'] = network or module in keep_modules
        reasons[module] = '联网及 wss/TLS 支持' if network else '未发现联网使用'
    for dim, active in [('2d', physics_2d), ('3d', physics_3d)]:
        options[f'module_godot_physics_{dim}_enabled'] = active
    options['module_jolt_physics_enabled'] = physics_3d and physics_engine != 'DEFAULT'
    if physics_3d and physics_engine != 'DEFAULT':
        if 'Jolt' in physics_engine:
            options['module_godot_physics_3d_enabled'] = False
        elif 'Godot' in physics_engine:
            options['module_jolt_physics_enabled'] = False
        else:
            raise BuildError(f'未知3D物理后端：{physics_engine}，无法安全裁剪')
    # DEFAULT 对应项目当前的 Godot Physics 3D；Jolt 不参与实际运行，因此关闭。
    options['module_navigation_2d_enabled'] = nav2
    options['module_navigation_3d_enabled'] = nav3
    for module in ['openxr', 'webxr', 'mobile_vr']:
        options[f'module_{module}_enabled'] = xr
    for module in keep_modules:
        if not re.fullmatch(r'[a-z][a-z0-9_]*', module):
            raise BuildError(f'无效模块名：{module}')
        options[f'module_{module}_enabled'] = True
    return {'version': capabilities['version'], 'settings': settings,
            'scons_options': options, 'module_reasons': reasons,
            'used_classes': used['classes'], 'scanned_files': used['files'],
            'resource_formats': used['resources'], 'inputs_hash': used['inputs_hash'],
            'note': '只关闭已知未使用功能；核心类、未知模块、中文文本、PNG/WebP及无障碍依赖保留。'}


def configure_build(plan, capabilities, optimize='size', lto='full', class_trim='safe', keep_classes=()):
    if optimize not in ('size', 'size_extra') or lto not in ('thin', 'full', 'none'):
        raise BuildError('不支持的编译优化选项')
    if class_trim not in ('none', 'safe'):
        raise BuildError('不支持的类裁剪模式')
    unknown = set(keep_classes) - set(capabilities['classes'])
    if unknown:
        raise BuildError('当前引擎没有这些类：' + ', '.join(sorted(unknown)))
    plan['build_options'] = {'optimize': optimize, 'lto': lto, 'class_trim': class_trim}
    plan['disabled_classes'] = select_disabled_classes(capabilities, plan['used_classes'], keep_classes) if class_trim == 'safe' else []
    plan['keep_classes'] = sorted(keep_classes)
    return plan


def template_fingerprint(plan, arch, compiler, dirty):
    return hashlib.sha256(json.dumps({'version': plan['version'], 'options': plan['scons_options'],
        'build_options': plan.get('build_options', {'optimize': 'size', 'lto': 'thin', 'class_trim': 'none'}),
        'disabled_classes': plan.get('disabled_classes', []),
        'arch': arch, 'compiler': compiler, 'diff': dirty, 'format': 2}, sort_keys=True).encode()).hexdigest()[:20]


def discover(godot, root):
    with tempfile.TemporaryDirectory(prefix='card-engine-survey-') as tmp:
        output = Path(tmp) / 'capabilities.json'
        env = dict(os.environ, CARD_ENGINE_CAPABILITIES=str(output))
        run([godot, '--headless', '--path', root, '--script', 'tools/engine_capabilities.gd'], env=env, cwd=root, capture=True)
        if not output.exists():
            raise BuildError('Godot 没有生成能力清单，停止裁剪')
        return json.loads(output.read_text())


def preset_section(text):
    for match in re.finditer(r'(?ms)^\[(preset\.\d+)\]\n(.*?)(?=^\[|\Z)', text):
        if re.search(r'^name="macOS"$', match[2], re.M):
            return match[1]
    raise BuildError('export_presets.cfg 缺少 macOS 预设')


def preset_value(text, section, key):
    part = re.search(r'(?ms)^\[' + re.escape(section) + r'\]\n(.*?)(?=^\[|\Z)', text)
    found = re.search(r'^' + re.escape(key) + r'=(.*)$', part[1], re.M) if part else None
    if not found:
        raise BuildError(f'导出预设缺少 {section}/{key}')
    return json.loads(found[1])


def patch_preset(text, section, values):
    pattern = r'(?ms)(^\[' + re.escape(section) + r'\]\n)(.*?)(?=^\[|\Z)'
    def replace(match):
        body = match[2]
        for key, value in values.items():
            line = f'{key}={json.dumps(value, ensure_ascii=False)}'
            rx = r'(?m)^' + re.escape(key) + r'=.*$'
            body = re.sub(rx, lambda _: line, body) if re.search(rx, body) else body.rstrip() + '\n' + line + '\n\n'
        return match[1] + body
    patched, count = re.subn(pattern, replace, text)
    if count != 1:
        raise BuildError(f'找不到唯一导出选项段：{section}')
    return patched


def write_plan(plan, directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'analysis.json').write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n')
    profile = {'type': 'build_profile', 'disabled_classes': plan.get('disabled_classes', []),
               'disabled_build_options': {k: v for k, v in plan['scons_options'].items() if k.startswith('disable_')}}
    (directory / 'game.build').write_text(json.dumps(profile, ensure_ascii=False, indent=2) + '\n')
    print(f"扫描 {len(plan['scanned_files'])} 个代码/配置文件，发现 {len(plan['used_classes'])} 个原生类", flush=True)
    print('保留：3D牌桌/物理、中文文本、高级UI、WebSocket/TLS及无障碍（以清单检测值为准）', flush=True)
    print('关闭：' + ', '.join(k.removeprefix('module_').removesuffix('_enabled') for k,v in plan['scons_options'].items() if k.startswith('module_') and not v), flush=True)
    settings = plan.get('build_options', {'optimize': 'size', 'lto': 'thin', 'class_trim': 'none'})
    print(f"编译优化：{settings['optimize']} / LTO {settings['lto']}；类裁剪 {len(plan.get('disabled_classes', []))} 个", flush=True)
    print(f'裁剪清单：{display_path(directory / "analysis.json")}\n构建配置：{display_path(directory / "game.build")}', flush=True)


def check_toolchain():
    if sys.platform != 'darwin':
        raise BuildError('该入口目前构建 macOS 模板，请在 macOS 上运行')
    for command in ['git', 'xcrun', 'lipo']:
        if not shutil.which(command):
            raise BuildError(f'缺少 {command}；请安装 Xcode Command Line Tools')
    supplied = bool(os.environ.get('CXX') or os.environ.get('CC'))
    compiler = os.environ.get('CXX') or os.environ.get('CC') or 'clang++'
    output = run([compiler, '--version'], capture=True)
    apple = re.search(r'Apple clang version (\d+)', output)
    # 当前 Godot 4.7.1 的 SConstruct 拒绝 Apple Clang <16；如果用户明确指定
    # 另一套 C/C++ 工具链，则交给匹配源码继续校验其版本，避免误挡 Homebrew LLVM。
    if apple and int(apple[1]) < 16 and not supplied:
        raise BuildError(f'当前 Apple Clang {apple[1]}，精简引擎需要 Xcode 16 或更新的工具链。'
                         '\n请更新后重试，或设置 CXX=/path/to/clang++、CC=/path/to/clang。'
                         '\n裁剪清单已生成，原 App 和标准构建方式未改动。')
    run(['xcrun', '--show-sdk-path'], capture=True)
    return output.strip()


def acquire_source(version, supplied, cache):
    commit = str(version['hash'])
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise BuildError('当前编辑器没有可验证的源码提交号，不能猜测匹配的导出模板版本')
    source = supplied.resolve() if supplied else cache / 'source' / commit
    if not (source / 'SConstruct').exists():
        if supplied:
            raise BuildError(f'指定目录不是 Godot 源码：{source}')
        source.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='download-', dir=source.parent) as tmp:
            checkout = Path(tmp) / 'godot'
            checkout.mkdir()
            run(['git', 'init', checkout])
            run(['git', '-C', checkout, 'remote', 'add', 'origin', 'https://github.com/godotengine/godot.git'])
            run(['git', '-C', checkout, 'fetch', '--depth', '1', 'origin', commit])
            run(['git', '-C', checkout, 'checkout', '--detach', 'FETCH_HEAD'])
            checkout.rename(source)
    head = run(['git', '-C', source, 'rev-parse', 'HEAD'], capture=True).strip()
    if head != commit:
        raise BuildError(f'源码提交 {head} 与编辑器 {commit} 不一致，不能使用这个模板')
    # 裁剪参数必须真的被当前源码支持，不让 SCons 静默忽略拼错的选项。
    return source


def registered_options(source):
    """只认源码实际声明的构建选项；注释、变量引用不能证明某个参数受支持。"""
    names = set()
    for path in [source / 'SConstruct', source / 'platform/macos/detect.py']:
        if not path.is_file():
            continue
        tree = ast.parse(path.read_text(), filename=str(path))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not node.args:
                continue
            function = node.func
            is_variable = isinstance(function, ast.Name) and function.id in {
                'BoolVariable', 'EnumVariable', 'PathVariable', 'ListVariable', 'PackageVariable'}
            is_add = isinstance(function, ast.Attribute) and function.attr == 'Add' and \
                isinstance(function.value, ast.Name) and function.value.id == 'opts'
            if (is_variable or is_add) and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                names.add(node.args[0].value)
    return names


def validate_options(source, options):
    supported = registered_options(source)
    invalid = []
    for key in options:
        if key.startswith('module_') and key.endswith('_enabled'):
            name = key[7:-8]
            if not (source / 'modules' / name / 'config.py').exists():
                invalid.append(key)
        elif key not in supported:
            invalid.append(key)
    if invalid:
        raise BuildError('匹配源码未声明以下构建参数：' + ', '.join(invalid) + '；请更新裁剪规则，不能静默忽略')


def python_for_scons(cache):
    python = cache / 'python/bin/python3'
    if not python.exists():
        run([sys.executable, '-m', 'venv', cache / 'python'])
    probe = subprocess.run([python, '-c', 'import SCons'], capture_output=True)
    if probe.returncode:
        run([python, '-m', 'pip', 'install', 'scons==4.9.1'])
    return python


def package_template(base, binary, destination, arch):
    executable = f'macos_template.app/Contents/MacOS/godot_macos_release.{arch}'
    with zipfile.ZipFile(base) as src, zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as out:
        original = 'macos_template.app/Contents/MacOS/godot_macos_release.universal'
        if original not in src.namelist():
            raise BuildError(f'标准 macOS 模板结构不匹配：{base}')
        for entry in src.infolist():
            if '/Contents/MacOS/' in entry.filename and not entry.is_dir():
                continue
            out.writestr(entry, src.read(entry))
        info = zipfile.ZipInfo(executable)
        info.external_attr = (stat.S_IFREG | 0o755) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        out.writestr(info, binary.read_bytes())


def build_template(plan, source, arch, jobs, cache, compiler, rebuild):
    validate_options(source, plan['scons_options'])
    dirty = run(['git', '-C', source, 'diff', 'HEAD'], capture=True)
    fingerprint = template_fingerprint(plan, arch, compiler, dirty)
    output = cache / 'templates' / fingerprint
    template = output / 'macos.zip'
    stamp = output / 'complete.json'
    if template.exists() and stamp.exists() and not rebuild:
        saved = json.loads(stamp.read_text())
        if saved.get('sha256') == hashlib.sha256(template.read_bytes()).hexdigest():
            print(f'使用已验证模板缓存：{display_path(template)}', flush=True)
            return template
    output.mkdir(parents=True, exist_ok=True)
    write_plan(plan, output)
    python = python_for_scons(cache)
    if plan['scons_options']['accesskit']:
        installer = source / 'misc/scripts/install_accesskit.py'
        if not installer.exists():
            raise BuildError('匹配源码缺少 AccessKit 安装工具，不能静默移除无障碍支持')
        run([python, installer], cwd=source)
    options = [f'{key}={"yes" if value else "no"}' for key,value in sorted(plan['scons_options'].items())]
    variants = ['arm64', 'x86_64'] if arch == 'universal' else [arch]
    settings = plan.get('build_options', {'optimize': 'size', 'lto': 'thin'})
    binaries = []
    for variant in variants:
        cmd = [python, '-m', 'SCons', f'-j{jobs}', 'platform=macos', 'target=template_release',
               f'arch={variant}', f"optimize={settings['optimize']}", f"lto={settings['lto']}", 'debug_symbols=no',
               f'build_profile={output / "game.build"}', *options]
        for key in ['CC', 'CXX']:
            if os.environ.get(key):
                cmd.append(f'{key}={os.environ[key]}')
        print(f'编译 {variant} 精简导出模板（首次需要较长时间）', flush=True)
        run(cmd, cwd=source)
        binary = source / f'bin/godot.macos.template_release.{variant}'
        if not binary.is_file():
            raise BuildError(f'编译没有生成预期二进制：{binary}')
        binaries.append(binary)
    combined = output / 'godot_macos_release.universal'
    if len(binaries) == 2:
        run(['lipo', '-create', *binaries, '-output', combined])
    else:
        shutil.copy2(binaries[0], combined)
    # 使用当前已安装模板的打包骨架；不替换用户的全局导出模板。
    v = plan['version']
    folder = f"{v['major']}.{v['minor']}.{v['patch']}.{v['status']}"
    base = Path.home() / 'Library/Application Support/Godot/export_templates' / folder / 'macos.zip'
    if not base.exists():
        raise BuildError(f'缺少匹配版本标准模板的 App 骨架：{base}')
    temporary = output / 'macos.partial.zip'
    package_template(base, combined, temporary, arch)
    temporary.replace(template)
    stamp.write_text(json.dumps({'sha256': hashlib.sha256(template.read_bytes()).hexdigest(), 'arch': arch}))
    print(f'精简模板已生成：{display_path(template)}（二进制 {combined.stat().st_size / 1048576:.1f} MiB）', flush=True)
    return template


def export_project(root, godot, template, arch, cache):
    """在隔离副本导出：导出预设、字体事务及导入缓存均不改写工作区。"""
    preset = (root / 'export_presets.cfg').read_text()
    section = preset_section(preset)
    target_relative = Path(preset_value(preset, section, 'export_path'))
    if target_relative.is_absolute() or '..' in target_relative.parts or target_relative.parts[0] != 'build':
        raise BuildError('macOS 输出必须在项目 build/ 下')
    with tempfile.TemporaryDirectory(prefix='export-', dir=cache) as tmp:
        stage = Path(tmp) / 'project'
        shutil.copytree(root, stage, ignore=lambda _path,names: [x for x in names if x in SKIP])
        (stage / 'export_presets.cfg').write_text(patch_preset(preset, section + '.options', {
            'custom_template/release': str(template.resolve()), 'binary_format/architecture': arch}))
        env = dict(os.environ, GODOT=str(godot))
        run(['bash', stage / '构建游戏.command'], cwd=stage, env=env)
        app = stage / target_relative
        executables = app / 'Contents/MacOS'
        if not executables.is_dir() or not any(p.stat().st_size for p in executables.iterdir() if p.is_file()):
            raise BuildError('导出没有生成可运行 App，保留原 App')
        from release_audit import audit
        checked = audit(app)
        expected_arches = {'arm64', 'x86_64'} if arch == 'universal' else {arch}
        if set(checked['architectures']) != expected_arches:
            raise BuildError(f"导出架构不完整：期望{sorted(expected_arches)}，实际{checked['architectures']}")
        checked.pop('pck_files')
        # 在替换原App前实际加载一次已导出的PCK；漏裁模块常表现为退出码0的脚本错误。
        executable = next(p for p in executables.iterdir() if p.is_file())
        smoke = run([executable, '--headless', '--quit-after', '30'], cwd=stage, capture=True)
        checked['native_startup_verified'] = 'Godot Engine' in smoke
        if not checked['native_startup_verified']:
            raise BuildError('精简App没有完成启动验证，保留原App')
        (root / 'build').mkdir(exist_ok=True)
        (root / 'build/release-audit.json').write_text(json.dumps(checked, ensure_ascii=False, indent=2) + '\n')
        destination = root / target_relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        old = Path(tmp) / 'previous.app'
        if destination.exists():
            destination.rename(old)
        try:
            shutil.move(str(app), destination)
        except BaseException:
            if old.exists():
                old.rename(destination)
            raise
        shutil.copy2(cache / 'analysis.json', root / 'build/slim-engine-build.json')
        print(f'精简构建完成：{display_path(destination)}', flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--slim-engine', '--slim', action='store_true')
    parser.add_argument('--engine-plan', action='store_true', help='只生成本地裁剪清单，不下载或编译')
    parser.add_argument('--godot', default=os.environ.get('GODOT', '/Applications/Godot.app/Contents/MacOS/Godot'))
    parser.add_argument('--source', type=Path, help='匹配当前编辑器提交号的 Godot Git 源码目录')
    parser.add_argument('--arch', choices=['arm64', 'x86_64', 'universal'])
    parser.add_argument('--optimize', choices=['size', 'size_extra'], default='size')
    parser.add_argument('--lto', choices=['thin', 'full', 'none'], default='full', help='默认full：已实测的体积/性能平衡')
    parser.add_argument('--class-trim', choices=['none', 'safe'], default='safe', help='保守裁剪未使用的节点族')
    parser.add_argument('--keep-class', action='append', default=[], help='保留动态使用的类及其父类')
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 2, 8))
    parser.add_argument('--keep-module', action='append', default=[], help='为动态加载等场景显式保留模块')
    parser.add_argument('--rebuild-engine', action='store_true', help='不使用已打包模板缓存，重新运行编译')
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error('--jobs 必须大于0')
    if not args.slim_engine and not args.engine_plan:
        parser.error('请选择 --slim-engine 或 --engine-plan')
    try:
        godot = Path(args.godot).expanduser().resolve()
        if not godot.is_file():
            raise BuildError(f'找不到 Godot：{godot}')
        # 直接调用此Python入口也不能把下载到build内的引擎当成项目资源。
        (ROOT / 'build').mkdir(exist_ok=True)
        (ROOT / 'build/.gdignore').touch(exist_ok=True)
        capabilities = discover(godot, ROOT)
        version = capabilities['version']
        if int(version['major']) != 4 or int(version['minor']) < 5:
            raise BuildError('此裁剪配置面向项目使用的 Godot 4.5+；其他版本需要重新核对构建选项')
        plan = make_plan(ROOT, capabilities, args.keep_module)
        configure_build(plan, capabilities, args.optimize, args.lto, args.class_trim, args.keep_class)
        preset = (ROOT / 'export_presets.cfg').read_text()
        arch = args.arch or preset_value(preset, preset_section(preset) + '.options', 'binary_format/architecture')
        if arch not in ['arm64', 'x86_64', 'universal']:
            raise BuildError(f'不支持的导出架构：{arch}')
        plan['architecture'] = arch
        write_plan(plan, CACHE)
        if args.engine_plan:
            return 0
        compiler = check_toolchain()
        source = acquire_source(version, args.source, CACHE)
        template = build_template(plan, source, arch, args.jobs, CACHE, compiler, args.rebuild_engine)
        export_project(ROOT, godot, template, arch, CACHE)
        return 0
    except (BuildError, OSError, ValueError, KeyError) as error:
        print(redact_paths(f'精简构建失败：{error}'), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('精简构建已中断，原构建配置未改写。', file=sys.stderr)
        return 130


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
