"""The parity gate and its tests live in the core's shared/ submodule (klaipher/nanogram-deps, tests/test_parity.py). These
tests cover what is specific to this repository: its docs/mac-core-paths.txt and the thin wrappers around shared/."""
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SHARED = ROOT / "submodules" / "telegram-ios" / "shared"
sys.path.insert(0, str(SHARED))

needs_shared = unittest.skipUnless((SHARED / "parity.py").is_file(), "the core's shared/ submodule is not checked out")


@needs_shared
class RepositoryConfigTests(unittest.TestCase):
    def setUp(self):
        import parity
        self.parity = parity
        self.config = parity.load_config(ROOT)

    def test_repository_file_parses(self):
        self.assertTrue(self.config.core_roots and self.config.shares and self.config.pins)
        self.assertTrue(all(a.reason for a in self.config.allows))

    def test_no_mirror_lines_remain(self):
        self.assertEqual(self.config.mirrors, [])

    def test_every_lib_line_is_known_to_the_manifest(self):
        known = set(json.loads((SHARED / "shared-libraries.json").read_text())["libraries"])
        self.assertTrue(self.config.libs)
        self.assertEqual([lib.name for lib in self.config.libs if lib.name not in known], [])

    def test_no_vendored_policy_or_doc_copies_remain(self):
        for path in ("tools/dev/cachegc/cache-policy.json", "docs/feature-parity.md", "docs/development-pipeline.md"):
            self.assertFalse((ROOT / path).exists(), path)

    def test_the_mac_file_is_the_ios_file(self):
        ios = ROOT / "submodules" / "telegram-ios" / "docs" / "mac-core-paths.txt"
        if not ios.is_file():
            self.skipTest("core docs not checked out")
        self.assertEqual((ROOT / "docs" / "mac-core-paths.txt").read_bytes(), ios.read_bytes())


@needs_shared
class WrapperTests(unittest.TestCase):
    def run_wrapper(self, *args):
        return subprocess.run([sys.executable, str(ROOT / args[0]), *args[1:]], capture_output=True, text=True, check=False)

    def test_parity_wrapper_forwards_to_shared(self):
        result = self.run_wrapper("tools/dev/parity/parity.py", "check", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--android-repo", result.stdout)

    def test_check_shared_wrapper_defaults_to_the_mac_side(self):
        result = self.run_wrapper("tools/dev/native/check_shared.py", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--side", result.stdout)

    def test_wrappers_hold_no_copy_of_the_tools(self):
        for path in ("tools/dev/parity/parity.py", "tools/dev/native/check_shared.py"):
            self.assertLess(len((ROOT / path).read_text().splitlines()), 40, path)

    def test_the_loader_imports_the_shared_gate(self):
        sys.path.insert(0, str(ROOT / "tools" / "dev"))
        from nanogram.parity_loader import parity
        self.assertTrue(hasattr(parity, "load_config"))


if __name__ == "__main__":
    unittest.main()
