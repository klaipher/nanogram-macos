import json
import sys
import tempfile
import unittest
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[1] / "native"
sys.path.insert(0, str(NATIVE))

import check_native_libs as native  # noqa: E402


def fake_repo(root: Path, rust="1.99.1", flags="--enable-a --disable-b"):
    (root / "core-xprojects").mkdir(parents=True)
    (root / "core-xprojects/rust-toolchain.toml").write_text(f'[toolchain]\nchannel = "{rust}"\n')
    (root / "core-xprojects/build.sh").write_text(f'X=1\nCONFIGURE_FLAGS="{flags} \\\n  --enable-c=y,x"\nnext\n')
    (root / "core-xprojects/lib-2.5.tar.gz").write_bytes(b"abc")


def data():
    probe = {"id": "p", "kind": "regex", "file": "core-xprojects/rust-toolchain.toml", "what": "version",
             "regex": r'channel = "([\d.]+)"'}
    return {"libs": {
        "rust": {"probes": {"mac": [probe]}, "version": {"shared": "1.99.1"}},
        "lib": {"probes": {"mac": [
            {"id": "n", "kind": "filename", "what": "version", "file": "core-xprojects/lib-*.tar.gz", "regex": r"^lib-([\d.]+)\.tar\.gz$"},
            {"id": "s", "kind": "sha256", "what": "sha256", "file": "core-xprojects/lib-*.tar.gz"},
            {"id": "f", "kind": "flags", "what": "flags", "file": "core-xprojects/build.sh",
             "region": [r'^CONFIGURE_FLAGS="', r'"\s*$']}]},
            "version": {"shared": "2.5"},
            "sha256": {"mac": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
            "flags": {"mac": ["--disable-b", "--enable-a", "--enable-c=x,y"]}}}}


class NativeLibsTests(unittest.TestCase):
    def test_matching_repo_is_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_repo(Path(tmp))
            self.assertEqual(native.check(Path(tmp), data()), [])

    def test_one_sided_bump_is_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_repo(Path(tmp), rust="1.99.2")
            problems = native.check(Path(tmp), data())
            self.assertEqual(len(problems), 1)
            self.assertIn("rust.version", problems[0])

    def test_flag_change_is_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_repo(Path(tmp), flags="--enable-a --enable-new")
            self.assertTrue(any("lib.flags" in p for p in native.check(Path(tmp), data())))

    def test_unlisted_difference_between_sides_is_drift(self):
        d = data()
        d["libs"]["lib"]["version"] = {"ios": "2.4", "mac": "2.5"}
        with tempfile.TemporaryDirectory() as tmp:
            fake_repo(Path(tmp))
            self.assertTrue(any("not under known_differences" in p for p in native.check(Path(tmp), d)))
            d["known_differences"] = {"lib.version": "reason"}
            self.assertEqual(native.check(Path(tmp), d), [])

    def test_stale_known_difference_is_reported(self):
        d = data()
        d["known_differences"] = {"lib.version": "reason"}
        with tempfile.TemporaryDirectory() as tmp:
            fake_repo(Path(tmp))
            self.assertTrue(any("remove the entry" in p for p in native.check(Path(tmp), d)))

    def test_repository_files_agree(self):
        root = Path(__file__).resolve().parents[3]
        self.assertEqual(native.check(root, native.load()), [])
        self.assertTrue(json.loads(native.DATA.read_text())["libs"])


if __name__ == "__main__":
    unittest.main()
