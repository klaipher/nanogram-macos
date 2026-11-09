"""Spotlight and Launchpad list every Nanogram.app that LaunchServices knows; tg keeps that list to one copy."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import appregistry  # noqa: E402

SEPARATOR = "-" * 80


def record(path: str, identifier: str, name: str = "Nanogram") -> str:
    return "\n".join([
        f"path:                       {path} (0x4e94)",
        f"name:                       {name}",
        f"identifier:                 {identifier}",
        "type code:                  'APPL' (4150504c)",
        SEPARATOR,
    ])


DUMP = "\n".join([
    "Checking data integrity...",
    "...done.",
    SEPARATOR,
    record("/Applications/Nanogram.app", "org.klaipher.Nanogram"),
    record("/Users/me/Projects/nanogram-macos/build-output.noindex/profiling/Nanogram.app", "org.klaipher.Nanogram"),
    record("/Users/me/.cache/nanogram-macos/DerivedData/Build/Products/Debug/Nanogram.app", "org.klaipher.Nanogram"),
    record("/Volumes/Nanogram/Nanogram.app", "org.klaipher.Nanogram"),
    record("/Users/me/Projects/nanogram-macos/build-output.noindex/apps/Debug-direct/Nanogram.app/Contents/Frameworks/"
           "Sparkle.framework/Versions/B/Updater.app", "org.sparkle-project.Sparkle.Updater", "Updater"),
    record("/Users/me/Library/Daemon Containers/X/Data/Library/Caches/Placeholders-v6.noindex/org.klaipher.Nanogram-13.2/"
           "Nanogram.app", "org.klaipher.Nanogram"),
    record("/Applications/Telegram.app", "ru.keepcoder.Telegram", "Telegram"),
    record("/Users/me/.cache/ios/Build/Products/Debug-iphoneos/Share.app", "org.klaipher.Nanogram.Share", "Share"),
    record("/Users/me/Library/Developer/CoreSimulator/Devices/A/data/tgwatch Watch App.app",
           "org.klaipher.Nanogram.watchkitapp", "tgwatch Watch App"),
    record("/Users/me/Projects/wt/mac-x/build-output/apps/Debug-direct/Renamed.app", "org.klaipher.Nanogram"),
    "path:                       /Users/me/broken.app (0x1)",
    "name:                       Nanogram",
    SEPARATOR,
])

INSTALLED = Path("/Applications/Nanogram.app")


class AppRegistryTests(unittest.TestCase):
    def test_parsesPathIdentifierAndName(self):
        records = appregistry.parse_dump(DUMP)
        self.assertEqual(records[0], appregistry.Registration(INSTALLED, "org.klaipher.Nanogram", "Nanogram"))
        self.assertEqual(records[-1], appregistry.Registration(Path("/Users/me/broken.app"), "", "Nanogram"))

    def test_everyCopyButTheInstalledOneIsAStray(self):
        strays = appregistry.strays(appregistry.parse_dump(DUMP), keep=INSTALLED)
        self.assertEqual([str(path) for path in strays], [
            "/Users/me/Projects/nanogram-macos/build-output.noindex/profiling/Nanogram.app",
            "/Users/me/.cache/nanogram-macos/DerivedData/Build/Products/Debug/Nanogram.app",
            "/Volumes/Nanogram/Nanogram.app",
            "/Users/me/Projects/wt/mac-x/build-output/apps/Debug-direct/Renamed.app",
            "/Users/me/broken.app",
        ])

    def test_helpersInsideABundleOtherAppsAndTheSystemsIPhonePlaceholderAreLeftAlone(self):
        strays = {str(path) for path in appregistry.strays(appregistry.parse_dump(DUMP), keep=INSTALLED)}
        self.assertFalse(any("Updater.app" in path for path in strays))
        self.assertNotIn("/Applications/Telegram.app", strays)
        self.assertFalse(any("Placeholders" in path for path in strays))
        self.assertFalse(any("Share.app" in path or "Watch App" in path for path in strays),
                         "iOS extensions and watch apps share the identifier prefix but never show up as Nanogram")

    def test_aRenamedMacCopyIsFoundByItsIdentifier(self):
        strays = {str(path) for path in appregistry.strays(appregistry.parse_dump(DUMP), keep=INSTALLED)}
        self.assertIn("/Users/me/Projects/wt/mac-x/build-output/apps/Debug-direct/Renamed.app", strays)

    def test_withoutAnInstalledCopyTheNewestBuildStays(self):
        records = appregistry.parse_dump(DUMP)
        mtimes = {
            "/Users/me/Projects/nanogram-macos/build-output.noindex/profiling/Nanogram.app": 300.0,
            "/Users/me/.cache/nanogram-macos/DerivedData/Build/Products/Debug/Nanogram.app": 200.0,
            "/Volumes/Nanogram/Nanogram.app": 100.0,
        }
        keep = appregistry.choose_keep(records, installed=INSTALLED, exists=lambda path: str(path) in mtimes,
                                       mtime=lambda path: mtimes[str(path)])
        self.assertEqual(keep, Path("/Users/me/Projects/nanogram-macos/build-output.noindex/profiling/Nanogram.app"))

    def test_theInstalledCopyIsKeptWhenItExists(self):
        keep = appregistry.choose_keep(appregistry.parse_dump(DUMP), installed=INSTALLED, exists=lambda path: True,
                                       mtime=lambda path: 0.0)
        self.assertEqual(keep, INSTALLED)

    def test_tidyUnregistersEachStrayAndNothingInADryRun(self):
        calls = []

        def run(arguments):
            calls.append(arguments)
            return DUMP if "-dump" in arguments else ""

        removed = appregistry.tidy(run=run, exists=lambda path: True, mtime=lambda path: 0.0, dry_run=True)
        self.assertEqual(len(removed), 5)
        self.assertEqual([call for call in calls if "-u" in call], [])
        calls.clear()
        appregistry.tidy(run=run, exists=lambda path: True, mtime=lambda path: 0.0)
        unregistered = [call[-1] for call in calls if "-u" in call]
        self.assertEqual(unregistered, [str(path) for path in removed])


if __name__ == "__main__":
    unittest.main()
