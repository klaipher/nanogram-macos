import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, doctor  # noqa: E402


def finding(findings, name):
    return next(f for f in findings if f.name == name)


class DoctorTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(doctor, "cache_root_size", return_value=0)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_doctor_missing_config(self):
        with tempfile.TemporaryDirectory() as empty, mock.patch.dict(os.environ, {"TG_IOS_CONFIG": empty}):
            result = finding(doctor.run_doctor(), "api-credentials")
        self.assertFalse(result.ok)
        self.assertTrue(result.required)
        self.assertIn("api-credentials.json", result.hint)

    def test_doctor_xcode_mismatch(self):
        with mock.patch.object(config, "xcode_version", return_value="26.0"):
            result = finding(doctor.run_doctor(), "xcode")
        self.assertFalse(result.ok)
        self.assertIn("27", result.hint)

    def test_doctor_xcode_27_ok(self):
        with mock.patch.object(config, "xcode_version", return_value="27.2"):
            self.assertTrue(finding(doctor.run_doctor(), "xcode").ok)

    def test_caches_over_cap_warns(self):
        with mock.patch.dict(os.environ, {"NANOGRAM_CACHE_MAX_GB": "40"}), \
                mock.patch.object(doctor, "cache_root_size", return_value=41 * 1024**3):
            result = doctor.check_caches()
        self.assertFalse(result.ok)
        self.assertFalse(result.required)
        self.assertIn("tg prune", result.hint)
        with mock.patch.object(doctor, "cache_root_size", return_value=10 * 1024**3):
            self.assertTrue(doctor.check_caches().ok)
            self.assertIn("caches", [f.name for f in doctor.run_doctor()])

    def test_require_file_raises_one_line(self):
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaises(config.ConfigError) as error:
                config.require_file(Path(empty) / "missing.json", "put it there")
        self.assertEqual(len(str(error.exception).splitlines()), 1)
        self.assertIn("put it there", str(error.exception))

    def test_submodule_check_needs_core_libvpx_and_opus(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for marker in doctor.SUBMODULE_MARKERS.values():
                if "libvpx" in marker or "opus" in marker:
                    continue
                (root / marker).parent.mkdir(parents=True, exist_ok=True)
                (root / marker).write_text("x")
            result = doctor.check_submodules(root)
            self.assertFalse(result.ok)
            self.assertIn("libvpx source", result.hint)
            self.assertIn("opus source", result.hint)
            for marker in doctor.SUBMODULE_MARKERS.values():
                (root / marker).parent.mkdir(parents=True, exist_ok=True)
                (root / marker).write_text("x")
            self.assertTrue(doctor.check_submodules(root).ok)


if __name__ == "__main__":
    unittest.main()
