"""Privacy guards on the Mac sources (no build). The shared core's side of this (no read metrics, music
listening, call logs, analytics events; trimmed connection fingerprint) is checked by the core's own
tools/dev/tests/test_privacy.py; this file covers what lives only in the Mac app.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = Path(config.ROOT)


def swift_sources():
    for base in ("packages", "Telegram-Mac", "nanogram"):
        for path in (ROOT / base).rglob("*.swift"):
            parts = path.relative_to(ROOT).parts
            if "Tests" in parts or ".build" in parts:
                continue
            yield path


def lines_matching(pattern):
    regex = re.compile(pattern)
    found = []
    for path in swift_sources():
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if regex.search(line) and not line.lstrip().startswith("//"):
                found.append("%s:%d" % (path.relative_to(ROOT), number))
    return found


class MacPrivacyTests(unittest.TestCase):
    def test_read_metrics_manager_is_gone(self):
        self.assertEqual(lines_matching(r"MessageReadMetricsManager|readMetricsManager"), [])
        self.assertFalse((ROOT / "packages/ChatUI/Sources/ChatUI/MessageReadMetricsManager.swift").exists())

    def test_nothing_reports_read_metrics_or_music(self):
        self.assertEqual(lines_matching(r"reportPeerReadMetrics|reportMusicListened"), [])

    def test_calls_do_not_upload_logs(self):
        self.assertEqual(lines_matching(r"\bsaveCallDebugLog\(|saveCompleteCallDebugLog\("), [])

    def test_device_model_is_the_family_unless_the_user_renamed_it(self):
        source = (ROOT / "Telegram-Mac/app/AppDelegate.swift").read_text(encoding="utf-8")
        self.assertIn('let systemDeviceModel = "Mac"', source)
        self.assertNotIn("let systemDeviceModel = deviceModelPretty()", source)

    def test_no_network_is_given_the_exact_model(self):
        # The share extension opens its own connection; it must send the same family the app does.
        share = (ROOT / "TelegramShare/ShareViewController.swift").read_text(encoding="utf-8")
        self.assertIn('deviceModelName: ApiEnvironment.customDeviceModel ?? "Mac"', share)
        found = []
        for path in list(swift_sources()) + [ROOT / "TelegramShare/ShareViewController.swift"]:
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if re.search(r"deviceModelName:[^,]*deviceModelPretty\(\)", line):
                    found.append("%s:%d" % (path.relative_to(ROOT), number))
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
