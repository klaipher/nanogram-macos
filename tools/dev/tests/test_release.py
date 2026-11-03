"""tg testflight (mas) and tg release-direct: archive, export, upload, notarize. Nothing here talks to Apple."""
import datetime
import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, release  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]


def fake_asc(directory: Path, key_id="ABC123DEF4", issuer="00000000-0000-0000-0000-000000000000") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "asc.json").write_text(json.dumps({"key_id": key_id, "issuer_id": issuer}))
    (directory / f"AuthKey_{key_id}.p8").write_text("not a real key\n")
    return directory


class ExportOptionsTests(unittest.TestCase):
    def test_export_options_mas(self):
        options = release.export_options("app-store-connect", upload=False)
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["signingStyle"], "automatic")
        self.assertEqual(options["teamID"], "YGTMYL879P")
        self.assertIs(options["uploadSymbols"], True)
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)
        self.assertEqual(release.export_options("app-store-connect", upload=True)["destination"], "upload")
        plistlib.dumps(options)

    def test_export_options_direct(self):
        options = release.export_options("developer-id", upload=False)
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["signingStyle"], "automatic")
        self.assertEqual(options["teamID"], "YGTMYL879P")
        self.assertNotIn("uploadSymbols", options)
        with self.assertRaises(ValueError):
            release.export_options("developer-id", upload=True)
        with self.assertRaises(ValueError):
            release.export_options("ad-hoc", upload=False)

    def test_edition_methods(self):
        self.assertEqual(release.METHODS, {"mas": "app-store-connect", "direct": "developer-id"})


class AscKeyTests(unittest.TestCase):
    def test_missing_asc_key_fails_early(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "asc"
            with self.assertRaises(config.ConfigError) as caught:
                release.asc_key(empty)
            self.assertIn(str(empty), str(caught.exception))
            self.assertIn("asc.json", str(caught.exception))
            with mock.patch.object(release, "asc_dir", return_value=empty), \
                    mock.patch.object(release.subprocess, "run") as run, \
                    mock.patch.object(release, "archive") as archive:
                with self.assertRaises(config.ConfigError):
                    release.testflight(export_only=True)
                with self.assertRaises(config.ConfigError):
                    release.release_direct()
                run.assert_not_called()
                archive.assert_not_called()

    def test_key_file_missing_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            asc = fake_asc(Path(tmp) / "asc")
            (asc / "AuthKey_ABC123DEF4.p8").unlink()
            with self.assertRaises(config.ConfigError) as caught:
                release.asc_key(asc)
            self.assertIn("AuthKey_ABC123DEF4.p8", str(caught.exception))

    def test_key_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            asc = fake_asc(Path(tmp) / "asc")
            key = release.asc_key(asc)
            self.assertEqual(key.key_id, "ABC123DEF4")
            self.assertEqual(key.path, asc / "AuthKey_ABC123DEF4.p8")
            self.assertEqual(key.auth_flags(), [
                "-authenticationKeyPath", str(asc / "AuthKey_ABC123DEF4.p8"),
                "-authenticationKeyID", "ABC123DEF4",
                "-authenticationKeyIssuerID", "00000000-0000-0000-0000-000000000000"])


class VersionTests(unittest.TestCase):
    def test_build_number_override(self):
        self.assertEqual(release.build_number({"TG_BUILD_NUMBER": "4242"}), "4242")
        now = datetime.datetime(2026, 11, 3, 9, 5)
        self.assertEqual(release.build_number({}, now=now), "202611030905")
        for bad in ("12a", "", "1.2.3.4", "-1"):
            with self.assertRaises(config.ConfigError):
                release.build_number({"TG_BUILD_NUMBER": bad})

    def test_marketing_version_is_upstreams(self):
        version = release.marketing_version()
        self.assertRegex(version, r"^\d+\.\d+(\.\d+)?$")
        self.assertIn(f"MARKETING_VERSION = {version};",
                      (ROOT / "Telegram.xcodeproj" / "project.pbxproj").read_text())


class SettingsTests(unittest.TestCase):
    def test_release_settings_turn_exclusivity_checks_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings = release.release_settings(order_file=Path(tmp) / "missing.order")
        self.assertIn("SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off", settings)
        self.assertFalse(any(s.startswith("NANOGRAM_ORDER_FILE=") for s in settings))

    def test_release_settings_pass_an_existing_order_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            order = Path(tmp) / "Telegram.order"
            order.write_text("_main\n")
            self.assertIn(f"NANOGRAM_ORDER_FILE={order}", release.release_settings(order_file=order))

    def test_order_file_is_the_generators_output_and_release_only(self):
        self.assertEqual(release.ORDER_FILE, ROOT / "Telegram-Mac" / "OrderFiles" / "Telegram.order")
        xcconfig = (ROOT / "nanogram" / "Nanogram.xcconfig").read_text()
        self.assertIn("NANOGRAM_ORDER_FILE_Telegram = $(NANOGRAM_ORDER_FILE)", xcconfig)
        self.assertIn("ORDER_FILE[config=Release] = $(NANOGRAM_ORDER_FILE_$(TARGET_NAME):default=$(inherited))",
                      xcconfig)
        self.assertNotIn("SWIFT_ENFORCE_EXCLUSIVE_ACCESS", xcconfig)

    def test_cold_screens_build_for_size_and_hot_modules_stay_fast(self):
        xcconfig = (ROOT / "nanogram" / "Nanogram.xcconfig").read_text()
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL[config=Release] = $(NANOGRAM_SWIFT_OPT_$(TARGET_NAME):default=-O)",
                      xcconfig)
        for module in ["WalletContext", "WalletUI", "StarsUI", "SettingsUI", "PassportUI", "ChatExportUI"]:
            self.assertIn(f"NANOGRAM_SWIFT_OPT_{module} = -Osize", xcconfig)
        for module in ["TelegramCore", "Postbox", "TGUIKit", "ChatUI", "ChatListUI", "TelegramMedia", "SwiftSignalKit"]:
            self.assertNotIn(f"NANOGRAM_SWIFT_OPT_{module} ", xcconfig)

    def test_conditions(self):
        self.assertEqual(release.conditions("direct"), "$(inherited) NANOGRAM STABLE")
        self.assertEqual(release.conditions("mas"), "$(inherited) NANOGRAM STABLE NANOGRAM_MAS")


class ArchiveCommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key = release.asc_key(fake_asc(Path(self.tmp.name) / "asc"))

    def tearDown(self):
        self.tmp.cleanup()

    def command(self, edition):
        return release.archive_command(edition, "4242", Path("/out/Nanogram.xcarchive"), self.key,
                                       derived=Path("/dd"))

    def test_archive_command_mas(self):
        cmd = self.command("mas")
        self.assertEqual(cmd[:2], ["xcodebuild", "archive"])
        for pair in (["-scheme", "Release"], ["-configuration", "Release"],
                     ["-archivePath", "/out/Nanogram.xcarchive"], ["-derivedDataPath", "/dd"],
                     ["-xcconfig", str(ROOT / "nanogram" / "editions" / "mas.xcconfig")],
                     ["-authenticationKeyID", "ABC123DEF4"]):
            self.assertIn(pair, [cmd[i:i + 2] for i in range(len(cmd) - 1)], pair)
        for setting in ("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) NANOGRAM STABLE NANOGRAM_MAS",
                        "CURRENT_PROJECT_VERSION=4242", "SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off",
                        "-allowProvisioningUpdates"):
            self.assertIn(setting, cmd)
        # A setting the -xcconfig file defines cannot be overridden on the command line (the file wins, seen in
        # the first archive): the distribution entitlements come from re-signing the archived app instead.
        overridden = [a for a in cmd if a.split("=")[0] in ("CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY",
                                                             "NANOGRAM_MAS_ENTITLEMENTS", "CODE_SIGN_ENTITLEMENTS")]
        self.assertEqual(overridden, [])

    def test_distribution_entitlements(self):
        self.assertEqual(release.DISTRIBUTION_ENTITLEMENTS,
                         {"mas": ROOT / "nanogram" / "entitlements" / "Nanogram-MAS.entitlements"})

    def test_archive_command_direct(self):
        cmd = self.command("direct")
        self.assertIn(str(ROOT / "nanogram" / "editions" / "direct.xcconfig"), cmd)
        self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) NANOGRAM STABLE", cmd)
        self.assertFalse(any("NANOGRAM_MAS" in a for a in cmd), cmd)


