"""The Share extension opens the account manager with the failable open (iOS spec I-26) and shows the unauthorized
screen instead of crashing when the databases cannot be opened."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

SHARE = config.ROOT / "TelegramShare" / "ShareViewController.swift"


class ShareExtensionDatabaseOpenTests(unittest.TestCase):
    def setUp(self):
        self.text = SHARE.read_text(encoding="utf-8")

    def test_the_share_extension_uses_the_failable_open(self):
        self.assertIn("AccountManager<TelegramAccountManagerTypes>.openForExtension(", self.text)

    def test_it_never_uses_the_app_open_that_traps_and_removes_databases(self):
        self.assertIsNone(re.search(r"=\s*AccountManager<TelegramAccountManagerTypes>\(", self.text))
        self.assertNotIn("removeDatabaseOnError: true", self.text)

    def test_a_failed_open_shows_the_unauthorized_screen_and_returns(self):
        match = re.search(r"openForExtension\(.*?else \{(.*?)\n        \}", self.text, re.S)
        self.assertIsNotNone(match)
        self.assertIn("presentAccountsUnavailable()", match.group(1))
        self.assertIn("return", match.group(1))
        self.assertIn("SEUnauthorizedViewController(", self.text)

    def test_the_new_code_has_no_comments_or_force_unwraps(self):
        start = self.text.index("private func presentAccountsUnavailable")
        end = self.text.index("private func launchExtension")
        body = self.text[start:end]
        self.assertNotIn("//", body)
        self.assertIsNone(re.search(r"\w!(?![=])", body))


if __name__ == "__main__":
    unittest.main()
