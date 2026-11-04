"""Every reader of the stored auto-download and autoplay settings goes through the Lockdown policy (hardening, 2026-11-04).

`AutomaticMediaDownloadSettings.effective(_:)` and `AutoplayMediaPreferences.effective(_:)` in InAppSettings apply
`HardenedMediaPolicy`. Decoding a stored entry anywhere else bypasses it: the chat history and the account context did,
so under Lockdown Mode the chat still auto-downloaded and autoplayed media. Settings screens that show the stored
choice itself are the only exceptions, and they only display it.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
RAW_DECODE = re.compile(r"\.get\((AutomaticMediaDownloadSettings|AutoplayMediaPreferences)\.self\)")

DISPLAY_ONLY = {
    "packages/DataUsageUI/Sources/DataUsageUI/DataAndStorageViewController.swift": "shows the stored auto-download switch",
    "packages/StickerSettingsUI/Sources/StickerSettingsUI/InstalledStickerPacksController.swift": "shows the stored loop switch",
}
POLICY_HOME = {
    "packages/InAppSettings/Sources/InAppSettings/AutomaticMediaDownloadCategoryPeers.swift",
    "packages/InAppSettings/Sources/InAppSettings/AutoplayPreferences.swift",
}


def swift_sources():
    for top in ("packages", "Telegram-Mac", "TelegramShare"):
        base = ROOT / top
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            parts = path.relative_to(ROOT).parts
            if ".build" in parts or "Tests" in parts:
                continue
            yield path


class HardenedMediaReaderTests(unittest.TestCase):
    def test_stored_settings_are_only_decoded_where_the_policy_is_applied(self):
        offenders = []
        for path in swift_sources():
            relative = path.relative_to(ROOT).as_posix()
            if relative in POLICY_HOME or relative in DISPLAY_ONLY:
                continue
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if RAW_DECODE.search(line):
                    offenders.append(f"{relative}:{number}")
        self.assertEqual(offenders, [], "decode through AutomaticMediaDownloadSettings.effective / AutoplayMediaPreferences.effective")

    def test_the_policy_home_hardens_what_it_decodes(self):
        for relative in POLICY_HOME:
            text = (ROOT / relative).read_text()
            self.assertIn("func effective(", text, relative)
            self.assertIn(".hardened(by: policy)", text, relative)

    def test_the_display_exceptions_still_exist(self):
        for relative in DISPLAY_ONLY:
            self.assertTrue((ROOT / relative).exists(), relative)


if __name__ == "__main__":
    unittest.main()