class BuildNumberStampTests(unittest.TestCase):
    def test_set_build_number_rewrites_app_extension_and_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "Nanogram.xcarchive"
            app = archive / "Products" / "Applications" / "Nanogram.app"
            appex = app / "Contents" / "PlugIns" / "Share.appex"
            for bundle, fmt in ((app, plistlib.FMT_BINARY), (appex, plistlib.FMT_XML)):
                (bundle / "Contents").mkdir(parents=True)
                (bundle / "Contents" / "Info.plist").write_bytes(
                    plistlib.dumps({"CFBundleVersion": "283357", "CFBundleShortVersionString": "13.1.0"}, fmt=fmt))
            (archive / "Info.plist").write_bytes(plistlib.dumps(
                {"ApplicationProperties": {"CFBundleVersion": "283357", "ApplicationPath": "Applications/Nanogram.app"}}))
            entitlements = Path(tmp) / "MAS.entitlements"
            with mock.patch.object(release, "_resign") as resign:
                release.set_build_number(archive, "4242", entitlements)
            for bundle in (app, appex):
                data = (bundle / "Contents" / "Info.plist").read_bytes()
                self.assertEqual(plistlib.loads(data)["CFBundleVersion"], "4242")
            self.assertTrue((app / "Contents" / "Info.plist").read_bytes().startswith(b"bplist"))
            self.assertEqual(plistlib.loads((archive / "Info.plist").read_bytes())
                             ["ApplicationProperties"]["CFBundleVersion"], "4242")
            self.assertEqual([c.args for c in resign.call_args_list], [(appex, None), (app, entitlements)])


def fake_app(root: Path) -> Path:
    app = root / "Nanogram.app"
    for path in ("Contents/MacOS/Nanogram", "Contents/PlugIns/Share.appex/Contents/MacOS/Share"):
        (app / path).parent.mkdir(parents=True, exist_ok=True)
        (app / path).write_bytes(bytes.fromhex("cffaedfe") + b"\0" * 60)
    bundle = app / "Contents" / "Resources" / "MetalEngine_MetalEngine.bundle" / "Contents"
    (bundle / "Resources").mkdir(parents=True)
    (bundle / "Resources" / "default.metallib").write_bytes(b"MTLB" + b"\0" * 60)
    (bundle / "_CodeSignature").mkdir()
    (bundle / "_CodeSignature" / "CodeResources").write_text("seal")
    return app


DISTRIBUTION = "Apple Distribution: Owner (YGTMYL879P)"
DEVELOPMENT = "Apple Development: owner@example.com (DC8G7G3PSH)"


