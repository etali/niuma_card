#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""在 macOS 上安装本项目 Android 构建依赖并配置 Godot。

安装范围：
- Android command-line tools
- platform-tools（adb）
- Android Platform 和 Build Tools（版本读取匹配 Godot 的源码模板）
- JDK 17（优先现有 JAVA_HOME，否则下载 Amazon Corretto）
- 与当前 Godot 版本匹配的 Android Export Template

所有下载和命令都显示在终端；失败时保留日志并返回非零退出码。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shlex
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import xml.etree.ElementTree as ET

from project_paths import redact_paths

ROOT = Path(__file__).resolve().parents[1]
GODOT_DEFAULT = "/Applications/Godot.app/Contents/MacOS/Godot"
ANDROID_SDK_DEFAULT = Path.home() / "Library/Android/sdk"
CMDLINE_XML = "https://dl.google.com/android/repository/repository2-3.xml"


class InstallError(RuntimeError):
    pass


def log(message: str) -> None:
    print(redact_paths(f"[Android] {message}", ROOT), flush=True)


def run(command: list[str], *, env: dict[str, str] | None = None,
        input_text: str | None = None, check: bool = True,
        timeout: float = 90) -> subprocess.CompletedProcess[str]:
    log("执行：" + shlex.join(command))
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, input=input_text,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout)
    except OSError as error:
        raise InstallError(f"无法启动 {command[0]}：{error}") from error
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        print(redact_paths(output.decode(errors="replace") if isinstance(output, bytes) else output, ROOT), flush=True)
        raise InstallError(f"命令超过 {timeout:g} 秒未完成：{command[0]}") from error
    if result.stdout:
        print(redact_paths(result.stdout, ROOT), end="", flush=True)
    if check and result.returncode != 0:
        raise InstallError(f"命令失败（退出码 {result.returncode}）：{command[0]}")
    return result


def download(url: str, destination: Path, checksum: str = "", algorithm: str = "sha1",
             size: int = 0) -> None:
    """实时显示 curl 进度；保留 .part，只有完整校验通过才提交缓存文件。"""
    destination.parent.mkdir(parents=True, exist_ok=True)
    def verified(path: Path) -> bool:
        if not path.is_file() or not path.stat().st_size or (size and path.stat().st_size != size):
            return False
        if checksum:
            digest = hashlib.new(algorithm)
            with path.open("rb") as file:
                for block in iter(lambda: file.read(1024 * 1024), b""):
                    digest.update(block)
            return digest.hexdigest().lower() == checksum.lower()
        return True
    if checksum and verified(destination):
        log(f"复用已校验下载：{destination.name}")
        return
    curl = shutil.which("curl")
    if not curl:
        raise InstallError("找不到 macOS curl")
    partial = destination.with_name(destination.name + ".part")
    log(f"下载：{url}")
    command = [curl, "--fail", "--location", "--progress-bar", "--retry", "2",
               "--retry-delay", "2", "--connect-timeout", "15", "--max-time", "1800",
               "--speed-limit", "1024", "--speed-time", "60"]
    if partial.exists() and partial.stat().st_size:
        command += ["--continue-at", "-"]
    command += ["--output", str(partial), url]
    try:
        # 保留实时进度，工具报错中的本机路径在写入终端/构建日志前脱敏。
        with subprocess.Popen(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT) as process:
            try:
                for line in process.stdout:
                    print(redact_paths(line, ROOT), end="", flush=True)
                returncode = process.wait()
            except BaseException:
                process.kill()
                process.wait()
                raise
    except OSError as error:
        raise InstallError(f"无法启动 curl：{error}") from error
    if returncode:
        raise InstallError(f"下载失败（退出码 {returncode}）：{url}；已下载部分保留在 {partial}")
    if not verified(partial):
        partial.unlink(missing_ok=True)
        raise InstallError(f"下载大小或校验和不匹配：{url}")
    partial.replace(destination)


def godot_version(godot: Path) -> tuple[str, str]:
    text = run([str(godot), "--version"], timeout=20).stdout
    match = re.search(r"(?m)^(\d+\.\d+\.\d+)\.stable(?:\.|$)", text)
    if not match:
        raise InstallError(f"需要可识别的 Godot stable 版本，不能猜测导出模板版本：{text.strip()}")
    return match[1], match[1] + ".stable"


