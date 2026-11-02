import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, credentials  # noqa: E402

FAKE_HASH = "0123456789abcdef0123456789abcdef"


class CredentialsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.src = self.dir / "api-credentials.json"
        self.dst = self.dir / "out" / "NanogramSecrets.swift"

    def write_src(self, api_id="12345", api_hash=FAKE_HASH):
        self.src.write_text(json.dumps({"api_id": api_id, "api_hash": api_hash}))

    def test_credentials_missing_fails(self):
        with self.assertRaises(config.ConfigError) as error:
            credentials.write_secrets(self.src, self.dst)
        message = str(error.exception)
        self.assertIn("api-credentials.json missing", message)
        self.assertIn("~/.config/telegram-ios/", message)
        self.assertEqual(len(message.splitlines()), 1)
        self.assertFalse(self.dst.exists())

    def test_secrets_not_rewritten_when_unchanged(self):
        self.write_src()
        credentials.write_secrets(self.src, self.dst)
        first = self.dst.stat().st_mtime_ns
        os.utime(self.dst, ns=(first - 10_000_000_000, first - 10_000_000_000))
        before = self.dst.stat().st_mtime_ns
        credentials.write_secrets(self.src, self.dst)
        self.assertEqual(self.dst.stat().st_mtime_ns, before)

    def test_secrets_rewritten_when_changed(self):
        self.write_src(api_id="1")
        credentials.write_secrets(self.src, self.dst)
        self.write_src(api_id="2")
        credentials.write_secrets(self.src, self.dst)
        self.assertIn("apiId: Int32 = 2\n", self.dst.read_text())

    def test_generated_file_content_and_mode(self):
        self.write_src(api_id=12345)
        self.dst.parent.mkdir()
        self.dst.write_text("old")
        os.chmod(self.dst, 0o644)
        credentials.write_secrets(self.src, self.dst)
        text = self.dst.read_text()
        self.assertIn("enum NanogramSecrets {", text)
        self.assertIn("static let apiId: Int32 = 12345\n", text)
        self.assertIn(f'static let apiHash: String = "{FAKE_HASH}"\n', text)
        self.assertEqual(stat.S_IMODE(self.dst.stat().st_mode), 0o600)

    def test_malformed_credentials_fail_without_echoing_hash(self):
        bad_hash = 'abc"; evil()'
        for api_id, api_hash in (("x", FAKE_HASH), ("12345", bad_hash), ("99999999999", FAKE_HASH)):
            with self.subTest(api_id=api_id):
                self.write_src(api_id=api_id, api_hash=api_hash)
                with self.assertRaises(config.ConfigError) as error:
                    credentials.write_secrets(self.src, self.dst)
                self.assertNotIn(bad_hash, str(error.exception))
                self.assertNotIn(FAKE_HASH, str(error.exception))
        self.assertFalse(self.dst.exists())

    def test_generated_file_is_gitignored(self):
        result = subprocess.run(
            ["git", "check-ignore", "-q", str(credentials.SECRETS_SWIFT)], cwd=config.ROOT)
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
