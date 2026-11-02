import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import warnings  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def fixture_log() -> str:
    return (FIXTURES / "warnings.log").read_text()


class CountTests(unittest.TestCase):
    def test_duplicates_counted_once(self):
        line = "/ROOT/packages/TGUIKit/Sources/A.swift:1:2: warning: deprecated\n"
        self.assertEqual(warnings.count(line * 3, root="/ROOT"), {"TGUIKit": 1})
        other = "/ROOT/packages/TGUIKit/Sources/A.swift:1:2: warning: another warning on the same spot\n"
        self.assertEqual(warnings.count(line + other + line, root="/ROOT"), {"TGUIKit": 2})

    def test_package_attribution(self):
        self.assertEqual(warnings.count(fixture_log(), root="/ROOT"), {
            "TGUIKit": 2,             # packages/<P>/ (one line repeated, the indented excerpt not counted)
            "TelegramCore": 1,        # submodules/telegram-ios/submodules/<P>/
            "sqlcipher": 1,
            "rnnoise": 1,             # submodules/telegram-ios/third-party/<P>/
            "Sparkle": 1,             # submodules/<P>/
            "app": 2,                 # Telegram-Mac/ and paths outside the repo
        })

    def test_our_packages_excluded(self):
        counts = warnings.count(fixture_log(), root="/ROOT")
        self.assertNotIn("NanogramKit", counts)
        self.assertNotIn("NanogramUpdater", counts)

    def test_root_with_trailing_slash(self):
        line = "/ROOT/packages/Colors/Sources/C.swift:1:2: warning: w\n"
        self.assertEqual(warnings.count(line, root="/ROOT/"), {"Colors": 1})


class CompareTests(unittest.TestCase):
    def test_increase_reported(self):
        self.assertEqual(warnings.compare({"TGUIKit": 2, "app": 1}, {"TGUIKit": 3, "app": 1}), ["TGUIKit"])

    def test_new_package_is_an_increase(self):
        self.assertEqual(warnings.compare({"TGUIKit": 2}, {"TGUIKit": 2, "ChatUI": 1}), ["ChatUI"])

    def test_decrease_ok(self):
        self.assertEqual(warnings.compare({"TGUIKit": 5, "ChatUI": 2}, {"TGUIKit": 1}), [])


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="warnings-test-"))
        self.log = self.dir / "build.log"
        self.log.write_text(fixture_log())
        self.baseline = self.dir / "warnings-baseline.json"

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = warnings.main(["--log", str(self.log), "--baseline", str(self.baseline), "--root", "/ROOT", *args])
        return status, out.getvalue(), err.getvalue()

    def test_update_writes_sorted_baseline(self):
        status, _, _ = self.run_main("--update")
        self.assertEqual(status, 0)
        data = json.loads(self.baseline.read_text())
        self.assertEqual(data["TGUIKit"], 2)
        self.assertEqual(list(data), sorted(data))

    def test_increase_fails_with_package_named(self):
        self.baseline.write_text(json.dumps({"TGUIKit": 1, "TelegramCore": 1, "sqlcipher": 1, "rnnoise": 1,
                                             "Sparkle": 1, "app": 2}))
        status, _, err = self.run_main()
        self.assertEqual(status, 1)
        self.assertIn("TGUIKit: 1 -> 2", err)

    def test_equal_or_lower_passes(self):
        self.baseline.write_text(json.dumps({"TGUIKit": 9, "TelegramCore": 1, "sqlcipher": 1, "rnnoise": 1,
                                             "Sparkle": 1, "app": 2}))
        status, out, _ = self.run_main()
        self.assertEqual(status, 0)
        self.assertIn("TGUIKit: 9 -> 2", out)

    def test_missing_baseline_fails_with_hint(self):
        status, _, err = self.run_main()
        self.assertEqual(status, 1)
        self.assertIn("--update", err)

    def test_log_without_build_succeeded_fails(self):
        self.log.write_text("/ROOT/packages/A/x.swift:1:1: warning: w\n** BUILD FAILED **\n")
        status, _, err = self.run_main("--update")
        self.assertEqual(status, 1)
        self.assertFalse(self.baseline.exists())
        self.assertIn("BUILD SUCCEEDED", err)


class RepoBaselineTests(unittest.TestCase):
    def test_checked_in_baseline_is_sorted_counts(self):
        path = Path(__file__).resolve().parents[3] / "nanogram" / "warnings-baseline.json"
        data = json.loads(path.read_text())
        self.assertEqual(list(data), sorted(data))
        self.assertTrue(all(isinstance(v, int) and v > 0 for v in data.values()))
        self.assertFalse(any(k == "NanogramKit" or k.startswith("Nanogram") for k in data))


if __name__ == "__main__":
    unittest.main()
