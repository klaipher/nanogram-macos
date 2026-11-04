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

    def test_decoder_service_must_be_sandboxed_hardened_and_have_no_network_or_file_access(self):
        good = dict(decoder_present=True, decoder_entitlements={"com.apple.security.app-sandbox": True},
                    decoder_hardened_runtime=True)
        self.assertEqual(editions.check_edition(self.facts(**good), "mas"), [])
        bad = dict(good, decoder_entitlements={"com.apple.security.app-sandbox": True,
                                               "com.apple.security.network.client": True,
                                               "com.apple.security.files.user-selected.read-write": True,
                                               "com.apple.security.temporary-exception.mach-lookup.global-name": ["x"]},
                   decoder_hardened_runtime=False)
        problems = editions.check_edition(self.facts(**bad), "mas")
        self.assertTrue(any("network.client" in p for p in problems), problems)
        self.assertTrue(any("files.user-selected" in p for p in problems), problems)
        self.assertTrue(any("temporary-exception" in p for p in problems), problems)
        self.assertTrue(any("hardened runtime" in p and "decoder" in p.lower() for p in problems), problems)
        unsandboxed = dict(good, decoder_entitlements={})
        self.assertTrue(any("decoder" in p.lower() and "sandbox" in p for p in editions.check_edition(self.facts(**unsandboxed), "direct")))

    def test_mas_rejects_sparkle(self):
        problems = editions.check_edition(self.facts(sparkle_embedded=True, sparkle_symbols=["_OBJC_CLASS_$_SUUpdater"]), "mas")
        self.assertTrue(any("Sparkle.framework" in p for p in problems))
        self.assertTrue(any("SUUpdater" in p for p in problems))

    def test_direct_rejects_sandbox(self):
        problems = editions.check_edition(self.facts(sparkle_embedded=True, hardened_runtime=True), "direct")
        self.assertTrue(any("sandbox" in p for p in problems))

    def test_direct_needs_our_feed_and_ed_key(self):
        base = dict(entitlements={"com.apple.security.application-groups": [GROUP]}, sparkle_embedded=True,
                    hardened_runtime=True)
        problems = editions.check_edition(self.facts(**base), "direct")
        self.assertTrue(any("SUFeedURL" in p for p in problems), problems)
        self.assertTrue(any("SUPublicEDKey" in p for p in problems), problems)
        good = self.facts(**base, sparkle_feed=editions.SPARKLE_FEED_URL, sparkle_public_key="A" * 43 + "=")
        self.assertEqual(editions.check_edition(good, "direct"), [])

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

    def test_direct_has_sparkle_no_sandbox(self):
        facts = editions.inspect_app(DIRECT)
        self.assertNotIn(facts.entitlements.get("com.apple.security.app-sandbox"), (True,))
        self.assertTrue(facts.sparkle_embedded, "direct does not embed Sparkle.framework")
        self.assertTrue(facts.hardened_runtime, "direct is not signed with the hardened runtime")
        self.assertEqual(editions.check_edition(facts, "direct"), [])

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
