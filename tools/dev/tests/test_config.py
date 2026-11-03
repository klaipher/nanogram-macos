import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

CACHE = Path("/cache")


class DerivedDataTests(unittest.TestCase):
    def test_main_checkout(self):
        self.assertEqual(config.derived_data_dir(Path("/p/nanogram-macos"), CACHE, {}), CACHE / "DerivedData")

    def test_worktree_suffix(self):
        self.assertEqual(config.derived_data_dir(Path("/p/nanogram-macos-stage2"), CACHE, {}),
                         CACHE / "DerivedData-stage2")
        self.assertEqual(config.derived_data_dir(Path("/p/nanogram-macos-runtime"), CACHE, {}),
                         CACHE / "DerivedData-runtime")

    def test_other_folder_name(self):
        self.assertEqual(config.derived_data_dir(Path("/p/nanogram"), CACHE, {}), CACHE / "DerivedData-nanogram")

    def test_env_override(self):
        env = {"NANOGRAM_DERIVED_DATA": "/elsewhere/DD"}
        self.assertEqual(config.derived_data_dir(Path("/p/nanogram-macos"), CACHE, env), Path("/elsewhere/DD"))

    def test_this_checkout(self):
        self.assertEqual(config.DERIVED_DATA,
                         config.derived_data_dir(config.ROOT, config.CACHE_DIR, __import__("os").environ))


if __name__ == "__main__":
    unittest.main()
