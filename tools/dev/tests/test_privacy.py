"""Privacy guards on the Mac sources (no build). The shared core's side of this (no call-log uploads,
analytics events, time zone offset) is checked by the core's own
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
    def test_channel_read_metrics_are_measured_as_upstream(self):
        # Channel owners see their statistics as usual (owner, 2026-11-05).
        self.assertNotEqual(lines_matching(r"MessageReadMetricsManager\(context:"), [])
        self.assertTrue((ROOT / "packages/ChatUI/Sources/ChatUI/MessageReadMetricsManager.swift").exists())

    def test_calls_do_not_upload_logs(self):
        self.assertEqual(lines_matching(r"\bsaveCallDebugLog\(|saveCompleteCallDebugLog\("), [])

    def test_device_model_is_the_real_model(self):
        # The owner wants the exact model in the session list (2026-11-05), in the app and the share extension.
        source = (ROOT / "Telegram-Mac/app/AppDelegate.swift").read_text(encoding="utf-8")
        self.assertIn("let systemDeviceModel = deviceModelPretty()", source)
        share = (ROOT / "TelegramShare/ShareViewController.swift").read_text(encoding="utf-8")
        self.assertIn("deviceModelName: ApiEnvironment.customDeviceModel ?? deviceModelPretty()", share)

if __name__ == "__main__":
    unittest.main()
