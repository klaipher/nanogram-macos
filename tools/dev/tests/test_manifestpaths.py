"""Local SwiftPM paths must point at real packages (shared-code lane, 2026-11-05)."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, manifestpaths  # noqa: E402


def write(path: Path, text: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def package(root: Path, group: str, name: str, deps: str = "") -> None:
    write(root / group / name / "Package.swift", f'// swift-tools-version:5.9\nlet package = Package(name: "{name}", dependencies: [{deps}])\n')


class LocalPathsTests(unittest.TestCase):
    def test_package_call_and_tuple_lists_are_read(self):
        text = '''
let deps: [(String, String)] = [
    ("Svg", "../Svg"),
    ("BuildConfig", "../../submodules/BuildConfig"),
]
let package = Package(name: "X", dependencies: [
    .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
    .package(url: "https://example.com/a.git", from: "1.0.0"),
] + deps.map { .package(name: $0.0, path: $0.1) },
targets: [.target(name: "X", path: "Sources/X")])
'''
        self.assertEqual(manifestpaths.local_paths(text), [
            "../Svg",
            "../../submodules/BuildConfig",
            "../../submodules/telegram-ios/submodules/SSignalKit",
        ])

    def test_target_source_paths_are_not_dependencies(self):
        self.assertEqual(manifestpaths.local_paths('.target(name: "X", path: "../Elsewhere/Sources")'), [])


class CheckTests(unittest.TestCase):
    def test_clean_tree_has_no_problems(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package(root, "packages", "Svg")
            package(root, "packages", "WebAppUI", '.package(name: "Svg", path: "../Svg")')
            self.assertEqual(manifestpaths.check(root), [])

    def test_directory_without_manifest_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root / "submodules" / "telegram-ios" / "submodules" / "Svg" / "Sources" / "a.swift")
            package(root, "packages", "WebAppUI", '.package(name: "Svg", path: "../../submodules/telegram-ios/submodules/Svg")')
            problems = manifestpaths.check(root)
            self.assertEqual(len(problems), 1)
            self.assertIn("packages/WebAppUI/Package.swift", problems[0])
            self.assertIn("has no Package.swift", problems[0])

    def test_missing_directory_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package(root, "packages", "AudioPlayerCore", '.package(name: "TelegramMediaResources", path: "../TelegramMediaResources")')
            self.assertIn("does not exist", manifestpaths.check(root)[0])

    def test_same_directory_name_twice_is_an_identity_clash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package(root, "packages", "VoiceRecorderInput")
            package(root, "submodules", "VoiceRecorderInput")
            package(root, "packages", "App",
                    '.package(name: "A", path: "../VoiceRecorderInput"), .package(name: "B", path: "../../submodules/VoiceRecorderInput")')
            self.assertTrue(any("two different directories named VoiceRecorderInput" in p for p in manifestpaths.check(root)))

    def test_paths_into_an_unpopulated_submodule_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root / ".gitmodules", '[submodule "telegram-ios"]\n\tpath = submodules/telegram-ios\n\turl = x\n')
            (root / "submodules" / "telegram-ios").mkdir(parents=True)
            package(root, "packages", "P", '.package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit")')
            self.assertEqual(manifestpaths.check(root), [])
            write(root / "submodules" / "telegram-ios" / "README")
            self.assertEqual(len(manifestpaths.check(root)), 1)


class RepositoryTests(unittest.TestCase):
    def test_every_local_path_in_this_repository_points_at_a_package(self):
        self.assertEqual(manifestpaths.check(config.ROOT), [])


if __name__ == "__main__":
    unittest.main()
