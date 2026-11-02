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

    def test_require_file_raises_one_line(self):
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaises(config.ConfigError) as error:
                config.require_file(Path(empty) / "missing.json", "put it there")
        self.assertEqual(len(str(error.exception).splitlines()), 1)
        self.assertIn("put it there", str(error.exception))


if __name__ == "__main__":
    unittest.main()
