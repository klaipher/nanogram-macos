"""Nanogram's name and artwork in the checkout: identity string keys, Telegram's icons, the login plane, alert titles."""
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import branding, config  # noqa: E402

KEYS_SWIFT = '''extension BrandingStrings {
    static let identityKeys: Set<String> = [
        "Login.QR.Title",
        "StatusBar.Activate",
    ]

    static let englishTexts: [String: String] = [
        "Login.EnterCodeFromApp": "We've sent the code.",
    ]
}
'''
STRINGS = '"Login.QR.Title" = "Log in to Telegram by QR Code";\n"StatusBar.Activate_other" = "Show Telegram";\n'


def checkout(directory: Path) -> Path:
    root = directory / "repo"
    (root / branding.IDENTITY_KEYS).parent.mkdir(parents=True)
    (root / branding.IDENTITY_KEYS).write_text(KEYS_SWIFT)
    (root / branding.ENGLISH_STRINGS).parent.mkdir(parents=True)
    (root / branding.ENGLISH_STRINGS).write_bytes(STRINGS.encode("utf-16"))
    (root / branding.COMET_LOGO).parent.mkdir(parents=True)
    (root / branding.COMET_LOGO).write_bytes(b"%PDF")
    (root / "TelegramShare").mkdir()
    (root / "packages" / "AuthUI").mkdir(parents=True)
    return root


class SourceCheckTests(unittest.TestCase):
    def test_a_clean_checkout_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = checkout(Path(tmp))
            self.assertEqual(branding.identity_keys(root), {"Login.QR.Title", "StatusBar.Activate"})
            self.assertEqual(branding.check_sources(root), [])

    def test_an_identity_key_renamed_upstream_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = checkout(Path(tmp))
            (root / branding.ENGLISH_STRINGS).write_bytes(STRINGS.replace("Login.QR.Title", "Login.QR.Header")
                                                          .encode("utf-16"))
            self.assertEqual(branding.check_sources(root),
                             [f"identity key Login.QR.Title is not in {branding.ENGLISH_STRINGS}"])

    def test_telegram_artwork_and_the_plane_animation_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = checkout(Path(tmp))
            plane = b"telegram plane"
            icon = root / "Telegram-Mac" / "Assets.xcassets" / "StatusIcon.imageset" / "StatusIcon.png"
            icon.parent.mkdir(parents=True)
            icon.write_bytes(plane)
            (root / "packages" / "AuthUI" / "Login.swift").write_text("let data = LocalAnimatedSticker.login_airplane.data\n")
            (root / "packages" / "AuthUI" / "Alert.swift").write_text('func alert(header: String? = "Telegram") {}\n')
            (root / branding.COMET_LOGO).unlink()
            original = dict(branding.TELEGRAM_ARTWORK)
            branding.TELEGRAM_ARTWORK[hashlib.sha256(plane).hexdigest()] = "menu bar plane"
            try:
                problems = branding.check_sources(root)
            finally:
                branding.TELEGRAM_ARTWORK.clear()
                branding.TELEGRAM_ARTWORK.update(original)
            self.assertEqual(problems, [
                "Telegram-Mac/Assets.xcassets/StatusIcon.imageset/StatusIcon.png is Telegram's menu bar plane",
                f"{branding.COMET_LOGO} is missing",
                'packages/AuthUI/Alert.swift titles alerts "Telegram" by default',
                "packages/AuthUI/Login.swift uses Telegram's plane animation (login_airplane)",
            ])

    def test_the_checkout_shows_nanogram_not_telegram(self):
        self.assertEqual(branding.check_sources(config.ROOT), [])
        self.assertGreaterEqual(len(branding.identity_keys(config.ROOT)), 60)


if __name__ == "__main__":
    unittest.main()