class ResourceBundleSigningTests(unittest.TestCase):
    def test_archive_drops_the_signature_of_code_free_resource_bundles(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            bundle = app / "Contents" / "Resources" / "MetalEngine_MetalEngine.bundle"
            self.assertEqual(release.unsign_resource_bundles(app), [bundle])
            self.assertFalse((bundle / "Contents" / "_CodeSignature").exists())
            self.assertTrue((bundle / "Contents" / "Resources" / "default.metallib").is_file())

    def test_resource_bundle_with_code_keeps_its_signature(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            bundle = app / "Contents" / "Resources" / "MetalEngine_MetalEngine.bundle"
            (bundle / "Contents" / "MacOS").mkdir()
            (bundle / "Contents" / "MacOS" / "stub").write_bytes(bytes.fromhex("cffaedfe") + b"\0" * 60)
            self.assertEqual(release.unsign_resource_bundles(app), [])
            self.assertTrue((bundle / "Contents" / "_CodeSignature").is_dir())

    def test_development_signed_resource_bundle_fails_the_export_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            authorities = {app: DISTRIBUTION, app / "Contents" / "PlugIns" / "Share.appex": DISTRIBUTION}
            with mock.patch.object(release, "_authority", side_effect=lambda path: authorities.get(path, DEVELOPMENT)):
                problems = release.check_distribution_signing(app, "mas")
            self.assertEqual(len(problems), 1)
            self.assertIn("MetalEngine_MetalEngine.bundle is signed by Apple Development", problems[0])

    def test_unsigned_mach_o_in_a_resource_bundle_fails_the_export_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            release.unsign_resource_bundles(app)
            stub = app / "Contents" / "Resources" / "MetalEngine_MetalEngine.bundle" / "Contents" / "MacOS" / "x"
            stub.parent.mkdir()
            stub.write_bytes(bytes.fromhex("cafebabe") + b"\0" * 60)
            authorities = {app: DISTRIBUTION, app / "Contents" / "PlugIns" / "Share.appex": DISTRIBUTION}
            with mock.patch.object(release, "_authority", side_effect=lambda path: authorities.get(path)):
                problems = release.check_distribution_signing(app, "mas")
            self.assertEqual(len(problems), 1)
            self.assertIn("MacOS/x is signed by no identity", problems[0])

    def test_distribution_signed_app_passes_for_its_edition_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            with mock.patch.object(release, "_authority", return_value=DISTRIBUTION):
                self.assertEqual(release.check_distribution_signing(app, "mas"), [])
                self.assertEqual(len(release.check_distribution_signing(app, "direct")), 3)
            with mock.patch.object(release, "_authority", return_value="Apple Distribution: Other (AAAAAAAAAA)"):
                self.assertEqual(len(release.check_distribution_signing(app, "mas")), 3)

    def test_embedded_apple_font_fails_the_export_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            release.unsign_resource_bundles(app)
            font = app / "Contents" / "PlugIns" / "Share.appex" / "Contents" / "Resources" / "fonts"
            font.mkdir(parents=True)
            (font / "SFCompactRounded-Semibold.otf").write_bytes(b"OTTO")
            with mock.patch.object(release, "_authority", return_value=DISTRIBUTION):
                with self.assertRaises(release.ReleaseError), mock.patch("sys.stderr"):
                    release.check_exported_app(app, "mas")
                (font / "SFCompactRounded-Semibold.otf").unlink()
                with mock.patch("sys.stdout"):
                    release.check_exported_app(app, "mas")

    def test_project_embeds_no_apple_font(self):
        for path in ("Telegram.xcodeproj/project.pbxproj", "Telegram-Mac/Info.plist", "TelegramShare/Info.plist"):
            text = (ROOT / path).read_text()
            self.assertNotIn("SFCompact", text, path)
            self.assertNotIn("ATSApplicationFontsPath", text, path)


class MacPlatformTests(unittest.TestCase):
    def test_missing_mac_platform_stops_with_one_line(self):
        versions = {"data": [{"attributes": {"platform": "IOS", "versionString": "1.0"}}]}
        with mock.patch.object(release, "asc_get", return_value=versions):
            with self.assertRaises(config.ConfigError) as caught:
                release.ensure_mac_platform(object())
        message = str(caught.exception)
        self.assertIn("macOS", message)
        self.assertIn("App Store Connect", message)
        self.assertIn("6829268176", message)
        self.assertEqual(len(message.splitlines()), 1)

    def test_mac_platform_present(self):
        versions = {"data": [{"attributes": {"platform": "IOS"}}, {"attributes": {"platform": "MAC_OS"}}]}
        with mock.patch.object(release, "asc_get", return_value=versions):
            release.ensure_mac_platform(object())


class UploadTests(unittest.TestCase):
    def test_upload_uses_altool_with_the_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            asc = fake_asc(Path(tmp) / "asc")
            key = release.asc_key(asc)
            with mock.patch.object(release.subprocess, "run") as run:
                run.return_value.returncode = 0
                release.upload_mas(Path("/out/Nanogram.pkg"), key)
            args, kwargs = run.call_args
            self.assertEqual(args[0], ["xcrun", "altool", "--upload-app", "-t", "macos", "-f", "/out/Nanogram.pkg",
                                       "--apiKey", "ABC123DEF4", "--apiIssuer",
                                       "00000000-0000-0000-0000-000000000000"])
            self.assertEqual(kwargs["env"]["API_PRIVATE_KEYS_DIR"], str(asc))


def git(cwd, *args):
    import subprocess
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL="/dev/null")
    return subprocess.run(["git", "-c", "protocol.file.allow=always", *args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True).stdout


def make_repo(path: Path, files: dict) -> Path:
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "main")
    for name, text in files.items():
        (path / name).parent.mkdir(parents=True, exist_ok=True)
        (path / name).write_text(text)
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "init")
    return path


