"""Edition checks on the apps `tg build --edition mas|direct` leaves in build-output/apps/."""
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import editions  # noqa: E402

CONFIGURATION = os.environ.get("NANOGRAM_EDITIONS_CONFIGURATION", "Debug")
GROUP = "YGTMYL879P.org.klaipher.Nanogram"
ENTITLEMENTS = Path(__file__).resolve().parents[3] / "nanogram" / "entitlements"
MACH_LOOKUP = "com.apple.security.temporary-exception.mach-lookup.global-name"
DIRECT_ENTITLEMENTS = {"com.apple.security.app-sandbox": True,
                       "com.apple.security.application-groups": [GROUP],
                       "com.apple.security.network.client": True,
                       MACH_LOOKUP: ["org.klaipher.Nanogram-spks", "org.klaipher.Nanogram-spki"]}
DIRECT_INFO = {"SUEnableInstallerLauncherService": True, "SUEnableDownloaderService": True,
               "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True}


def built(edition):
    try:
        return editions.stashed_app(CONFIGURATION, edition)
    except FileNotFoundError:
        return None


MAS, DIRECT = built("mas"), built("direct")
BOTH_BUILT = MAS is not None and DIRECT is not None
NOT_BUILT = f"build both editions first: tg build --edition mas && tg build --edition direct ({CONFIGURATION})"


class EditionRulesTests(unittest.TestCase):
    """The rules themselves, on synthetic facts (no build needed)."""

    def facts(self, **overrides):
        base = dict(bundle_id="org.klaipher.Nanogram", source="DEBUG", sparkle_embedded=False, sparkle_symbols=[],
                    entitlements={"com.apple.security.app-sandbox": True,
                                  "com.apple.security.application-groups": [GROUP]},
                    hardened_runtime=False, extension_entitlements={"com.apple.security.app-sandbox": True,
                                                                   "com.apple.security.application-groups": [GROUP]})
        base.update(overrides)
        return editions.AppFacts(**base)

    def test_mas_rejects_sparkle(self):
        problems = editions.check_edition(self.facts(sparkle_embedded=True, sparkle_symbols=["_OBJC_CLASS_$_SUUpdater"]), "mas")
        self.assertTrue(any("Sparkle.framework" in p for p in problems))
        self.assertTrue(any("SUUpdater" in p for p in problems))

    def direct_facts(self, **overrides):
        base = dict(entitlements=dict(DIRECT_ENTITLEMENTS), sparkle_embedded=True, hardened_runtime=True,
                    sparkle_feed=editions.SPARKLE_FEED_URL, sparkle_public_key="A" * 43 + "=",
                    sparkle_xpc_services=["Downloader.xpc", "Installer.xpc"], info=dict(DIRECT_INFO))
        base.update(overrides)
        return self.facts(**base)

    def test_direct_requires_sandbox(self):
        entitlements = dict(DIRECT_ENTITLEMENTS)
        del entitlements["com.apple.security.app-sandbox"]
        problems = editions.check_edition(self.direct_facts(entitlements=entitlements), "direct")
        self.assertTrue(any("not sandboxed" in p for p in problems), problems)

    def test_sandboxed_direct_with_everything_is_clean(self):
        self.assertEqual(editions.check_edition(self.direct_facts(), "direct"), [])

    def test_direct_requires_both_sparkle_xpc_services(self):
        for missing in ("Downloader.xpc", "Installer.xpc"):
            services = [s for s in ("Downloader.xpc", "Installer.xpc") if s != missing]
            problems = editions.check_edition(self.direct_facts(sparkle_xpc_services=services), "direct")
            self.assertTrue(any(missing in p for p in problems), problems)

    def test_direct_requires_the_sparkle_service_and_security_keys(self):
        for key in ("SUEnableInstallerLauncherService", "SUEnableDownloaderService",
                    "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
            info = dict(DIRECT_INFO)
            info[key] = False
            problems = editions.check_edition(self.direct_facts(info=info), "direct")
            self.assertTrue(any(key in p for p in problems), (key, problems))

    def test_direct_rejects_a_dsa_key_entry(self):
        info = dict(DIRECT_INFO, SUPublicDSAKeyFile="")
        problems = editions.check_edition(self.direct_facts(info=info), "direct")
        self.assertTrue(any("SUPublicDSAKeyFile" in p for p in problems), problems)

    def test_direct_requires_the_sparkle_mach_lookup_exceptions(self):
        for name in ("-spks", "-spki"):
            entitlements = dict(DIRECT_ENTITLEMENTS)
            entitlements[MACH_LOOKUP] = [n for n in entitlements[MACH_LOOKUP] if not n.endswith(name)]
            problems = editions.check_edition(self.direct_facts(entitlements=entitlements), "direct")
            self.assertTrue(any(editions.BUNDLE_ID + name in p for p in problems), problems)

    def test_direct_requires_the_network_client_entitlement(self):
        entitlements = dict(DIRECT_ENTITLEMENTS)
        del entitlements["com.apple.security.network.client"]
        problems = editions.check_edition(self.direct_facts(entitlements=entitlements), "direct")
        self.assertTrue(any("network.client" in p for p in problems), problems)

    def test_direct_needs_our_feed_and_ed_key(self):
        problems = editions.check_edition(self.direct_facts(sparkle_feed="", sparkle_public_key=""), "direct")
        self.assertTrue(any("SUFeedURL" in p for p in problems), problems)
        self.assertTrue(any("SUPublicEDKey" in p for p in problems), problems)

    def test_mas_has_no_feed(self):
        problems = editions.check_edition(self.facts(sparkle_feed="https://example.org/appcast.xml"), "mas")
        self.assertTrue(any("SUFeedURL" in p for p in problems), problems)

    def test_missing_group_rejected(self):
        facts = self.facts(entitlements={"com.apple.security.app-sandbox": True})
        self.assertTrue(any(GROUP in p for p in editions.check_edition(facts, "mas")))


    def test_mas_development_entitlements_differ_only_by_profile_keys(self):
        full = plistlib.loads((ENTITLEMENTS / "Nanogram-MAS.entitlements").read_bytes())
        development = plistlib.loads((ENTITLEMENTS / "Nanogram-MAS-Development.entitlements").read_bytes())
        for key in editions.PROFILE_ONLY_KEYS:
            self.assertIn(key, full)
            full.pop(key)
        self.assertEqual(development, full)
        self.assertNotIn("com.apple.developer.associated-domains", full)

class DirectEntitlementsTests(unittest.TestCase):
    """Nanogram-Direct.entitlements is the sandboxed mas set plus Sparkle's mach-lookup exceptions, nothing else."""

    def load(self, name):
        return plistlib.loads((ENTITLEMENTS / name).read_bytes())

    def test_direct_is_sandboxed(self):
        self.assertIs(self.load("Nanogram-Direct.entitlements").get("com.apple.security.app-sandbox"), True)

    def test_direct_equals_the_mas_set_plus_the_sparkle_exceptions(self):
        direct = self.load("Nanogram-Direct.entitlements")
        exceptions = direct.pop(MACH_LOOKUP)
        self.assertEqual(sorted(exceptions), ["$(PRODUCT_BUNDLE_IDENTIFIER)-spki", "$(PRODUCT_BUNDLE_IDENTIFIER)-spks"])
        self.assertEqual(direct, self.load("Nanogram-MAS-Development.entitlements"))

    def test_mas_sets_have_no_sparkle_exceptions(self):
        for name in ("Nanogram-MAS.entitlements", "Nanogram-MAS-Development.entitlements"):
            self.assertNotIn(MACH_LOOKUP, self.load(name))

    def test_calls_and_files_capabilities_are_kept(self):
        direct = self.load("Nanogram-Direct.entitlements")
        for key in ("com.apple.security.network.client", "com.apple.security.network.server",
                    "com.apple.security.device.camera", "com.apple.security.device.audio-input",
                    "com.apple.security.personal-information.location", "com.apple.security.files.downloads.read-write",
                    "com.apple.security.files.user-selected.read-write"):
            self.assertIs(direct.get(key), True, key)
        self.assertEqual(direct["com.apple.security.application-groups"], [GROUP])


class DirectBuildSettingsTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[3]

    def setting(self, name):
        text = (self.ROOT / "nanogram" / "editions" / "direct.xcconfig").read_text()
        match = re.search(rf"^{name} = (.*)$", text, re.M)
        return match.group(1).strip() if match else None

    def test_both_sparkle_xpc_services_are_embedded(self):
        self.assertEqual(self.setting("SPARKLE_EMBED_INSTALLER_LAUNCHER_XPC_SERVICE"), "1")
        self.assertEqual(self.setting("SPARKLE_EMBED_DOWNLOADER_XPC_SERVICE"), "1")

    def test_the_connection_and_status_services_stay_off(self):
        self.assertIsNone(self.setting("SPARKLE_EMBED_INSTALLER_CONNECTION_XPC_SERVICE"))
        self.assertIsNone(self.setting("SPARKLE_EMBED_INSTALLER_STATUS_XPC_SERVICE"))

    def test_legacy_updater_and_dsa_stay_out(self):
        self.assertEqual(self.setting("SPARKLE_BUILD_LEGACY_SUUPDATER"), "0")
        self.assertEqual(self.setting("SPARKLE_BUILD_LEGACY_DSA_SUPPORT"), "0")
        self.assertIsNone(self.setting("DSA_PEM_FILE"))

    def test_info_plist_carries_the_sparkle_security_keys(self):
        info = plistlib.loads((self.ROOT / "Telegram-Mac" / "Info.plist").read_bytes())
        for key in DIRECT_INFO:
            self.assertIs(info.get(key), True, key)
        self.assertNotIn("SUPublicDSAKeyFile", info)
        self.assertEqual(info["SUPublicEDKey"], "$(SPARKLE_ED_PUBLIC_KEY)")


class ContainerMigrationTests(unittest.TestCase):
    """The unsandboxed direct builds kept preferences and caches under ~/Library; the sandboxed app finds them in its
    new container because macOS moves the listed paths when that container is first created."""
    ROOT = Path(__file__).resolve().parents[3]
    PLIST = ROOT / "Telegram-Mac" / "container-migration.plist"

    def moves(self):
        return plistlib.loads(self.PLIST.read_bytes())["Move"]

    def test_preferences_and_support_folders_of_the_bundle_move_into_the_container(self):
        moves = self.moves()
        for path in ("Library/Preferences/org.klaipher.Nanogram.plist",
                     "Library/Application Support/org.klaipher.Nanogram",
                     "Library/Caches/org.klaipher.Nanogram",
                     "Library/Saved Application State/org.klaipher.Nanogram.savedState"):
            self.assertIn(path, moves)

    def test_only_paths_of_this_bundle_move_and_the_app_group_stays_put(self):
        for path in self.moves():
            self.assertTrue(path.startswith("Library/"), path)
            self.assertIn("org.klaipher.Nanogram", path)
            self.assertNotIn("Group Containers", path)
            self.assertNotIn("..", path)

    def test_plist_is_a_resource_of_the_app_target(self):
        project = (self.ROOT / "Telegram.xcodeproj" / "project.pbxproj").read_text()
        build_file = re.search(r"^\t\t(\w{24}) /\* container-migration.plist in Resources \*/ = \{isa = PBXBuildFile;", project, re.M)
        self.assertIsNotNone(build_file, "container-migration.plist is not in a Resources build phase")
        phase = re.search(r"D098C7131D7E175A007784E4 /\* Resources \*/ = \{.*?files = \((.*?)\);", project, re.S)
        self.assertIn(build_file.group(1), phase.group(1), "container-migration.plist is not in the app's Resources phase")
        self.assertEqual(project.count("container-migration.plist in Resources */,"), 1)


class BuildDescriptionTests(unittest.TestCase):
    """Xcode reused a cached build description after an edition xcconfig changed (seen in Task 9: mas build,
    edit direct.xcconfig, direct build → Info.plist without the new setting). tg build drops the cache then."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.editions_dir = root / "nanogram" / "editions"
        self.editions_dir.mkdir(parents=True)
        (root / "nanogram" / "Nanogram.xcconfig").write_text("ARCHS = arm64\n")
        self.xcconfig = self.editions_dir / "direct.xcconfig"
        self.xcconfig.write_text('#include "../Nanogram.xcconfig"\nSFEED_URL = a\n')
        self.derived = root / "DerivedData"
        self.descriptions = self.derived / "Build" / "Intermediates.noindex" / "XCBuildData"
        self.descriptions.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def cached(self):
        (self.descriptions / "734b.xcbuilddata").mkdir(exist_ok=True)
        (self.descriptions / "build.db").write_text("db")

    def refresh(self):
        return editions.refresh_build_descriptions(self.xcconfig, "direct", self.derived)

    def test_unchanged_settings_keep_the_cache(self):
        self.refresh()
        self.cached()
        self.assertFalse(self.refresh())
        self.assertTrue((self.descriptions / "734b.xcbuilddata").exists())

    def test_changed_edition_xcconfig_drops_descriptions_only(self):
        self.refresh()
        self.cached()
        self.xcconfig.write_text(self.xcconfig.read_text() + "SPARKLE_ED_PUBLIC_KEY = k\n")
        self.assertTrue(self.refresh())
        self.assertFalse((self.descriptions / "734b.xcbuilddata").exists())
        self.assertEqual((self.descriptions / "build.db").read_text(), "db")

    def test_changed_included_xcconfig_drops_descriptions(self):
        self.refresh()
        self.cached()
        (self.editions_dir.parent / "Nanogram.xcconfig").write_text("ARCHS = arm64\nPRODUCT_NAME = x\n")
        self.assertTrue(self.refresh())

    def test_each_edition_tracked_separately(self):
        self.refresh()
        self.cached()
        self.assertTrue(editions.refresh_build_descriptions(self.xcconfig, "mas", self.derived))
        self.cached()
        self.assertFalse(self.refresh())


class ProductFingerprintTests(unittest.TestCase):
    """The editions check (codesign, nm, a full-bundle endpoint scan: 4–9 s) is skipped when the built app's code
    signature covers the same contents as the app it last passed. Xcode re-signs the app on every build (Sparkle's
    always-run script phases re-embed it), so the fingerprint is the CodeDirectory hash, not file times."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.template = Path(cls.tmp.name) / "template" / "Nanogram.app"
        cls.make_app(cls.template)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @staticmethod
    def compile(target, source):
        target.parent.mkdir(parents=True, exist_ok=True)
        c_file = target.parent / f"{target.name}.c"
        c_file.write_text(source)
        subprocess.run(["xcrun", "clang", "-arch", "arm64", str(c_file), "-o", str(target)], check=True)
        c_file.unlink()

    @staticmethod
    def write_plist(path, identifier, executable):
        with path.open("wb") as handle:
            plistlib.dump({"CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                           "CFBundlePackageType": "APPL"}, handle)

    @classmethod
    def sign(cls, bundle, entitlements=None):
        args = ["codesign", "--force", "-s", "-"]
        if entitlements:
            args += ["--entitlements", str(entitlements)]
        subprocess.run(args + [str(bundle)], check=True, capture_output=True)

    @classmethod
    def make_app(cls, app):
        appex = app / "Contents" / "PlugIns" / "Share.appex"
        cls.compile(appex / "Contents" / "MacOS" / "Share", "int main(void) { return 0; }\n")
        cls.write_plist(appex / "Contents" / "Info.plist", "org.example.App.Share", "Share")
        cls.compile(app / "Contents" / "MacOS" / "Nanogram", "int main(void) { return 0; }\n")
        cls.write_plist(app / "Contents" / "Info.plist", "org.example.App", "Nanogram")
        cls.sign(appex)
        cls.sign(app)

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(dir=self.tmp.name))
        self.products = self.dir / "Products"
        self.products.mkdir()
        self.app = self.products / "Nanogram.app"
        subprocess.run(["cp", "-R", str(self.template), str(self.app)], check=True)
        self.apps_dir = self.dir / "apps"
        self.patches = [mock.patch.object(editions, "APPS_DIR", self.apps_dir),
                        mock.patch.object(editions.branding, "check_names", return_value=[]),
                        mock.patch.object(editions.branding, "find_forbidden", return_value=[])]
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in self.patches:
            patch.stop()

    def check(self, edition="direct", problems=()):
        with mock.patch.object(editions, "inspect_app", return_value=None) as inspect, \
                mock.patch.object(editions, "check_edition", return_value=list(problems)):
            status = editions.main(["--edition", edition, "--configuration", "Debug", "--products", str(self.products)])
        return status, inspect.called

    def test_unchanged_product_skips_check(self):
        self.assertEqual(self.check(), (0, True))
        with mock.patch.object(editions, "inspect_app", side_effect=AssertionError("inspected")), \
                mock.patch.object(editions, "stash_app", side_effect=AssertionError("stashed")):
            self.assertEqual(editions.main(["--edition", "direct", "--configuration", "Debug",
                                            "--products", str(self.products)]), 0)

    def test_resigned_unchanged_product_skips_check(self):
        self.check()
        self.sign(self.app)
        self.assertEqual(self.check(), (0, False))

    def test_relinked_binary_rechecks(self):
        self.check()
        self.compile(self.app / "Contents" / "MacOS" / "Nanogram", "int main(void) { return 1; }\n")
        self.sign(self.app)
        self.assertEqual(self.check(), (0, True))

    def test_changed_extension_rechecks(self):
        self.check()
        appex = self.app / "Contents" / "PlugIns" / "Share.appex"
        self.compile(appex / "Contents" / "MacOS" / "Share", "int main(void) { return 2; }\n")
        self.sign(appex)
        self.sign(self.app)
        self.assertEqual(self.check(), (0, True))

    def test_changed_entitlements_recheck(self):
        self.check()
        entitlements = self.dir / "e.plist"
        with entitlements.open("wb") as handle:
            plistlib.dump({"com.apple.security.app-sandbox": True}, handle)
        self.sign(self.app, entitlements)
        self.assertEqual(self.check(), (0, True))

    def test_failed_check_does_not_write_fingerprint(self):
        self.assertEqual(self.check(problems=["direct app is sandboxed"]), (1, True))
        self.assertFalse(editions.fingerprint_file("Debug", "direct").exists())
        self.assertEqual(self.check(problems=["direct app is sandboxed"]), (1, True))

    def test_edition_switch_rechecks(self):
        self.check("mas")
        self.assertEqual(self.check("direct"), (0, True))

    def test_missing_stash_rechecks(self):
        self.check()
        shutil.rmtree(self.apps_dir / "Debug-direct")
        self.assertEqual(self.check(), (0, True))

    def test_unsigned_app_always_checked(self):
        subprocess.run(["codesign", "--remove-signature", str(self.app)], check=True)
        self.assertEqual(editions.product_fingerprint(self.app), "")
        self.check()
        self.assertEqual(self.check(), (0, True))


@unittest.skipUnless(BOTH_BUILT, NOT_BUILT)
class BuiltEditionsTests(unittest.TestCase):
    def test_mas_has_sandbox_no_sparkle(self):
        facts = editions.inspect_app(MAS)
        self.assertIs(facts.entitlements.get("com.apple.security.app-sandbox"), True)
        self.assertFalse(facts.sparkle_embedded, "mas embeds Sparkle.framework")
        self.assertEqual(facts.sparkle_symbols, [])
        self.assertNotIn("com.apple.developer.associated-domains", facts.entitlements)
        self.assertEqual(editions.check_edition(facts, "mas"), [])

    def test_direct_is_sandboxed_with_sparkle_and_its_xpc_services(self):
        facts = editions.inspect_app(DIRECT)
        self.assertIs(facts.entitlements.get("com.apple.security.app-sandbox"), True)
        self.assertEqual(sorted(facts.sparkle_xpc_services), ["Downloader.xpc", "Installer.xpc"])
        self.assertTrue(facts.sparkle_embedded, "direct does not embed Sparkle.framework")
        self.assertTrue(facts.hardened_runtime, "direct is not signed with the hardened runtime")
        self.assertEqual(editions.check_edition(facts, "direct"), [])

    def test_both_ship_the_container_migration(self):
        for app in (MAS, DIRECT):
            plist = app / "Contents" / "Resources" / "container-migration.plist"
            self.assertTrue(plist.is_file(), app)
            self.assertIn("Library/Preferences/org.klaipher.Nanogram.plist", plistlib.loads(plist.read_bytes())["Move"])

    def test_both_share_app_group(self):
        for app in (MAS, DIRECT):
            facts = editions.inspect_app(app)
            self.assertIn(GROUP, facts.entitlements.get("com.apple.security.application-groups", []), app)
            self.assertIn(GROUP, facts.extension_entitlements.get("com.apple.security.application-groups", []), app)

    def test_both_use_same_bundle_and_data_prefix(self):
        mas, direct = editions.inspect_app(MAS), editions.inspect_app(DIRECT)
        self.assertEqual(mas.bundle_id, "org.klaipher.Nanogram")
        self.assertEqual(direct.bundle_id, mas.bundle_id)
        self.assertEqual(direct.source, mas.source)


def running_pids(app):
    executable = str(editions.main_executable(app))
    out = subprocess.run(["pgrep", "-f", "-x", executable], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def frontmost_pid():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True).stdout
    match = re.search(r"\bpid = (\d+)", out)
    return int(match.group(1)) if match else None


def frontmost_is_loginwindow():
    pid = frontmost_pid()
    if pid is None:
        return True
    command = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout
    return command.strip().endswith("/loginwindow")


@unittest.skipUnless(BOTH_BUILT and os.environ.get("NANOGRAM_LAUNCH_TESTS") == "1",
                     NOT_BUILT + "; launches GUI apps, set NANOGRAM_LAUNCH_TESTS=1")
class SingleInstanceTests(unittest.TestCase):
    def tearDown(self):
        for app in (MAS, DIRECT):
            for pid in running_pids(app):
                subprocess.run(["kill", str(pid)])

    def wait_for(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.25)
        return predicate()

    def test_single_instance_across_editions(self):
        self.assertEqual(running_pids(MAS) + running_pids(DIRECT), [], "quit Nanogram before running this test")
        subprocess.run(["open", "-n", "-g", str(DIRECT)], check=True)
        self.assertTrue(self.wait_for(lambda: len(running_pids(DIRECT)) == 1, 20), "direct did not start")
        first = running_pids(DIRECT)
        time.sleep(3)
        started = time.monotonic()
        try:
            subprocess.run(["open", "-n", "-g", "-W", str(MAS)], check=True, timeout=5)
        except subprocess.TimeoutExpired:
            self.fail("the mas edition kept running next to direct for 5 s")
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(running_pids(MAS), [])
        self.assertEqual(running_pids(DIRECT), first, "the first instance did not survive")

    def test_second_launch_activates_first(self):
        if frontmost_is_loginwindow():
            self.skipTest("the screen is locked (loginwindow is frontmost): no app can be activated")
        subprocess.run(["open", "-n", "-g", str(DIRECT)], check=True)
        self.assertTrue(self.wait_for(lambda: len(running_pids(DIRECT)) == 1, 20), "direct did not start")
        first = running_pids(DIRECT)
        time.sleep(3)
        subprocess.run(["open", "-n", "-W", str(MAS)], check=True, timeout=5)
        self.assertTrue(self.wait_for(lambda: frontmost_pid() == first[0], 3), "the first instance was not activated")


if __name__ == "__main__":
    unittest.main()
