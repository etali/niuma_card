# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""发布签名回归：自动密钥稳定复用、配置优先级及损坏凭据拒绝覆盖。"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("android_signing", ROOT / "tools/android_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)

ENV_PATH = "GODOT_ANDROID_KEYSTORE_RELEASE_PATH"
ENV_USER = "GODOT_ANDROID_KEYSTORE_RELEASE_USER"
ENV_PASSWORD = "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"


class AndroidSigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="card signing with spaces ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.calls = self.root / "keytool calls.jsonl"
        self.keytool = self.root / "Fake JDK With Spaces" / "bin" / "keytool"
        self.keytool.parent.mkdir(parents=True)
        self.keytool.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "password = os.environ['CARD_ANDROID_KEYSTORE_PASSWORD']\n"
            "assert password and all(password not in arg for arg in args)\n"
            "assert args[args.index('-storepass:env') + 1] == 'CARD_ANDROID_KEYSTORE_PASSWORD'\n"
            "assert args[args.index('-keypass:env') + 1] == 'CARD_ANDROID_KEYSTORE_PASSWORD'\n"
            "record = {'argv': args, 'password_length': len(password)}\n"
            "with open(os.environ['SIGNING_TEST_CALLS'], 'a') as output:\n"
            "    output.write(json.dumps(record) + '\\n')\n"
            "if os.environ.get('SIGNING_TEST_FAIL'):\n"
            "    print('fixture keytool failed', file=sys.stderr)\n"
            "    sys.exit(7)\n"
            "pathlib.Path(args[args.index('-keystore') + 1]).write_bytes(b'fixture signed identity')\n",
            encoding="utf-8",
        )
        self.keytool.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GODOT_ANDROID_KEYSTORE_")}
        self.env["SIGNING_TEST_CALLS"] = str(self.calls)
        self.env["SIGNING_TEST_PRESERVE"] = "original environment"
        keytool_patch = mock.patch.object(signing, "_find_keytool", return_value=self.keytool)
        self.find_keytool = keytool_patch.start()
        self.addCleanup(keytool_patch.stop)
        self.write_presets()

    def write_presets(self, android=None, aab=None):
        text = '[preset.0]\nname="macOS"\nplatform="macOS"\n\n'
        for index, name, options in [(2, "Android", android or {}), (7, "Android AAB", aab or {})]:
            text += f'[preset.{index}]\nname={json.dumps(name)}\nplatform="Android"\n\n'
            text += f'[preset.{index}.options]\npackage/signed=true\n'
            text += "".join(f"{key}={json.dumps(value)}\n" for key, value in options.items())
            text += "\n"
        (self.root / "export_presets.cfg").write_text(text, encoding="utf-8")

    def write_credentials(self, options, index=2):
        path = self.root / ".godot" / "export_credentials.cfg"
        path.parent.mkdir(exist_ok=True)
        text = f"[preset.{index}.options]\n"
        text += "".join(f"{key}={json.dumps(value)}\n" for key, value in options.items())
        path.write_text(text, encoding="utf-8")

    def existing_key(self, name="Existing Release With Spaces.keystore"):
        path = self.root / name
        path.write_bytes(b"existing signing identity")
        return path

    def prepare(self, preset="Android", **environment):
        return signing.prepare_release_signing(self.root, preset, {**self.env, **environment})

    def test_generated_identity_is_private_and_reused_without_keytool(self):
        first = self.prepare()
        directory = self.root / ".android-signing"
        key = directory / "release.keystore"
        metadata = directory / "release.json"
        self.assertEqual(Path(first[ENV_PATH]), key)
        self.assertTrue(first[ENV_USER])
        self.assertGreaterEqual(len(first[ENV_PASSWORD]), 12)
        self.assertEqual(first["SIGNING_TEST_PRESERVE"], "original environment")
        self.assertTrue((directory / ".gdignore").is_file())
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        for path in (key, metadata):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        saved = json.loads(metadata.read_text())
        saved_key = Path(saved["path"])
        self.assertEqual(saved_key if saved_key.is_absolute() else directory / saved_key, key)
        self.assertEqual((saved["user"], saved["password"]), (first[ENV_USER], first[ENV_PASSWORD]))
        before = (key.read_bytes(), metadata.read_bytes(), key.stat().st_mtime_ns)
        self.find_keytool.reset_mock()
        self.find_keytool.side_effect = AssertionError("已有签名不能再次调用 keytool")
        second = self.prepare("Android AAB")
        for variable in (ENV_PATH, ENV_USER, ENV_PASSWORD):
            self.assertEqual(second[variable], first[variable])
        self.assertEqual((key.read_bytes(), metadata.read_bytes(), key.stat().st_mtime_ns), before)
        self.find_keytool.assert_not_called()
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_keytool_receives_password_only_through_environment(self):
        result = self.prepare()
        invocation = json.loads(self.calls.read_text())
        self.assertEqual(invocation["password_length"], len(result[ENV_PASSWORD]))
        self.assertNotIn(result[ENV_PASSWORD], json.dumps(invocation["argv"]))
        self.assertIn("-storepass:env", invocation["argv"])
        self.assertIn("-keypass:env", invocation["argv"])
        self.assertIn(" ", invocation["argv"][invocation["argv"].index("-keystore") + 1])

    def test_incomplete_local_identity_is_never_replaced(self):
        directory = self.root / ".android-signing"
        directory.mkdir()
        key = directory / "release.keystore"
        metadata = directory / "release.json"
        cases = [(), ("key",), ("metadata",)]
        for files in cases:
            with self.subTest(files=files):
                if "key" in files:
                    key.write_bytes(b"important existing signing key")
                if "metadata" in files:
                    metadata.write_text(json.dumps({"path": "release.keystore", "user": "release", "password": "saved-password"}))
                before = {path.name: path.read_bytes() for path in directory.iterdir() if path.is_file()}
                with self.assertRaises(signing.SigningError):
                    self.prepare()
                for name, content in before.items():
                    self.assertEqual((directory / name).read_bytes(), content)
                self.find_keytool.assert_not_called()
                key.unlink(missing_ok=True)
                metadata.unlink(missing_ok=True)

    def test_explicit_environment_preserves_existing_key_with_spaces(self):
        key = self.existing_key()
        result = self.prepare(**{ENV_PATH: str(key), ENV_USER: "published-alias", ENV_PASSWORD: "external-password"})
        self.assertEqual((result[ENV_PATH], result[ENV_USER], result[ENV_PASSWORD]),
                         (str(key), "published-alias", "external-password"))
        self.assertEqual(key.read_bytes(), b"existing signing identity")
        self.assertFalse((self.root / ".android-signing").exists())
        self.find_keytool.assert_not_called()

    def test_explicit_missing_or_partial_credentials_do_not_generate_a_new_identity(self):
        key = self.existing_key()
        complete = {ENV_PATH: str(key), ENV_USER: "published-alias", ENV_PASSWORD: "external-password"}
        cases = [{name: value for name, value in complete.items() if name != missing}
                 for missing in complete]
        cases.append({**complete, ENV_PATH: str(self.root / "missing.keystore")})
        for environment in cases:
            with self.subTest(fields=tuple(environment)):
                with self.assertRaises(signing.SigningError):
                    self.prepare(**environment)
                self.assertFalse((self.root / ".android-signing").exists())
                self.find_keytool.assert_not_called()

    def test_priority_is_applied_per_field_and_empty_environment_is_ignored(self):
        preset_key = self.existing_key("preset.keystore")
        credential_key = self.existing_key("credential with spaces.keystore")
        self.write_presets(android={"keystore/release": str(preset_key),
                                    "keystore/release_user": "preset-alias",
                                    "keystore/release_password": "preset-password"})
        self.write_credentials({"keystore/release": str(credential_key),
                                "keystore/release_user": "credential-alias"})
        result = self.prepare(**{ENV_PATH: "", ENV_USER: "environment-alias", ENV_PASSWORD: ""})
        self.assertEqual((result[ENV_PATH], result[ENV_USER], result[ENV_PASSWORD]),
                         (str(credential_key), "environment-alias", "preset-password"))
        self.write_credentials({"keystore/release": str(credential_key),
                                "keystore/release_password": "credential-password"})
        result = self.prepare(**{ENV_PATH: "", ENV_USER: "", ENV_PASSWORD: ""})
        self.assertEqual((result[ENV_PATH], result[ENV_USER], result[ENV_PASSWORD]),
                         (str(credential_key), "preset-alias", "credential-password"))
        self.find_keytool.assert_not_called()

    def test_empty_credentials_override_preset_and_fail_without_regeneration(self):
        key = self.existing_key()
        self.write_presets(android={"keystore/release": str(key),
                                    "keystore/release_user": "preset-alias",
                                    "keystore/release_password": "preset-password"})
        self.write_credentials({"keystore/release_password": ""})
        with self.assertRaises(signing.SigningError):
            self.prepare()
        self.find_keytool.assert_not_called()
        self.assertFalse((self.root / ".android-signing").exists())

    def test_empty_default_credentials_reuse_a_previous_local_identity(self):
        first = self.prepare()
        key = Path(first[ENV_PATH])
        metadata = self.root / ".android-signing" / "release.json"
        before = (key.read_bytes(), metadata.read_bytes(), key.stat().st_mtime_ns)
        self.write_credentials({"keystore/release": "", "keystore/release_user": "", "keystore/release_password": ""})
        self.find_keytool.reset_mock()
        self.find_keytool.side_effect = AssertionError("默认空凭据不能替换已有本机签名")
        second = self.prepare()
        for variable in (ENV_PATH, ENV_USER, ENV_PASSWORD):
            self.assertEqual(second[variable], first[variable])
        self.assertEqual((key.read_bytes(), metadata.read_bytes(), key.stat().st_mtime_ns), before)
        self.find_keytool.assert_not_called()
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_empty_default_credentials_allow_first_local_identity_generation(self):
        self.write_credentials({"keystore/release": "", "keystore/release_user": "", "keystore/release_password": ""})
        result = self.prepare()
        self.assertEqual(Path(result[ENV_PATH]), self.root / ".android-signing" / "release.keystore")
        self.assertTrue(Path(result[ENV_PATH]).is_file())
        self.assertTrue(result[ENV_USER])
        self.assertTrue(result[ENV_PASSWORD])
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_aab_selects_its_named_preset_and_matching_credentials_section(self):
        apk_key = self.existing_key("apk.keystore")
        aab_key = self.existing_key("aab.keystore")
        self.write_presets(
            android={"keystore/release": str(apk_key), "keystore/release_user": "apk-alias", "keystore/release_password": "apk-password"},
            aab={"keystore/release": str(aab_key), "keystore/release_user": "aab-alias", "keystore/release_password": "old-aab-password"},
        )
        self.write_credentials({"keystore/release_password": "aab-credential-password"}, index=7)
        result = self.prepare("Android AAB")
        self.assertEqual((result[ENV_PATH], result[ENV_USER], result[ENV_PASSWORD]),
                         (str(aab_key), "aab-alias", "aab-credential-password"))
        self.find_keytool.assert_not_called()

    def test_keytool_failure_is_reported_as_signing_error(self):
        with self.assertRaises(signing.SigningError):
            self.prepare(SIGNING_TEST_FAIL="1")
        self.assertFalse((self.root / ".android-signing" / "release.keystore").exists())
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