class DirectReleaseTests(unittest.TestCase):
    def test_appcast_entry_fields(self):
        import xml.etree.ElementTree as ET
        with tempfile.TemporaryDirectory() as tmp:
            dmg = Path(tmp) / "Nanogram-13.1.0-4242.dmg"
            dmg.write_bytes(b"x" * 1234)
            url = release.download_url("13.1.0", "4242")
            self.assertEqual(url, "https://github.com/klaipher/nanogram-releases/releases/download/"
                                  "v13.1.0-4242/Nanogram-13.1.0-4242.dmg")
            entry = release.appcast_entry("13.1.0", "4242", dmg, "c2lnbmF0dXJl", url)
            feed = release.appcast([entry])
        ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        root = ET.fromstring(feed)
        item = root.find("channel/item")
        self.assertEqual(item.find("sparkle:version", ns).text, "4242")
        self.assertEqual(item.find("sparkle:shortVersionString", ns).text, "13.1.0")
        self.assertEqual(item.find("sparkle:minimumSystemVersion", ns).text, "15.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), url)
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(enclosure.get("{%s}edSignature" % ns["sparkle"]), "c2lnbmF0dXJl")
        self.assertEqual(root.find("channel/link").text,
                         "https://github.com/klaipher/nanogram-releases/releases/latest/download/appcast.xml")

    def test_source_archive_includes_submodules(self):
        import tarfile
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            core = make_repo(tmp / "core", {"Package.swift": "// core\n"})
            ios = make_repo(tmp / "ios", {"README": "ios\n"})
            git(ios, "submodule", "add", "-q", str(core), "submodules/TelegramCore")
            git(ios, "commit", "-q", "-m", "core")
            top = make_repo(tmp / "top", {"Telegram-Mac/main.swift": "print(1)\n", "secret.txt": "x\n"})
            (top / ".gitignore").write_text("NanogramSecrets.swift\n")
            (top / "NanogramSecrets.swift").write_text("let hash = \"never\"\n")
            git(top, "add", ".gitignore")
            git(top, "submodule", "add", "-q", str(ios), "submodules/telegram-ios")
            git(top, "commit", "-q", "-m", "ios")
            git(top, "submodule", "update", "--init", "--recursive", "-q")
            out = release.source_archive(tmp / "out" / "src.tar.gz", "Nanogram-13.1.0-4242-source", root=top)
            with tarfile.open(out) as archive:
                names = set(archive.getnames())
        prefix = "Nanogram-13.1.0-4242-source/"
        self.assertIn(prefix + "submodules/telegram-ios/submodules/TelegramCore/Package.swift", names)
        self.assertIn(prefix + "submodules/telegram-ios/README", names)
        self.assertIn(prefix + "Telegram-Mac/main.swift", names)
        self.assertFalse(any(n.endswith("NanogramSecrets.swift") for n in names), names)

    def test_dirty_tree_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = make_repo(Path(tmp) / "top", {"a.txt": "a\n"})
            self.assertEqual(release.tracked_changes(top), [])
            (top / "a.txt").write_text("b\n")
            (top / "untracked.txt").write_text("u\n")
            self.assertEqual(release.tracked_changes(top), ["a.txt"])

    def test_make_dmg(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Nanogram.app"
            (app / "Contents" / "MacOS").mkdir(parents=True)
            (app / "Contents" / "MacOS" / "Nanogram").write_text("#!/bin/sh\n")
            dmg = release.make_dmg(app, Path(tmp) / "out" / "Nanogram.dmg")
            info = subprocess.run(["hdiutil", "imageinfo", str(dmg)], capture_output=True, text=True).stdout
            self.assertIn("ULFO", info)
            listing = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountrandom", tmp,
                                      str(dmg)], capture_output=True, text=True, check=True).stdout
            mount = [line.split("\t")[-1].strip() for line in listing.splitlines() if "\t/" in line][-1]
            try:
                self.assertTrue((Path(mount) / "Nanogram.app" / "Contents" / "MacOS" / "Nanogram").is_file())
                self.assertTrue((Path(mount) / "Applications").is_symlink())
            finally:
                subprocess.run(["hdiutil", "detach", mount, "-quiet"], check=False)

    def test_make_dmg_signs_the_image_when_given_an_identity(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Nanogram.app"
            (app / "Contents" / "MacOS").mkdir(parents=True)
            (app / "Contents" / "MacOS" / "Nanogram").write_text("#!/bin/sh\n")
            dmg = release.make_dmg(app, Path(tmp) / "out" / "Nanogram.dmg", identity="-")
            signed = subprocess.run(["codesign", "--verify", "--verbose", str(dmg)], capture_output=True, text=True)
            self.assertEqual(signed.returncode, 0, signed.stderr)

    def test_dmg_gatekeeper_check_uses_the_disk_image_context(self):
        self.assertEqual(release.DMG_SPCTL_ARGS, ["-a", "-vv", "-t", "open", "--context",
                                                  "context:primary-signature"])

    def test_notarize_submits_with_the_key_and_staples(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = release.asc_key(fake_asc(Path(tmp) / "asc"))
            dmg = Path(tmp) / "Nanogram.dmg"
            dmg.write_bytes(b"dmg")
            calls = []

            def run(args, **kwargs):
                calls.append(args)
                result = mock.Mock(returncode=0, stderr="")
                result.stdout = json.dumps({"id": "abc", "status": "Accepted"}) if "submit" in args else ""
                return result
            with mock.patch.object(release.subprocess, "run", side_effect=run):
                release.notarize(dmg, key)
            self.assertEqual(calls[0][:4], ["xcrun", "notarytool", "submit", str(dmg)])
            for flag in (["--key", str(key.path)], ["--key-id", "ABC123DEF4"], ["--issuer", key.issuer]):
                self.assertIn(flag, [calls[0][i:i + 2] for i in range(len(calls[0]) - 1)])
            self.assertIn("--wait", calls[0])
            self.assertEqual(calls[-1], ["xcrun", "stapler", "staple", str(dmg)])

    def test_notarize_waits_again_when_apple_times_out_after_receiving_the_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = release.asc_key(fake_asc(Path(tmp) / "asc"))
            dmg = Path(tmp) / "Nanogram.dmg"
            dmg.write_bytes(b"dmg")
            submission = "292453bc-f680-4806-888c-e2899cbc754c"
            calls = []

            def run(args, **kwargs):
                calls.append(args)
                result = mock.Mock(returncode=0, stdout="", stderr="")
                if "submit" in args:
                    result.returncode = 1
                    result.stderr = ("Error: HTTPError(statusCode: nil, error: The request timed out. "
                                     f"NSErrorFailingURLKey=https://appstoreconnect.apple.com/notary/v2/submissions/"
                                     f"{submission}?)")
                elif "wait" in args:
                    result.stdout = json.dumps({"id": submission, "status": "Accepted"})
                return result
            with mock.patch.object(release.subprocess, "run", side_effect=run):
                release.notarize(dmg, key)
            waits = [c for c in calls if c[:3] == ["xcrun", "notarytool", "wait"]]
            self.assertEqual(len(waits), 1)
            self.assertEqual(waits[0][3], submission)
            self.assertEqual(calls[-1], ["xcrun", "stapler", "staple", str(dmg)])

    def test_notarize_rejected_raises_with_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = release.asc_key(fake_asc(Path(tmp) / "asc"))
            dmg = Path(tmp) / "Nanogram.dmg"
            dmg.write_bytes(b"dmg")

            def run(args, **kwargs):
                result = mock.Mock(returncode=0, stderr="")
                result.stdout = json.dumps({"id": "abc", "status": "Invalid"}) if "submit" in args else "{}"
                return result
            with mock.patch.object(release.subprocess, "run", side_effect=run):
                with self.assertRaises(config.ConfigError) as caught:
                    release.notarize(dmg, key)
            self.assertIn("Invalid", str(caught.exception))
            self.assertIn("notarization-abc.json", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
