# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""安装器回归：跨平台包选择、ZIP执行权限、失败恢复及JAVA_HOME。无外网依赖。"""
import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("android_installer", ROOT / "tools/install_android_dependencies.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_environment_file_uses_home_expansion_and_preserves_shell_special_characters(self):
        home = self.root / "home with spaces"
        jdk = home / "JDK $value `literal` 'quote'"
        sdk = home / "SDK 中文 $(false)"
        env_file = self.root / "build/android-env.sh"
        with mock.patch.object(Path, "home", return_value=home):
            installer.write_environment(env_file, jdk, sdk)
        text = env_file.read_text()
        self.assertNotIn(str(home), text)
        result = subprocess.run(["bash", "-c", 'source "$1"; "$2" -c "import json,os; print(json.dumps([os.environ[\'JAVA_HOME\'],os.environ[\'ANDROID_HOME\'],os.environ[\'ANDROID_SDK_ROOT\']]))"',
                                 "fixture", str(env_file), sys.executable],
                                env=dict(os.environ, HOME=str(home)), text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(result.stdout), [str(jdk), str(sdk), str(sdk)])
        external = Path("/opt/custom JDK")
        with mock.patch.object(Path, "home", return_value=home):
            self.assertEqual(installer.shell_home_path(external), "'/opt/custom JDK'")

    def test_download_stream_hides_paths_and_retains_complete_file(self):
        root = self.root.resolve()
        tool = root / "fake-curl"
        tool.write_text(f"#!{sys.executable}\nimport pathlib,sys\n"
                        "target=pathlib.Path(sys.argv[sys.argv.index('--output')+1])\n"
                        "print(str(target),flush=True)\ntarget.write_bytes(b'complete')\n")
        tool.chmod(0o755)
        destination = root / "cache/package.zip"
        capture = io.StringIO()
        with mock.patch.object(installer, "ROOT", root), \
                mock.patch.object(installer.shutil, "which", return_value=str(tool)), redirect_stdout(capture):
            installer.download("https://example.invalid/fixture", destination)
        self.assertEqual(destination.read_bytes(), b"complete")
        self.assertNotIn(str(root), capture.getvalue())
        self.assertIn("./cache/package.zip.part", capture.getvalue())

    def test_command_output_and_timeout_are_redacted_without_changing_raw_result(self):
        raw = f"version 17 {self.root}/sdk {Path.home()}/java\n"
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                capture = io.StringIO()
                value = subprocess.CompletedProcess(["fixture"], 0, raw)
                effect = subprocess.TimeoutExpired(["fixture"], 1, output=raw.encode()) if timeout else None
                with mock.patch.object(installer, "ROOT", self.root), \
                        mock.patch.object(installer.subprocess, "run", return_value=value, side_effect=effect), \
                        redirect_stdout(capture):
                    if timeout:
                        with self.assertRaises(installer.InstallError):
                            installer.run(["fixture"], timeout=1)
                    else:
                        self.assertEqual(installer.run(["fixture"]).stdout, raw)
                self.assertNotIn(str(self.root), capture.getvalue())
                self.assertNotIn(str(Path.home()), capture.getvalue())
                self.assertIn("./sdk ~/java", capture.getvalue())

    def test_host_os_is_archive_sibling_and_macos_wins_over_linux(self):
        root = ET.fromstring('''<repo xmlns="urn:android"><remotePackage path="platform-tools"><archives>
        <archive><complete><size>20</size><checksum type="sha1">abc</checksum><url>linux.zip</url></complete><host-os>linux</host-os></archive>
        <archive><complete><size>42</size><checksum type="sha1">def</checksum><url>darwin.zip</url></complete><host-os>macosx</host-os></archive>
        </archives></remotePackage></repo>''')
        data = installer._repository_package(root, "platform-tools")
        self.assertTrue(data['url'].endswith('/darwin.zip'))
        self.assertEqual((data['size'], data['checksum']), (42, 'def'))

    def test_never_falls_back_to_linux_when_mac_archive_is_absent(self):
        root = ET.fromstring('''<repo><remotePackage path="cmdline-tools;latest"><archives><archive>
        <complete><url>linux.zip</url></complete><host-os>linux</host-os>
        </archive></archives></remotePackage></repo>''')
        self.assertIsNone(installer._repository_package(root, 'cmdline-tools;latest'))
        with mock.patch.object(installer, 'download') as download:
            with self.assertRaises(installer.InstallError):
                installer._download_sdk_package(root, 'cmdline-tools;latest')
            download.assert_not_called()

    def test_platform_archive_without_host_os_is_allowed(self):
        root = ET.fromstring('''<repo><remotePackage path="platforms;android-35"><archives><archive>
        <complete><url>platform.zip</url></complete></archive></archives></remotePackage></repo>''')
        self.assertTrue(installer._repository_url(root, 'platforms;android-35').endswith('/platform.zip'))

    def test_extract_repairs_executable_scripts_but_not_text_resources(self):
        archive = self.root / 'sdk.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('tools/bin/sdkmanager', '#!/bin/sh\nprintf "fixture-sdk\\n"\n')
            output.writestr('tools/source.properties', 'Pkg.Revision=19.0\n')
            output.writestr('tools/native', b'\xcf\xfa\xed\xfe' + b'\0' * 30)
        destination = self.root / 'extracted'
        installer._extract_zip(archive, destination)
        script = destination / 'tools/bin/sdkmanager'
        self.assertTrue(os.access(script, os.X_OK))
        self.assertEqual(subprocess.check_output([script], text=True).strip(), 'fixture-sdk')
        self.assertFalse(os.access(destination / 'tools/source.properties', os.X_OK))
        self.assertTrue(os.access(destination / 'tools/native', os.X_OK))

    def test_failed_reinstall_keeps_previous_install(self):
        dest = self.root / 'sdk/platform-tools'
        dest.mkdir(parents=True)
        previous = dest / 'adb'
        previous.write_text('#!/bin/sh\necho previous\n')
        archive = self.root / 'linux.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('platform-tools/adb', b'\x7fELF' + b'\0' * 100)
        with self.assertRaises(installer.InstallError):
            installer._extract_sdk_archive(archive, dest, 'adb')
        self.assertIn('previous', previous.read_text())

    def test_dry_run_does_not_chmod_existing_sdkmanager(self):
        tool = self.root / 'cmdline-tools/latest/bin/sdkmanager'
        tool.parent.mkdir(parents=True)
        tool.write_text('#!/usr/bin/env sh\necho 19.0\n')
        tool.chmod(0o644)
        self.assertEqual(installer.install_cmdline_tools(self.root, True), tool)
        self.assertFalse(os.access(tool, os.X_OK))
        self.assertEqual(installer.install_cmdline_tools(self.root, False), tool)
        self.assertTrue(os.access(tool, os.X_OK))

    def test_sdkmanager_wrapper_cannot_hide_linux_android_binary(self):
        tools = self.root / 'cmdline-tools/latest/bin'
        tools.mkdir(parents=True)
        (tools / 'sdkmanager').write_text('#!/bin/sh\necho unknown\n')
        (tools / 'android').write_bytes(b'\x7fELF' + b'\0' * 100)
        with self.assertRaises(installer.InstallError):
            installer.sdkmanager(self.root)

    def test_all_version_commands_receive_java_home_and_execute(self):
        jdk = self.root / 'JDK With Space'
        sdk = self.root / 'SDK With Space'
        for relative, output in [(jdk/'bin/java', '17.0.20'),
                                 (sdk/'cmdline-tools/latest/bin/sdkmanager', '19.0'),
                                 (sdk/'platform-tools/adb', 'adb fixture'),
                                 (sdk/'build-tools/35.0.0/apksigner', '0.9'),
                                 (sdk/'build-tools/35.0.0/aapt2', 'fixture aapt2')]:
            relative.parent.mkdir(parents=True, exist_ok=True)
            relative.write_text('#!/bin/sh\n[ -x "$JAVA_HOME/bin/java" ] || exit 42\nprintf "%s\\n" "' + output + '"\n')
            relative.chmod(0o755)
        align = sdk/'build-tools/35.0.0/zipalign'
        align.write_text('#!/bin/sh\necho "Usage: zipalign"\nexit 2\n')
        align.chmod(0o755)
        installer.verify_tools(sdk, jdk, '35.0.0')

    def test_permission_error_is_explained_without_traceback(self):
        tool = self.root / 'tool'
        tool.write_text('#!/bin/sh\nexit 0\n')
        tool.chmod(0o644)
        with self.assertRaisesRegex(installer.InstallError, '无法启动'):
            installer.run([str(tool)])

    def test_archive_path_traversal_rejected_before_extracting(self):
        archive = self.root / 'bad.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('../outside', 'bad')
        with self.assertRaises(installer.InstallError):
            installer._extract_zip(archive, self.root / 'extract')
        self.assertFalse((self.root / 'outside').exists())

    def test_prerelease_does_not_silently_install_stable_template(self):
        result = subprocess.CompletedProcess([], 0, stdout='4.8.0.beta1.official.hash\n')
        with mock.patch.object(installer, 'run', return_value=result):
            with self.assertRaises(installer.InstallError):
                installer.godot_version(Path('godot'))

    def test_template_reuse_requires_gradle_source_as_well_as_apks(self):
        templates = self.root/'Library/Application Support/Godot/export_templates/4.7.1.stable'
        templates.mkdir(parents=True)
        for name in ['android_debug.apk', 'android_release.apk']:
            with zipfile.ZipFile(templates / name, 'w') as output:
                output.writestr('file', 'fixture')
        with mock.patch.object(Path, 'home', return_value=self.root), mock.patch.object(installer, 'log') as log:
            installer.install_export_template(Path('godot'), '4.7.1', '4.7.1.stable', True)
            self.assertIn('Gradle', log.call_args[0][0])

    def test_sdk_versions_follow_the_matched_template_not_a_second_copy(self):
        folder = self.root/'Library/Application Support/Godot/export_templates/4.7.1.stable'
        folder.mkdir(parents=True)
        with zipfile.ZipFile(folder/'android_source.zip', 'w') as archive:
            archive.writestr('config.gradle', "ext.versions = [\n compileSdk : 37,\n buildTools : '37.2.1',\n]\n")
        with mock.patch.object(Path, 'home', return_value=self.root):
            self.assertEqual(installer.sdk_versions('4.7.1.stable', None, None), ('37', '37.2.1'))
            self.assertEqual(installer.sdk_versions('4.7.1.stable', '35', '35.0.0'), ('35', '35.0.0'))


if __name__ == '__main__':
    unittest.main()
