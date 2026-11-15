# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""Windows 模板、发布包和构建预设回归；不需要外网或 Windows 主机。"""
import configparser
from contextlib import redirect_stdout
import io
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_deps
import install_build_env as env
import release_bundle as bundle


def pe_binary(machine=0x8664):
    binary = bytearray(512)
    binary[:2] = b"MZ"
    struct.pack_into("<I", binary, 0x3C, 128)
    binary[128:132] = b"PE\0\0"
    struct.pack_into("<H", binary, 132, machine)
    struct.pack_into("<H", binary, 152, 0x20B)
    return bytes(binary)


def populate(stage, tag=b"new"):
    directory = stage / "windows"
    directory.mkdir(parents=True)
    (directory / "牛马牌.exe").write_bytes(pe_binary() + tag)
    (directory / "牛马牌.pck").write_bytes(struct.pack("<6I", 0x43504447, 4, 4, 7, 1, 0) + tag)
    for name in ("on_work_cards.json", "off_work_cards.json", "LICENSE", "NOTICE"):
        (directory / name).write_bytes(tag)
    (directory / "runtime.dll").write_bytes(tag)
    return directory


class WindowsBuildTest(unittest.TestCase):
    def test_preset_uses_x64_separate_pck_and_shared_filters(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read(ROOT / "export_presets.cfg", encoding="utf-8")
        self.assertEqual(config.get("preset.3", "name"), '"Windows Desktop"')
        self.assertEqual(config.get("preset.3", "platform"), '"Windows Desktop"')
        for key in ("exclude_filter", "include_filter", "export_filter"):
            self.assertEqual(config.get("preset.3", key), config.get("preset.0", key))
        self.assertEqual(config.get("preset.3.options", "binary_format/architecture"), '"x86_64"')
        self.assertEqual(config.get("preset.3.options", "binary_format/embed_pck"), "false")
        self.assertEqual(config.get("preset.3.options", "application/icon"), '"res://assets/app_icon.png"')
        self.assertEqual(config.get("preset.3.options", "codesign/enable"), "false")

    def test_windows_dependency_check_never_requires_macos_template_or_toolchain(self):
        version = ("4.7.1", "4.7.1.stable")
        with mock.patch.object(build_deps, "godot_version", return_value=version), \
                mock.patch.object(env, "missing_templates", return_value=list(env.WINDOWS_TEMPLATES)) as missing, \
                mock.patch.object(build_deps, "python_check", return_value=[]), \
                mock.patch.object(build_deps, "toolchain_check", side_effect=AssertionError("不能编译 macOS 引擎")), \
                mock.patch.object(env, "install_templates") as install:
            groups = build_deps.collect("windows", Path("godot"))
            self.assertEqual(len(groups), 1)
            missing.assert_called_once_with(version[1], env.WINDOWS_TEMPLATES)
            groups[0].install()
            install.assert_called_once_with(*version, False, env.WINDOWS_TEMPLATES)

    def test_windows_templates_are_pe_not_zip(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "4.7.1.stable"
            folder.mkdir()
            for name in env.WINDOWS_TEMPLATES:
                (folder / name).write_bytes(pe_binary())
            with mock.patch.object(env, "TEMPLATES_ROOT", root):
                self.assertEqual(env.missing_templates(folder.name, env.WINDOWS_TEMPLATES), [])
                for data in (b"<html>download failed</html>", b"MZ", pe_binary(0x14C)):
                    (folder / env.WINDOWS_TEMPLATES[0]).write_bytes(data)
                    self.assertEqual(env.missing_templates(folder.name, env.WINDOWS_TEMPLATES),
                                     [env.WINDOWS_TEMPLATES[0]])

    def test_cached_archive_installs_only_requested_windows_templates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "build/android-downloads/Godot_v4.7.1-stable_export_templates.tpz"
            archive.parent.mkdir(parents=True)
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("templates/version.txt", "4.7.1.stable")
                for name in env.WINDOWS_TEMPLATES:
                    zipped.writestr("templates/" + name, pe_binary())
            with mock.patch.object(env, "ROOT", root), mock.patch.object(env, "TEMPLATES_ROOT", root / "templates"), \
                    mock.patch.object(env, "download", side_effect=AssertionError("不能重复下载")), redirect_stdout(io.StringIO()):
                env.install_templates("4.7.1", "4.7.1.stable", False, env.WINDOWS_TEMPLATES)
            installed = root / "templates/4.7.1.stable"
            self.assertEqual({p.name for p in installed.iterdir()}, {*env.WINDOWS_TEMPLATES, "version.txt"})
            self.assertTrue(all(env.valid_template(installed / name) for name in env.WINDOWS_TEMPLATES))

    def test_invalid_template_is_detected_before_any_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "build/android-downloads/Godot_v4.7.1-stable_export_templates.tpz"
            archive.parent.mkdir(parents=True)
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("templates/version.txt", "4.7.1.stable")
                zipped.writestr("templates/" + env.WINDOWS_TEMPLATES[0], pe_binary())
                zipped.writestr("templates/" + env.WINDOWS_TEMPLATES[1], b"invalid")
            installed = root / "templates/4.7.1.stable"
            installed.mkdir(parents=True)
            (installed / env.WINDOWS_TEMPLATES[0]).write_bytes(b"previous")
            with mock.patch.object(env, "ROOT", root), mock.patch.object(env, "TEMPLATES_ROOT", root / "templates"), \
                    redirect_stdout(io.StringIO()):
                with self.assertRaises(env.InstallError):
                    env.install_templates("4.7.1", "4.7.1.stable", False, env.WINDOWS_TEMPLATES)
            self.assertEqual((installed / env.WINDOWS_TEMPLATES[0]).read_bytes(), b"previous")
            self.assertFalse((installed / env.WINDOWS_TEMPLATES[1]).exists())

    def test_cli_packages_and_replaces_only_windows_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "build"
            (output / "牛马牌.app").mkdir(parents=True)
            (output / "牛马牌.app/keep").write_bytes(b"macOS")
            for tag in (b"previous", b"new"):
                stage = root / tag.decode()
                populate(stage, tag)
                result = subprocess.run([sys.executable, str(ROOT / "tools/release_bundle.py"),
                                         str(stage), str(output), "--windows"], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with zipfile.ZipFile(output / "牛马牌_windows.zip") as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertEqual(archive.read("牛马牌/牛马牌.exe"), pe_binary() + tag)
                    for name in ("runtime.dll", "on_work_cards.json", "off_work_cards.json", "LICENSE", "NOTICE"):
                        self.assertEqual(archive.read("牛马牌/" + name), tag)
                self.assertEqual((output / "牛马牌.app/keep").read_bytes(), b"macOS")
                self.assertFalse(list(output.glob(".release-previous-*")))

    def test_invalid_pe_missing_pck_and_wrong_pck_rejected(self):
        for failure in ("wrong_arch", "missing_pck", "bad_pck", "extra_pck"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                stage = Path(temporary)
                directory = populate(stage)
                if failure == "wrong_arch":
                    (directory / "牛马牌.exe").write_bytes(pe_binary(0x14C))
                elif failure == "missing_pck":
                    (directory / "牛马牌.pck").unlink()
                elif failure == "bad_pck":
                    (directory / "牛马牌.pck").write_bytes(b"not a PCK")
                else:
                    (directory / "extra.pck").write_bytes(b"unexpected")
                with self.assertRaises(ValueError):
                    bundle.package_windows(stage)
                self.assertFalse((stage / "牛马牌_windows.zip").exists())

    def test_publication_failure_rolls_back_windows_and_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, output = root / "stage", root / "build"
            populate(stage, b"new")
            populate(output, b"previous")
            bundle.package_windows(stage)
            (output / "牛马牌_windows.zip").write_bytes(b"old ZIP")
            replace = bundle.os.replace
            def fail(source, target):
                if Path(source) == stage / "牛马牌_windows.zip":
                    raise OSError("fixture rename failure")
                return replace(source, target)
            with mock.patch.object(bundle.os, "replace", side_effect=fail):
                with self.assertRaises(OSError):
                    bundle.publish(stage, output, ["windows", "牛马牌_windows.zip"])
            self.assertEqual((output / "windows/牛马牌.exe").read_bytes(), pe_binary() + b"previous")
            self.assertEqual((output / "牛马牌_windows.zip").read_bytes(), b"old ZIP")
            self.assertFalse(list(output.glob(".release-previous-*")))


if __name__ == "__main__":
    unittest.main()
