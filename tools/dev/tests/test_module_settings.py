import sys
import tempfile
import unittest
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[1] / "native"
sys.path.insert(0, str(NATIVE))

import module_settings as ms  # noqa: E402


class ModuleSettingsTests(unittest.TestCase):
    def test_package_mode(self):
        self.assertEqual(ms.package_mode("// swift-tools-version:5.5\n"), "5")
        self.assertEqual(ms.package_mode("// swift-tools-version:6.2\n"), "6")
        self.assertEqual(ms.package_mode("// swift-tools-version:5.9\nswiftLanguageModes: [.v6]"), "6")
        self.assertEqual(ms.package_mode("// swift-tools-version:6.0\n.swiftLanguageMode(.v5) .swiftLanguageMode(.v6)"), "mixed")

    def test_ios_build_rules(self):
        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / "submodules/A/BUILD"
            build.parent.mkdir(parents=True)
            build.write_text('load("x")\nswift6_library(\n    name = "A",\n    module_name = "AMod",\n)\n'
                             'swift_library(\n    name = "B",\n    srcs = [],\n)\n')
            self.assertEqual(ms.ios_modules(Path(tmp)), {"AMod": "6", "B": "5"})

    def test_mac_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "packages/P/Package.swift"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('// swift-tools-version:6.2\n.target(name: "P"), .testTarget(name: "PTests")\n')
            self.assertEqual(ms.mac_modules(Path(tmp)), {"P": "6"})

    def test_repository_table_is_current(self):
        here = Path(__file__).resolve().parents[3]
        ios = here if (here / "MODULE.bazel").is_file() else here.parent / "nanogram-ios"
        mac = here if (here / "core-xprojects").is_dir() else here.parent / "nanogram-macos"
        if not (ios.is_dir() and mac.is_dir()):
            self.skipTest("needs both repositories side by side")
        self.assertEqual(ms.main(["--check", "--ios", str(ios), "--mac", str(mac)]), 0)


if __name__ == "__main__":
    unittest.main()
