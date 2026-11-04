"""The UTF-16 .strings merge driver: upstream additions and our edits to different lines merge without a conflict."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DRIVER = ROOT / "tools" / "dev" / "git" / "utf16-merge.sh"


def write(path: Path, text: str) -> None:
    path.write_bytes(b"\xff\xfe" + text.encode("utf-16-le"))


def read(path: Path) -> str:
    return path.read_bytes().decode("utf-16")


class Utf16MergeDriverTests(unittest.TestCase):
    def merge(self, base, ours, theirs):
        with tempfile.TemporaryDirectory() as tmp:
            files = [Path(tmp) / name for name in ("base", "ours", "theirs")]
            for path, text in zip(files, (base, ours, theirs)):
                write(path, text)
            result = subprocess.run([str(DRIVER), *map(str, files), "7", "x"], capture_output=True, text=True)
            return result.returncode, files[1].read_bytes(), read(files[1])

    BASE = '"A" = "one";\n"B" = "Telegram quit";\n"C" = "three";\n'

    def test_disjoint_edits_merge_cleanly_and_stay_utf16_with_a_bom(self):
        status, raw, text = self.merge(self.BASE, self.BASE.replace("Telegram quit", "Nanogram quit"), self.BASE + '"D" = "new";\n')
        self.assertEqual(status, 0)
        self.assertEqual(raw[:2], b"\xff\xfe")
        self.assertIn('"B" = "Nanogram quit";', text)
        self.assertIn('"D" = "new";', text)

    def test_non_ascii_text_survives(self):
        status, _, text = self.merge(self.BASE, self.BASE.replace("one", "один"), self.BASE.replace("three", "три"))
        self.assertEqual(status, 0)
        self.assertIn("один", text)
        self.assertIn("три", text)

    def test_the_same_line_changed_on_both_sides_is_a_conflict(self):
        status, _, text = self.merge(self.BASE, self.BASE.replace("one", "ours"), self.BASE.replace("one", "theirs"))
        self.assertGreater(status, 0)
        self.assertIn("<<<<<<<", text)

    def test_the_repository_registers_the_driver_for_strings_files(self):
        attributes = (ROOT / ".gitattributes").read_text()
        self.assertIn("Telegram-Mac/*.lproj/Localizable.strings diff=utf16 merge=utf16strings", attributes)
        self.assertIn("merge.utf16strings.driver", (ROOT / "tools" / "dev" / "git" / "setup.sh").read_text())


if __name__ == "__main__":
    unittest.main()
