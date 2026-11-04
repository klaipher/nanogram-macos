"""Sparkle EdDSA keys and signatures for the direct edition. The private key never enters the repo."""
import base64
import hashlib
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import editions, sparkle  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]

# RFC 8032 Ed25519 verification, written independently of Sparkle's C code (the reference in section 6).
P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A, B = (y1 - x1) * (y2 - x2) % P, (y1 + x1) * (y2 + x2) % P
    C, Dd = t1 * 2 * D * t2 % P, z1 * 2 * z2 % P
    E, F, G, H = B - A, Dd - C, Dd + C, B + A
    return E * F % P, G * H % P, F * G % P, E * H % P


def _mul(s, point):
    q = (0, 1, 1, 0)
    while s:
        if s & 1:
            q = _add(q, point)
        point, s = _add(point, point), s >> 1
    return q


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _decompress(data):
    y = int.from_bytes(data, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P or (x == 0 and sign):
        return None
    if x & 1 != sign:
        x = P - x
    return x, y, 1, x * y % P


BASE = _decompress((4 * pow(5, P - 2, P) % P).to_bytes(32, "little"))


def rfc8032_verify(public_key: bytes, message: bytes, signature: bytes) -> bool:
    a, r = _decompress(public_key), _decompress(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if a is None or r is None or s >= L:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public_key + message).digest(), "little") % L
    return _equal(_mul(s, BASE), _add(r, _mul(h, a)))


class SparkleKeysTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key_file = Path(self.tmp.name) / "config" / "sparkle_ed25519"

    def tearDown(self):
        self.tmp.cleanup()

    def test_sign_roundtrip(self):
        public = base64.b64decode(sparkle.ensure_keys(self.key_file))
        archive = Path(self.tmp.name) / "Nanogram.zip"
        archive.write_bytes(os.urandom(100_000))
        signature = base64.b64decode(sparkle.sign(archive, self.key_file))
        self.assertEqual((len(public), len(signature)), (32, 64))
        self.assertTrue(rfc8032_verify(public, archive.read_bytes(), signature))
        self.assertTrue(sparkle.verify(archive, base64.b64encode(signature).decode(), base64.b64encode(public).decode()))
        archive.write_bytes(archive.read_bytes()[:-1] + b"!")
        self.assertFalse(rfc8032_verify(public, archive.read_bytes(), signature))
        self.assertFalse(sparkle.verify(archive, base64.b64encode(signature).decode(), base64.b64encode(public).decode()))

    def test_rfc8032_test_vector(self):
        # RFC 8032 section 7.1, TEST 2: proves the key derivation and signing match the standard.
        seed = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
        self.key_file.parent.mkdir(mode=0o700)
        self.key_file.write_text(base64.b64encode(seed).decode() + "\n")
        self.key_file.chmod(0o600)
        message = Path(self.tmp.name) / "message"
        message.write_bytes(bytes.fromhex("72"))
        self.assertEqual(base64.b64decode(sparkle.ensure_keys(self.key_file)).hex(),
                         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
        self.assertEqual(base64.b64decode(sparkle.sign(message, self.key_file)).hex(),
                         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                         "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")

    def test_keys_are_created_once_with_private_modes(self):
        first = sparkle.ensure_keys(self.key_file)
        self.assertEqual(stat.S_IMODE(self.key_file.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.key_file.stat().st_mode), 0o600)
        content = self.key_file.read_bytes()
        self.assertEqual(sparkle.ensure_keys(self.key_file), first)
        self.assertEqual(self.key_file.read_bytes(), content)

    def test_loose_key_permissions_rejected(self):
        sparkle.ensure_keys(self.key_file)
        self.key_file.chmod(0o644)
        archive = Path(self.tmp.name) / "a.zip"
        archive.write_bytes(b"update")
        with self.assertRaisesRegex(sparkle.SparkleError, "0600"):
            sparkle.sign(archive, self.key_file)

    def test_errors_never_echo_the_key(self):
        self.key_file.parent.mkdir(mode=0o700)
        self.key_file.write_text("bm90LWEta2V5LWJ1dC1zZWNyZXQ=\n")
        self.key_file.chmod(0o600)
        with self.assertRaises(sparkle.SparkleError) as caught:
            sparkle.ensure_keys(self.key_file)
        self.assertNotIn("bm90LWEta2V5", str(caught.exception))

    def test_cli_prints_appcast_attributes_only(self):
        sparkle.ensure_keys(self.key_file)
        archive = Path(self.tmp.name) / "a.zip"
        archive.write_bytes(b"update")
        out = subprocess.run([sys.executable, "-m", "nanogram.sparkle", "--key-file", str(self.key_file), "sign", str(archive)],
                             capture_output=True, text=True, check=True, env={**os.environ, "PYTHONPATH": str(ROOT / "tools/dev")})
        self.assertRegex(out.stdout.strip(), r'^sparkle:edSignature="[A-Za-z0-9+/]{86}==" length="6"$')
        self.assertNotIn(self.key_file.read_text().strip()[:16], out.stdout + out.stderr)


class UpdaterSourceTests(unittest.TestCase):
    SOURCE = (ROOT / "Telegram-Mac/updater/NanogramUpdater.swift").read_text()

    def test_release_notes_are_plain_text_not_imported_html(self):
        self.assertNotIn("html2Attributed", self.SOURCE)
        self.assertNotIn("NSAttributedString", self.SOURCE)
        self.assertNotIn("DocumentType.html", self.SOURCE)
        self.assertIn("UpdateNotes.plainText(from: itemDescription)", self.SOURCE)

    def test_the_stale_dsa_key_entry_is_gone_from_info_plist(self):
        info = plistlib.loads((ROOT / "Telegram-Mac/Info.plist").read_bytes())
        self.assertNotIn("SUPublicDSAKeyFile", info)
        self.assertNotIn("SUPublicDSAKey", info)

    def test_info_plist_requires_a_signed_feed_and_verifies_before_extraction(self):
        info = plistlib.loads((ROOT / "Telegram-Mac/Info.plist").read_bytes())
        self.assertIs(info["SURequireSignedFeed"], True)
        self.assertIs(info["SUVerifyUpdateBeforeExtraction"], True)

    def test_sparkle_accepts_exactly_the_signing_block_we_write(self):
        reader = (ROOT / "submodules/Sparkle/Sparkle/SPUExtractSignedFeed.m").read_text()
        self.assertIn('"<!-- sparkle-signatures:\\n"', reader)
        self.assertIn('@"edSignature:"', reader)
        self.assertIn('@"length:"', reader)


class RepositoryKeyTests(unittest.TestCase):
    """The owner's real key in ~/.config/nanogram-macos: public half in the repo, private half never."""

    def setUp(self):
        if not sparkle.KEY_FILE.exists():
            self.skipTest(f"no Sparkle key yet: tools/dev/tg sparkle-key creates {sparkle.KEY_FILE}")

    def test_private_key_never_in_repo(self):
        secret = sparkle.KEY_FILE.read_text().strip()
        for prefix in {secret[:16], base64.b64decode(secret)[:12].hex()}:
            found = subprocess.run(["git", "grep", "-q", "--untracked", "-F", "-e", prefix], cwd=ROOT)
            self.assertEqual(found.returncode, 1, "the Sparkle private key (or its prefix) is in the repository")
        self.assertEqual(stat.S_IMODE(sparkle.KEY_FILE.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(sparkle.KEY_FILE.parent.stat().st_mode), 0o700)

    def test_direct_xcconfig_carries_our_public_key(self):
        text = (ROOT / "nanogram/editions/direct.xcconfig").read_text()
        match = re.search(r"^SPARKLE_ED_PUBLIC_KEY = (\S+)$", text, re.M)
        self.assertIsNotNone(match, "direct.xcconfig sets no SPARKLE_ED_PUBLIC_KEY")
        self.assertEqual(match.group(1), sparkle.ensure_keys())

    def test_built_direct_app_has_feed_and_key(self):
        try:
            app = editions.stashed_app(os.environ.get("NANOGRAM_EDITIONS_CONFIGURATION", "Debug"), "direct")
        except FileNotFoundError:
            self.skipTest("build the direct edition first: tg build --edition direct")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info.get("SUPublicEDKey"), sparkle.ensure_keys())
        self.assertEqual(info.get("SUFeedURL"), sparkle.FEED_URL)
        self.assertNotIn("SUPublicDSAKeyFile", info)
        for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableInstallerLauncherService",
                    "SUEnableDownloaderService"):
            self.assertIs(info.get(key), True, key)


if __name__ == "__main__":
    unittest.main()
