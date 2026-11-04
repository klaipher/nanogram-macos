"""Fork-owned Swift packages follow the NanogramKit convention (round-2 spec R2-17).

Each one declares tools 6.2, Swift 6 language mode and warnings as errors. The floor is macOS 15 unless an upstream
package (still at 10.13) depends on it: SwiftPM refuses a dependency whose minimum is above its dependent's.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

PACKAGES = config.ROOT / "packages"
FORK_PACKAGES = ("NanogramKit", "ChatAppIntents", "NanogramDebug", "VoiceRecorderInput", "VP9Hardware",
                 "LocalAudioTranscription", "NanogramAppIcons", "NanogramDecoder")
PENDING_SWIFT6 = ("NanogramRuntime",)
UPSTREAM_DEPENDENTS_KEEP_FLOOR = ("NanogramDebug", "VoiceRecorderInput", "VP9Hardware", "LocalAudioTranscription",
                                  "NanogramRuntime", "NanogramAppIcons")


def manifest(name: str) -> str:
    return (PACKAGES / name / "Package.swift").read_text()


def upstream_dependents(name: str) -> list[str]:
    dependents = []
    for path in PACKAGES.glob("*/Package.swift"):
        package = path.parent.name
        if package == name or package in FORK_PACKAGES or package in PENDING_SWIFT6:
            continue
        if re.search(r'"\.\./' + re.escape(name) + r'"', path.read_text()):
            dependents.append(package)
    return dependents


class ForkPackageTests(unittest.TestCase):
    def test_fork_packages_use_swift_6_and_warnings_as_errors(self):
        for name in FORK_PACKAGES:
            text = manifest(name)
            with self.subTest(package=name):
                self.assertTrue(text.startswith("// swift-tools-version:6.2"), name)
                self.assertIn("swiftLanguageModes: [.v6]", text)
                self.assertIn(".treatAllWarnings(as: .error)", text)

    def test_floor_is_15_unless_an_upstream_package_depends_on_it(self):
        for name in FORK_PACKAGES + PENDING_SWIFT6:
            text = manifest(name)
            with self.subTest(package=name):
                if name in UPSTREAM_DEPENDENTS_KEEP_FLOOR:
                    self.assertTrue(upstream_dependents(name), f"{name} has no upstream dependent; raise it to .v15")
                else:
                    self.assertIn(".macOS(.v15)", text)

    def test_nanogram_packages_are_all_listed(self):
        for path in PACKAGES.glob("Nanogram*/Package.swift"):
            self.assertIn(path.parent.name, FORK_PACKAGES + PENDING_SWIFT6)


if __name__ == "__main__":
    unittest.main()
