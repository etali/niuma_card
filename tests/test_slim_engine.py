# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""裁剪参数必须对应实际构建选项，并保留本游戏的渲染/物理/文本/联网能力。"""
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('slim_engine', ROOT / 'tools/slim_engine.py')
slim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slim)


class SlimEngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='card-engine-options-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scenes').mkdir()
        (self.root / 'scenes/main.gd').write_text('''extends RigidBody3D
var camera := Camera3D.new()
var panel := Control.new()
var socket := WebSocketPeer.new()
''')
        self.capabilities = {
            'version': {'major': 4, 'minor': 7, 'patch': 1, 'status': 'stable', 'hash': 'a' * 40},
            'classes': {'RigidBody3D': 'CollisionObject3D', 'CollisionObject3D': 'Node3D',
                        'Camera3D': 'Node3D', 'Node3D': 'Node', 'Node': 'Object',
                        'Control': 'Node', 'WebSocketPeer': 'Object', 'Object': ''},
            'settings': {'renderer': 'gl_compatibility', 'physics_3d': 'DEFAULT'},
        }

    def test_compatibility_driver_uses_actual_scons_option(self):
        options = slim.make_plan(self.root, self.capabilities)['scons_options']
        self.assertTrue(options['opengl3'])
        self.assertNotIn('gles3', options)
        self.assertFalse(options['angle'])
        self.assertFalse(options['vulkan'])
        self.assertFalse(options['metal'])
        for key in ['disable_3d', 'disable_physics_3d', 'disable_advanced_gui']:
            self.assertFalse(options[key])
        for key in ['module_websocket_enabled', 'module_mbedtls_enabled',
                    'module_text_server_adv_enabled', 'module_godot_physics_3d_enabled']:
            self.assertTrue(options[key])

    def test_optional_runtime_modules_follow_assets_and_calls(self):
        plan = slim.make_plan(self.root, self.capabilities)['scons_options']
        for name in ['raycast', 'vhacd', 'meshoptimizer', 'msdfgen', 'svg', 'astcenc', 'basis_universal']:
            self.assertFalse(plan[f'module_{name}_enabled'], name)
        self.assertTrue(plan['module_etcpak_enabled'])
        code = self.root / 'scenes/main.gd'
        code.write_text(code.read_text() + '\nvar mesh = obj.convex_decompose()\nvar lod = obj.generate_lods()\nvar text = image.load_svg_from_string("<svg/>")\nfont.set_multichannel_signed_distance_field(true)\nview.use_occlusion_culling = true\n')
        plan = slim.make_plan(self.root, self.capabilities)['scons_options']
        for name in ['raycast', 'vhacd', 'meshoptimizer', 'msdfgen', 'svg']:
            self.assertTrue(plan[f'module_{name}_enabled'], name)

    def test_import_formats_preserve_decoders_without_counting_audio(self):
        asset = self.root / 'assets'
        asset.mkdir()
        (asset / 'sound.wav.import').write_text('importer="wav"\ncompress/mode=2\n')
        (asset / 'font.ttf.import').write_text('importer="font_data_dynamic"\nmultichannel_signed_distance_field=false\n')
        self.assertFalse(slim.make_plan(self.root, self.capabilities)['scons_options']['module_astcenc_enabled'])
        self.assertFalse(slim.make_plan(self.root, self.capabilities)['scons_options']['module_msdfgen_enabled'])
        (asset / 'image.png.import').write_text('importer="texture"\ncompress/mode=4\n')
        (asset / 'font.ttf.import').write_text('importer="font_data_dynamic"\nmultichannel_signed_distance_field=true\n')
        plan = slim.make_plan(self.root, self.capabilities)['scons_options']
        for name in ['astcenc', 'etcpak', 'basis_universal', 'msdfgen']:
            self.assertTrue(plan[f'module_{name}_enabled'], name)

    def test_project_settings_are_part_of_feature_detection(self):
        (self.root / 'project.godot').write_text('[rendering]\nocclusion_culling/use_occlusion_culling=true\n')
        plan = slim.make_plan(self.root, self.capabilities)
        self.assertIn('project.godot', plan['scanned_files'])
        self.assertTrue(plan['scons_options']['module_raycast_enabled'])

    def test_byte_stream_delta_codec_does_not_enable_gpu_texture_encoders(self):
        code = self.root / 'scenes/main.gd'
        base = code.read_text()
        code.write_text(base + '\nvar raw = bytes.decompress(589824, FileAccess.COMPRESSION_DEFLATE)\n'
                        'var packed = bytes.compress(FileAccess.COMPRESSION_DEFLATE)\n')
        options = slim.make_plan(self.root, self.capabilities)['scons_options']
        self.assertFalse(options['module_astcenc_enabled'])
        self.assertFalse(options['module_basis_universal_enabled'])
        code.write_text(base + '\nimage.decompress()\n')
        options = slim.make_plan(self.root, self.capabilities)['scons_options']
        self.assertTrue(options['module_astcenc_enabled'])
        self.assertTrue(options['module_basis_universal_enabled'])

    def test_keep_module_overrides_detected_absence(self):
        for name in ['raycast', 'vhacd', 'meshoptimizer', 'msdfgen', 'svg', 'astcenc', 'basis_universal']:
            self.assertTrue(slim.make_plan(self.root, self.capabilities, [name])['scons_options'][f'module_{name}_enabled'])

    def test_class_pruning_protects_inherited_runtime_dependencies(self):
        from engine_class_profile import disabled_classes
        classes = {'Object': '', 'Node': 'Object', 'Node3D': 'Node',
                   'AnimationMixer': 'Node', 'AnimationPlayer': 'AnimationMixer',
                   'VehicleBody3D': 'Node3D', 'Sprite2D': 'Node', 'Control': 'Node'}
        capabilities = {'classes': classes}
        cuts = disabled_classes(capabilities, ['AnimationPlayer', 'Control'])
        self.assertNotIn('AnimationPlayer', cuts)
        self.assertNotIn('AnimationMixer', cuts)
        self.assertNotIn('Control', cuts)
        self.assertIn('VehicleBody3D', cuts)
        self.assertIn('Sprite2D', cuts)
        self.assertNotIn('VehicleBody3D', disabled_classes(capabilities, [], ['VehicleBody3D']))

    def test_build_variants_cannot_reuse_wrong_cached_template(self):
        import copy
        plan = slim.make_plan(self.root, self.capabilities)
        original = slim.template_fingerprint(plan, 'universal', 'clang16', '')
        variants = [('size', 'full', 'none'), ('size_extra', 'thin', 'none'), ('size', 'thin', 'safe')]
        hashes = {original}
        for optimize, lto, trim in variants:
            other = copy.deepcopy(plan)
            slim.configure_build(other, self.capabilities, optimize, lto, trim)
            digest = slim.template_fingerprint(other, 'universal', 'clang16', '')
            self.assertNotIn(digest, hashes)
            hashes.add(digest)
        other = copy.deepcopy(plan)
        other['disabled_classes'] = ['Sprite2D']
        self.assertNotEqual(original, slim.template_fingerprint(other, 'universal', 'clang16', ''))

    def test_unknown_kept_class_is_rejected_before_building(self):
        plan = slim.make_plan(self.root, self.capabilities)
        with self.assertRaisesRegex(slim.BuildError, '不存在'):
            slim.configure_build(plan, self.capabilities, keep_classes=['不存在'])

    def test_string_referenced_native_class_is_preserved(self):
        source = self.root / 'scenes/main.gd'
        source.write_text(source.read_text() + '\nvar dynamic = ClassDB.instantiate("AnimationPlayer")\n')
        self.capabilities['classes'].update({'AnimationMixer': 'Node', 'AnimationPlayer': 'AnimationMixer'})
        plan = slim.make_plan(self.root, self.capabilities)
        slim.configure_build(plan, self.capabilities, class_trim='safe')
        self.assertNotIn('AnimationPlayer', plan['disabled_classes'])
        self.assertNotIn('AnimationMixer', plan['disabled_classes'])

    def test_benchmark_requires_identical_game_pack(self):
        from benchmark_engine_variants import benchmark
        apps = {}
        for label in ['baseline', 'changed']:
            app = self.root / (label + '.app')
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/Resources/game.pck').write_bytes(label.encode())
            apps[label] = app
        with self.assertRaisesRegex(ValueError, '资源包不同'):
            benchmark(apps, self.root / 'benchmark')

    def test_default_uses_measured_balanced_configuration(self):
        plan = slim.make_plan(self.root, self.capabilities)
        slim.configure_build(plan, self.capabilities)
        self.assertEqual(plan['build_options'], {'optimize': 'size', 'lto': 'full', 'class_trim': 'safe'})

    def test_profile_contains_selected_class_blacklist(self):
        plan = slim.make_plan(self.root, self.capabilities)
        plan['disabled_classes'] = ['Sprite2D', 'VehicleBody3D']
        slim.write_plan(plan, self.root / 'profile')
        profile = json.loads((self.root / 'profile/game.build').read_text())
        self.assertEqual(profile['disabled_classes'], plan['disabled_classes'])

    def test_only_registered_options_count_not_mentions(self):
        (self.root / 'SConstruct').write_text('''
# gles3 is a renderer directory, not the build option.
legacy = "gles3"
opts.Add(BoolVariable("opengl3", "Enable the OpenGL/GLES3 rendering driver", True))
opts.Add("build_profile", "Path to a feature build profile", "")
''')
        platform = self.root / 'platform/macos'
        platform.mkdir(parents=True)
        (platform / 'detect.py').write_text('''
def get_opts():
    return [BoolVariable("generate_bundle", "Generate APP bundle", False)]
''')
        slim.validate_options(self.root, {'opengl3': True, 'build_profile': '', 'generate_bundle': False})
        with self.assertRaisesRegex(slim.BuildError, 'gles3'):
            slim.validate_options(self.root, {'gles3': True})

    def test_validation_reports_all_unknown_options_before_compilation(self):
        (self.root / 'SConstruct').write_text('opts.Add(BoolVariable("opengl3", "GL", True))')
        with self.assertRaises(slim.BuildError) as error:
            slim.validate_options(self.root, {'gles3': True, 'typo_driver': False})
        self.assertIn('gles3', str(error.exception))
        self.assertIn('typo_driver', str(error.exception))

    def test_unknown_module_rejected_but_existing_module_accepted(self):
        (self.root / 'SConstruct').write_text('')
        module = self.root / 'modules/websocket'
        module.mkdir(parents=True)
        (module / 'config.py').write_text('def can_build(env, platform): return True')
        slim.validate_options(self.root, {'module_websocket_enabled': True})
        with self.assertRaisesRegex(slim.BuildError, 'module_missing_enabled'):
            slim.validate_options(self.root, {'module_missing_enabled': False})

    def test_generated_engine_dependencies_are_not_project_documentation(self):
        spec = importlib.util.spec_from_file_location('line_refs', ROOT / 'tools/check_no_line_refs.py')
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        checker.ROOT = self.root
        vendor = self.root / 'build/slim-engine/python/vendor.py'
        vendor.parent.mkdir(parents=True)
        vendor.write_text('# https://example.invalid/vendor/code.py' + '#' + 'L123\n')
        self.assertEqual(checker.scan(), [])
        (self.root / 'scenes/comment.gd').write_text(vendor.read_text())
        self.assertEqual(len(checker.scan()), 1)

    def test_all_generated_flags_supported_by_downloaded_matching_source(self):
        sources = sorted((ROOT / 'build/slim-engine/source').glob('*/SConstruct'))
        sources = [p.parent for p in sources if len(p.parent.name) == 40]
        if not sources:
            self.skipTest('未下载匹配的Godot源码；不为测试访问网络')
        for source in sources:
            slim.validate_options(source, slim.make_plan(self.root, self.capabilities)['scons_options'])
        plan = ROOT / 'build/slim-engine/analysis.json'
        if plan.is_file():
            data = json.loads(plan.read_text())
            source = ROOT / 'build/slim-engine/source' / data['version']['hash']
            if (source / 'SConstruct').is_file():
                slim.validate_options(source, data['scons_options'])


if __name__ == '__main__':
    unittest.main()