def java_major(java: Path) -> int | None:
    try:
        result = subprocess.run([str(java), "-version"], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.search(r'version "(\d+)[."]', result.stdout)
    return int(match[1]) if result.returncode == 0 and match else None


def find_java() -> Path | None:
    candidates: list[Path] = []
    java_home = os.environ.get("JAVA_HOME", "")
    if java_home:
        candidates.append(Path(java_home) / "bin/java")
    which = shutil.which("java")
    if which:
        candidates.append(Path(which))
    candidates.extend(Path("/Library/Java/JavaVirtualMachines").glob("*/Contents/Home/bin/java"))
    candidates.extend(Path.home().glob("Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java"))
    for candidate in candidates:
        if candidate.is_file() and java_major(candidate) == 17:
            return candidate
    return None


def java_home_from(java: Path) -> Path:
    resolved = java.resolve()
    if resolved.parts[-2:] == ("bin", "java"):
        return resolved.parent.parent
    return Path(os.environ.get("JAVA_HOME", ""))


def install_java(destination: Path, dry_run: bool) -> Path:
    existing = find_java()
    if existing:
        log(f"复用 JDK 17：{java_home_from(existing)}")
        return java_home_from(existing)
    # 当前网络无法访问 GitHub 时，不走 Homebrew cask；使用 Amazon Corretto 的 CloudFront 直链。
    if dry_run:
        log(f"将下载 Amazon Corretto 17 到：{destination}")
        return destination
    arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x64"
    urls = [
        f"https://corretto.aws/downloads/latest/amazon-corretto-17-{arch}-macos-jdk.tar.gz",
        f"https://api.adoptium.net/v3/binary/latest/17/ga/mac/{arch}/jdk/hotspot/normal/eclipse",
    ]
    last_error = None
    with tempfile.TemporaryDirectory(prefix="card-combine-jdk-") as temp:
        archive = Path(temp) / "jdk.tar.gz"
        for url in urls:
            try:
                download(url, archive)
                break
            except InstallError as error:
                last_error = error
                archive.unlink(missing_ok=True)
        else:
            raise InstallError(f"JDK 下载失败；已尝试 Amazon Corretto 和 Adoptium。\n{last_error}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        extracted = Path(temp) / "extracted"
        extracted.mkdir()
        with tarfile.open(archive, "r:gz") as tar:
            tar.extractall(extracted)
        homes = sorted(extracted.glob("*/Contents/Home"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not homes:
            raise InstallError("JDK 压缩包中没有找到 Contents/Home")
        home = homes[0]
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(home, destination)
    java = destination / "bin/java"
    if java_major(java) != 17:
        raise InstallError(f"安装后 JDK 版本不正确：{destination}")
    return destination


MACHO_MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def _is_macos_tool(path: Path) -> bool:
    if not path.is_file():
        return False
    with path.open("rb") as file:
        header = file.read(4)
    return header.startswith(b"#!") or header in MACHO_MAGIC


def _repair_android_tool_permissions(directory: Path, dry_run: bool = False) -> None:
    if not directory.is_dir():
        return
    repaired = []
    for tool in directory.rglob("*"):
        if tool.is_symlink() or not tool.is_file() or not _is_macos_tool(tool):
            continue
        if not tool.stat().st_mode & stat.S_IXUSR:
            if not dry_run:
                tool.chmod(tool.stat().st_mode | 0o111)
            repaired.append(tool.name)
    if repaired:
        log(("将修复" if dry_run else "已修复") + "执行权限：" + ", ".join(sorted(repaired)))


def sdkmanager(sdk: Path, dry_run: bool = False) -> Path:
    for relative in ["cmdline-tools/latest/bin", "cmdline-tools/bin"]:
        candidate = sdk / relative / "sdkmanager"
        if not candidate.is_file():
            continue
        native = candidate.parent / "android"
        if not _is_macos_tool(candidate) or (native.exists() and not _is_macos_tool(native)):
            raise InstallError(f"command-line tools 含非 macOS 工具：{candidate.parent}")
        _repair_android_tool_permissions(candidate.parent.parent, dry_run)
        return candidate
    raise InstallError(f"找不到 sdkmanager：{sdk}/cmdline-tools/latest/bin/sdkmanager")


def _repository_package(root: ET.Element, package_path: str) -> dict | None:
    # Google 把 host-os / host-arch 放在 archive 下，与 complete 同级。
    # 统一选择逻辑供 command-line tools、platform-tools、build-tools 共用。
    for node in root.iter():
        node.tag = node.tag.rsplit("}", 1)[-1]
    for package in root.findall(".//remotePackage"):
        if package.get("path") != package_path or package.find("obsolete") is not None:
            continue
        candidates = []
        native_arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
        for archive in package.findall("./archives/archive"):
            complete = archive.find("complete")
            if complete is None or not complete.findtext("url"):
                continue
            host_os = (archive.findtext("host-os") or "").lower()
            host_arch = (archive.findtext("host-arch") or "").lower()
            if host_os not in ("", "macosx", "macos", "darwin"):
                continue
            if host_arch in ("arm64", "aarch64") and native_arch != "aarch64":
                continue
            score = (2 if host_os else 0) + (1 if host_arch == native_arch else 0)
            checksum = complete.find("checksum")
            data = {"url": "https://dl.google.com/android/repository/" + complete.findtext("url"),
                    "checksum": (checksum.text or "").strip() if checksum is not None else "",
                    "algorithm": checksum.get("type", "sha1") if checksum is not None else "sha1",
                    "size": int(complete.findtext("size", "0")), "element": package}
            candidates.append((score, data))
        if candidates:
            return max(candidates, key=lambda item: item[0])[1]
    return None


def _repository_url(root: ET.Element, package_path: str) -> str | None:
    package = _repository_package(root, package_path)
    return package["url"] if package else None


def _extract_zip(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as zipped:
        for info in zipped.infolist():
            target = (destination / info.filename).resolve()
            if not target.is_relative_to(destination.resolve()) or stat.S_ISLNK(info.external_attr >> 16):
                raise InstallError(f"压缩包含不安全路径：{info.filename}")
        for info in zipped.infolist():
            zipped.extract(info, destination)
            path = destination / info.filename
            if path.is_file():
                mode = (info.external_attr >> 16) & 0o777
                if mode:
                    path.chmod(mode)
    _repair_android_tool_permissions(destination)


def _replace_directory(source: Path, destination: Path) -> None:
    # 所有下载/解压/平台校验结束之后，才替换上次安装，失败时保留原目录。
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".android-install-", dir=destination.parent) as temp:
        staged, backup = Path(temp) / "new", Path(temp) / "old"
        shutil.copytree(source, staged)
        if destination.exists():
            destination.rename(backup)
        try:
            staged.rename(destination)
        except BaseException:
            if backup.exists():
                backup.rename(destination)
            raise


def _extract_sdk_archive(archive: Path, destination: Path, marker: str) -> None:
    with tempfile.TemporaryDirectory(prefix="card-combine-sdk-package-") as temp:
        extracted = Path(temp) / "extracted"
        extracted.mkdir()
        _extract_zip(archive, extracted)
        matches = list(extracted.rglob(marker))
        if len(matches) != 1:
            raise InstallError(f"SDK 压缩包必须包含唯一 {marker}：{archive}")
        source = matches[0].parent
        if marker in ("adb", "apksigner", "sdkmanager") and not _is_macos_tool(source / marker):
            raise InstallError(f"SDK 压缩包不是 macOS 版本：{marker}")
        for binary in ["android", "aapt2", "zipalign", "adb"]:
            if (source / binary).exists() and not _is_macos_tool(source / binary):
                raise InstallError(f"SDK 压缩包不是 macOS 版本：{binary}")
        _replace_directory(source, destination)


def _read_repository() -> ET.Element:
    path = ROOT / "build/android-downloads/repository.xml"
    download(CMDLINE_XML, path)
    return ET.parse(path).getroot()


def _download_sdk_package(repository: ET.Element, package_path: str) -> Path:
    data = _repository_package(repository, package_path)
    if not data:
        raise InstallError(f"Google 仓库缺少适用 macOS 的包：{package_path}（不会回退到 Linux）")
    archive = ROOT / "build/android-downloads" / data["url"].rsplit("/", 1)[-1]
    download(data["url"], archive, data["checksum"], data["algorithm"], data["size"])
    return archive


def install_cmdline_tools(sdk: Path, dry_run: bool, repository: ET.Element | None = None) -> Path:
    try:
        return sdkmanager(sdk, dry_run)
    except InstallError as error:
        log(f"需要安装 macOS command-line tools：{error}")
    target = sdk / "cmdline-tools/latest"
    if dry_run:
        log(f"将安装 macOS command-line tools：{target}")
        return target / "bin/sdkmanager"
    root = repository if repository is not None else _read_repository()
    archive = _download_sdk_package(root, "cmdline-tools;latest")
    with tempfile.TemporaryDirectory(prefix="card-combine-cmdline-") as temp:
        extracted = Path(temp)
        _extract_zip(archive, extracted)
        source = extracted / "cmdline-tools"
        # 放入临时SDK树后复用同一校验，不把旧安装当作解压目标。
        staged = extracted / "sdk/cmdline-tools/latest"
        staged.parent.mkdir(parents=True)
        shutil.move(str(source), staged)
        sdkmanager(extracted / "sdk")
        _replace_directory(staged, target)
    return sdkmanager(sdk)


def _write_android_licenses(sdk: Path, repository: ET.Element, packages: list[str]) -> None:
    # 根据本次官方清单的许可内容保留指纹，不覆盖此前接受的许可证记录。
    for name in packages:
        package = _repository_package(repository, name)
        reference = package["element"].find("uses-license") if package else None
        if reference is None:
            continue
        license_id = reference.get("ref", "")
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", license_id):
            raise InstallError(f"无效许可标识：{license_id}")
        license_node = next((n for n in repository.iter("license") if n.get("id") == license_id), None)
        if license_node is None:
            raise InstallError(f"仓库清单缺少许可证：{license_id}")
        text = "".join(license_node.itertext()).strip()
        fingerprint = hashlib.sha1(text.encode()).hexdigest()
        path = sdk / "licenses" / license_id
        previous = path.read_text() if path.exists() else ""
        if fingerprint not in previous.splitlines():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(previous.rstrip() + "\n" + fingerprint + "\n")


def _sdk_package_is_macos(destination: Path, package_path: str) -> bool:
    if package_path == "platform-tools":
        return _is_macos_tool(destination / "adb")
    if package_path.startswith("build-tools;"):
        return all(_is_macos_tool(destination / name) for name in ["apksigner", "aapt2", "zipalign"])
    return (destination / "android.jar").is_file()


def sdk_environment(sdk: Path, java_home: Path) -> dict[str, str]:
    env = dict(os.environ, JAVA_HOME=str(java_home), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    env["PATH"] = os.pathsep.join([str(java_home / "bin"), str(sdk / "platform-tools"),
                                  str(sdk / "cmdline-tools/latest/bin"), env.get("PATH", "")])
    return env


def install_sdk_packages(manager: Path, sdk: Path, api: str, build_tools: str,
                         dry_run: bool, java_home: Path, repository: ET.Element | None = None) -> None:
    specs = [("platform-tools", sdk / "platform-tools", "adb"),
             (f"platforms;android-{api}", sdk / "platforms" / f"android-{api}", "android.jar"),
             (f"build-tools;{build_tools}", sdk / "build-tools" / build_tools, "apksigner")]
    if dry_run:
        log("将检查/安装 SDK 包：" + ", ".join(item[0] for item in specs))
        return
    root = repository if repository is not None else _read_repository()
    for package_path, destination, marker in specs:
        if _sdk_package_is_macos(destination, package_path):
            _repair_android_tool_permissions(destination)
            log(f"复用 SDK 包：{package_path}")
        else:
            archive = _download_sdk_package(root, package_path)
            _extract_sdk_archive(archive, destination, marker)
            if not _sdk_package_is_macos(destination, package_path):
                raise InstallError(f"SDK 包校验失败：{package_path}")
    _write_android_licenses(sdk, root, [item[0] for item in specs])


def verify_tools(sdk: Path, java_home: Path, build_tools: str) -> None:
    env = sdk_environment(sdk, java_home)
    for command in [[java_home / "bin/java", "-version"],
                    [sdkmanager(sdk), "--version"],
                    [sdk / "platform-tools/adb", "version"],
                    [sdk / f"build-tools/{build_tools}/apksigner", "version"],
                    [sdk / f"build-tools/{build_tools}/aapt2", "version"]]:
        run([str(x) for x in command], env=env, timeout=25)
    # zipalign 不支持 --version，无参数时输出帮助并返回2，借此验证它真能执行。
    result = run([str(sdk / f"build-tools/{build_tools}/zipalign")], env=env, check=False, timeout=15)
    if result.returncode not in (0, 2) or "zipalign" not in result.stdout.lower():
        raise InstallError("zipalign 未通过执行校验")


def install_export_template(godot: Path, version: str, version_folder: str, dry_run: bool) -> None:
    templates = Path.home() / "Library/Application Support/Godot/export_templates" / version_folder
    names = ["android_debug.apk", "android_release.apk", "android_source.zip"]
    if all(zipfile.is_zipfile(templates / name) for name in names):
        log(f"复用匹配版本 Android 导出模板：{templates}")
        return
    if dry_run:
        log(f"将安装 Godot {version} Android APK 模板及 Gradle 源码模板")
        return
    archive = ROOT / "build/android-downloads" / f"Godot_v{version}-stable_export_templates.tpz"
    if not zipfile.is_zipfile(archive):
        url = f"https://godot-releases.nbg1.your-objectstorage.com/{version}-stable/{archive.name}"
        download(url, archive)
    with zipfile.ZipFile(archive) as zipped, tempfile.TemporaryDirectory(prefix="android-templates-") as temp:
        wanted = {}
        for name in [*names, "version.txt"]:
            matches = [n for n in zipped.namelist() if n.rsplit("/", 1)[-1] == name]
            if len(matches) != 1:
                raise InstallError(f"Godot 模板缺少或重复：{name}")
            wanted[name] = matches[0]
        actual = zipped.read(wanted["version.txt"]).decode().strip()
        if actual != version_folder:
            raise InstallError(f"模板版本 {actual} 与编辑器 {version_folder} 不一致")
        for name in names:
            target = Path(temp) / name
            with zipped.open(wanted[name]) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            if not zipfile.is_zipfile(target):
                raise InstallError(f"无效 Godot Android 模板：{name}")
        templates.mkdir(parents=True, exist_ok=True)
        for name in names:
            temporary = templates / (name + ".partial")
            shutil.copyfile(Path(temp) / name, temporary)
            temporary.replace(templates / name)


def sdk_versions(version_folder: str, api: str | None, build_tools: str | None,
                 dry_run: bool = False) -> tuple[str, str]:
    source = Path.home() / "Library/Application Support/Godot/export_templates" / version_folder / "android_source.zip"
    if not source.is_file():
        if dry_run:
            return api or "<模板compileSdk>", build_tools or "<模板buildTools>"
        raise InstallError(f"缺少匹配版本 Gradle 源码模板：{source}")
    with zipfile.ZipFile(source) as archive:
        config = next((n for n in archive.namelist() if n == "config.gradle" or n.endswith("/config.gradle")), "")
        if not config:
            raise InstallError(f"Android 源码模板缺少 config.gradle：{source}")
        text = archive.read(config).decode()
    compile_sdk = re.search(r"(?m)^\s*compileSdk\s*:\s*(\d+)", text)
    tools = re.search(r"(?m)^\s*buildTools\s*:\s*['\"]([\d.]+)['\"]", text)
    if (api is None and not compile_sdk) or (build_tools is None and not tools):
        raise InstallError("无法识别模板的SDK版本，请用 --api / --build-tools 显式指定")
    return api or compile_sdk[1], build_tools or tools[1]


def configure_editor_settings(sdk: Path, java_home: Path, dry_run: bool, version: str) -> None:
    major_minor = ".".join(version.split(".")[:2])
    godot_settings = Path.home() / "Library/Application Support/Godot" / f"editor_settings-{major_minor}.tres"
    if dry_run:
        log(f"将配置 Godot：export/android/android_sdk_path={sdk}")
        log(f"将配置 Godot：export/android/java_sdk_path={java_home}")
        return
    godot_settings.parent.mkdir(parents=True, exist_ok=True)
    text = godot_settings.read_text(encoding="utf-8") if godot_settings.exists() else '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n'
    values = {
        "export/android/android_sdk_path": str(sdk),
        "export/android/java_sdk_path": str(java_home),
    }
    for key, value in values.items():
        line = f"{key} = {json.dumps(value, ensure_ascii=False)}"
        pattern = re.compile(r"^" + re.escape(key) + r"\s*=.*$", re.M)
        text = pattern.sub(lambda _: line, text) if pattern.search(text) else text.rstrip() + "\n" + line + "\n"
    if godot_settings.exists() and not godot_settings.with_suffix(".tres.android-backup").exists():
        shutil.copy2(godot_settings, godot_settings.with_suffix(".tres.android-backup"))
    temporary = godot_settings.with_suffix(".tres.android-tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(godot_settings)
    log(f"已写入 Godot 编辑器配置：{godot_settings}")


def shell_home_path(path: Path) -> str:
    """保留 shell 可执行性；只替换 HOME 前缀，后缀独立引用防止命令展开。"""
    try:
        relative = path.relative_to(Path.home())
    except ValueError:
        return shlex.quote(str(path))
    return '"$HOME"' + (shlex.quote("/" + str(relative)) if str(relative) != "." else "")


def write_environment(env_path: Path, java_home: Path, sdk: Path) -> None:
    env_path.parent.mkdir(parents=True, exist_ok=True)
    env_path.write_text("export JAVA_HOME=" + shell_home_path(java_home) + "\n" +
                        "export ANDROID_HOME=" + shell_home_path(sdk) + "\n" +
                        "export ANDROID_SDK_ROOT=\"$ANDROID_HOME\"\n" +
                        'export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"\n')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT", GODOT_DEFAULT))
    parser.add_argument("--sdk", default=os.environ.get("ANDROID_SDK_ROOT", str(ANDROID_SDK_DEFAULT)))
    parser.add_argument("--api", help="Android API level，默认读取匹配Godot模板")
    parser.add_argument("--build-tools", help="默认读取匹配Godot模板")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        if platform.system() != "Darwin":
            raise InstallError("此脚本针对 macOS；Android 工具链路径和 JDK 安装方式需要按平台单独配置")
        godot = Path(args.godot)
        if not godot.is_file():
            raise InstallError(f"找不到 Godot：{godot}")
        version, version_folder = godot_version(godot)
        sdk = Path(args.sdk).expanduser().resolve()
        java_home = install_java(Path.home() / "Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home", args.dry_run)
        install_export_template(godot, version, version_folder, args.dry_run)
        api, build_tools = sdk_versions(version_folder, args.api, args.build_tools, args.dry_run)
        log(f"Android Platform：{api}；Build Tools：{build_tools}（匹配当前Godot模板）")
        repository = None if args.dry_run else _read_repository()
        manager = install_cmdline_tools(sdk, args.dry_run, repository)
        install_sdk_packages(manager, sdk, api, build_tools, args.dry_run, java_home, repository)
        if not args.dry_run:
            verify_tools(sdk, java_home, build_tools)
        configure_editor_settings(sdk, java_home, args.dry_run, version)
        if args.dry_run:
            log("以上为检查计划；没有安装或修改文件。")
            return 0
        env_path = ROOT / "build/android-env.sh"
        write_environment(env_path, java_home, sdk)
        log("安装及工具执行校验完成。可以运行：./构建游戏.command --android-debug")
        log(f"终端使用 SDK 工具：source {shlex.quote(str(env_path))}")
        log("发布 APK/AAB 首次未配置签名时自动生成 .android-signing/；请备份该目录，不要提交密钥或密码到 Git")
        return 0
    except (InstallError, OSError, ValueError, ET.ParseError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(redact_paths(f"Android 环境安装失败：{error}", ROOT), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Android 环境安装已中断。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
