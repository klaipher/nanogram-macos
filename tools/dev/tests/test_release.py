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

from nanogram import config, release, sparkle  # noqa: E402

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


class DecoderServiceStampTests(unittest.TestCase):
    def test_set_build_number_stamps_and_resigns_the_decoder_service_before_the_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "Nanogram.xcarchive"
            app = archive / "Products" / "Applications" / "Nanogram.app"
            xpc = app / "Contents" / "XPCServices" / "NanogramDecoder.xpc"
            for bundle in (app, xpc):
                (bundle / "Contents").mkdir(parents=True)
                (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "283357"}))
            (archive / "Info.plist").write_bytes(plistlib.dumps(
                {"ApplicationProperties": {"CFBundleVersion": "283357", "ApplicationPath": "Applications/Nanogram.app"}}))
            entitlements = Path(tmp) / "MAS.entitlements"
            with mock.patch.object(release, "_resign") as resign:
                release.set_build_number(archive, "4242", entitlements)
            self.assertEqual(plistlib.loads((xpc / "Contents" / "Info.plist").read_bytes())["CFBundleVersion"], "4242")
            self.assertEqual([c.args for c in resign.call_args_list], [(xpc, None), (app, entitlements)])


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


class SignedAppcastTests(unittest.TestCase):
    PREFIX = "<!-- sparkle-signatures:\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.key_file = Path(self.tmp.name) / "keys" / "sparkle_ed25519"
        self.public = sparkle.ensure_keys(self.key_file)
        dmg = Path(self.tmp.name) / "Nanogram.dmg"
        dmg.write_bytes(b"x" * 10)
        self.feed = release.appcast([release.appcast_entry("13.1.0", "4242", dmg, "c2ln", "https://example.org/a.dmg")])

    def parse(self, signed):
        data = signed.encode()
        start = data.rindex(self.PREFIX.encode())
        block = data[start + len(self.PREFIX):].decode()
        self.assertTrue(block.endswith("-->\n"), block)
        lines = dict(line.split(": ", 1) for line in block[:-len("-->\n")].splitlines())
        return data[:start], lines["edSignature"], int(lines["length"])

    def verify(self, content, signature):
        path = Path(self.tmp.name) / "content.xml"
        path.write_bytes(content)
        return sparkle.verify(path, signature, self.public)

    def test_feed_ends_with_a_signing_block_in_sparkles_format(self):
        signed = release.sign_appcast(self.feed, self.key_file)
        content, signature, length = self.parse(signed)
        self.assertEqual(content, self.feed.encode())
        self.assertEqual(length, len(content))
        self.assertTrue(self.verify(content, signature))

    def test_signed_feed_is_still_valid_xml(self):
        import xml.etree.ElementTree as ET
        root = ET.fromstring(release.sign_appcast(self.feed, self.key_file))
        self.assertIsNotNone(root.find("channel/item"))

    def test_a_changed_feed_does_not_verify_against_the_signature(self):
        _, signature, _ = self.parse(release.sign_appcast(self.feed, self.key_file))
        tampered = self.feed.replace("4242", "4243").encode()
        self.assertFalse(self.verify(tampered, signature))

    def test_signing_an_already_signed_feed_replaces_the_block(self):
        once = release.sign_appcast(self.feed, self.key_file)
        twice = release.sign_appcast(once, self.key_file)
        self.assertEqual(twice.count("sparkle-signatures"), 1)
        self.assertEqual(self.parse(twice)[0], self.feed.encode())

    def test_write_signed_appcast_writes_a_verifiable_file(self):
        out = Path(self.tmp.name) / "out"
        out.mkdir()
        path = release.write_signed_appcast(out, [], key_file=self.key_file)
        self.assertEqual(path, out / "appcast.xml")
        content, signature, length = self.parse(path.read_text())
        self.assertEqual(length, len(content))
        self.assertTrue(self.verify(content, signature))

    def test_release_direct_writes_the_feed_through_the_signing_step(self):
        import inspect
        source = inspect.getsource(release.release_direct)
        self.assertIn("write_signed_appcast", source)
        self.assertNotIn('"appcast.xml").write_text', source)


class SparkleNestedCodeTests(unittest.TestCase):
    def test_sparkle_xpc_services_and_helpers_are_checked_for_distribution_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            version = app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B"
            (version / "XPCServices" / "Installer.xpc" / "Contents" / "MacOS").mkdir(parents=True)
            (version / "XPCServices" / "Downloader.xpc" / "Contents" / "MacOS").mkdir(parents=True)
            (version / "Updater.app").mkdir()
            (version / "Autoupdate").write_bytes(bytes.fromhex("cffaedfe") + b"\0" * 60)
            code = [str(path.relative_to(version)) for path in release.nested_code(app) if version in path.parents]
            self.assertEqual(sorted(code), ["Autoupdate", "Updater.app", "XPCServices/Downloader.xpc",
                                            "XPCServices/Installer.xpc"])


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

    def test_release_notes_html_keeps_only_bullets(self):
        notes = ("Nanogram is an unofficial Telegram client.\n\n**What's better in this update**\n"
                 "- Calls: **screen sharing** stops <reliably> & fast.\n"
                 "• Chats open faster.\n\n**Requirements:** macOS 15.\n")
        self.assertEqual(release.release_notes_html(notes),
                         "<ul><li>Calls: screen sharing stops &lt;reliably&gt; &amp; fast.</li>"
                         "<li>Chats open faster.</li></ul>")

    def test_release_notes_html_rejects_notes_without_bullets(self):
        with self.assertRaises(release.ReleaseError):
            release.release_notes_html("Just a paragraph.\n")

    def test_appcast_entry_carries_release_notes(self):
        import xml.etree.ElementTree as ET
        with tempfile.TemporaryDirectory() as tmp:
            dmg = Path(tmp) / "Nanogram-13.1.0-4242.dmg"
            dmg.write_bytes(b"x")
            entry = release.appcast_entry("13.1.0", "4242", dmg, "c2ln", "https://example.org/a.dmg",
                                          notes_html="<ul><li>A ]]> B</li></ul>")
            plain = release.appcast_entry("13.1.0", "4242", dmg, "c2ln", "https://example.org/a.dmg")
        item = ET.fromstring(release.appcast([entry])).find("channel/item")
        self.assertEqual(item.find("description").text, "<ul><li>A ]]> B</li></ul>")
        self.assertIsNone(ET.fromstring(release.appcast([plain])).find("channel/item/description"))

    def test_release_direct_cli_requires_notes(self):
        with mock.patch.object(release, "release_direct") as direct, \
                mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            release.main(["release-direct"])
        direct.assert_not_called()

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


class EnhancedSecurityExportTests(unittest.TestCase):
    KEYS = dict(release.enhanced_security_module.SOFT_MODE_KEYS)
    GRANT = {release.enhanced_security_module.PREFIX: True}

    def problems(self, signed, profile):
        return release.enhanced_security_problems(Path("/x/Nanogram.app"), entitlements_of=lambda path: signed,
                                                  profile_of=lambda path: profile)

    def test_kept_keys_and_a_granting_profile_pass(self):
        self.assertEqual(self.problems(self.KEYS, self.GRANT), [])

    def test_each_dropped_key_is_named(self):
        signed = dict(self.KEYS)
        del signed[f"{release.enhanced_security_module.PREFIX}.checked-allocations.soft-mode"]
        problems = self.problems(signed, self.GRANT)
        self.assertEqual(len(problems), 1)
        self.assertIn("checked-allocations.soft-mode", problems[0])

    def test_a_missing_or_non_granting_profile_is_named(self):
        self.assertIn("embeds no provisioning profile", self.problems(self.KEYS, None)[0])
        self.assertIn("does not grant", self.problems(self.KEYS, {})[0])

    def test_the_export_check_runs_only_when_enhanced_security_was_requested(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            release.unsign_resource_bundles(app)
            with mock.patch.object(release, "_authority", return_value=DISTRIBUTION), \
                    mock.patch.object(release, "enhanced_security_problems", return_value=["dropped"]) as check:
                with mock.patch("sys.stdout"):
                    release.check_exported_app(app, "mas", enhanced_security=False)
                check.assert_not_called()
                with self.assertRaises(release.ReleaseError), mock.patch("sys.stderr"):
                    release.check_exported_app(app, "mas", enhanced_security=True)
                check.assert_called_once_with(app)

    def test_the_export_check_follows_the_release_switch_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp))
            release.unsign_resource_bundles(app)
            with mock.patch.object(release, "_authority", return_value=DISTRIBUTION), \
                    mock.patch.object(release, "enhanced_security_problems", return_value=["dropped"]), \
                    mock.patch.dict(os.environ, {release.ENHANCED_SECURITY_ENV: "1"}):
                with self.assertRaises(release.ReleaseError), mock.patch("sys.stderr"):
                    release.check_exported_app(app, "mas")


class BuildRecordTests(unittest.TestCase):
    def make_archive(self, tmp: Path, with_dsym=True) -> Path:
        archive = tmp / "Nanogram.xcarchive"
        app = archive / "Products" / "Applications" / "Nanogram.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "MacOS" / "Nanogram").write_bytes(b"binary")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Nanogram"}))
        if with_dsym:
            dsym = archive / "dSYMs" / "Nanogram.app.dSYM" / "Contents" / "Resources" / "DWARF"
            dsym.mkdir(parents=True)
            (dsym / "Nanogram").write_bytes(b"dwarf")
            other = archive / "dSYMs" / "Sparkle.framework.dSYM" / "Contents"
            other.mkdir(parents=True)
            (other / "Info.plist").write_bytes(b"x")
        return archive

    def test_build_info_text_has_the_ios_fields(self):
        text = release.build_info_text("202611061200", "a" * 40, "main", dirty=False, pushed=True)
        self.assertEqual(text, "build 202611061200\ncommit " + "a" * 40 + "\nbranch main\ndirty no\npushed yes\n")
        text = release.build_info_text("1", "b" * 40, "x", dirty=True, pushed=False)
        self.assertIn("dirty yes\n", text)
        self.assertIn("pushed no\n", text)

    def test_git_state_clean_and_pushed(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            origin = make_repo(tmp / "origin", {"a.txt": "a\n"})
            clone = tmp / "clone"
            import subprocess
            subprocess.run(["git", "clone", "-q", str(origin), str(clone)], check=True, capture_output=True)
            commit, branch, dirty, pushed = release.git_state(clone)
            self.assertEqual(commit, git(clone, "rev-parse", "HEAD").strip())
            self.assertEqual(branch, "main")
            self.assertFalse(dirty)
            self.assertTrue(pushed)

    def test_git_state_dirty_and_unpushed(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            origin = make_repo(tmp / "origin", {"a.txt": "a\n"})
            clone = tmp / "clone"
            import subprocess
            subprocess.run(["git", "clone", "-q", str(origin), str(clone)], check=True, capture_output=True)
            (clone / "a.txt").write_text("b\n")
            git(clone, "commit", "-q", "-am", "local")
            (clone / "a.txt").write_text("c\n")
            _, _, dirty, pushed = release.git_state(clone)
            self.assertTrue(dirty)
            self.assertFalse(pushed)

    def test_warnings_name_each_problem(self):
        self.assertEqual(release.build_warnings("1", "c" * 40, dirty=False, pushed=True, unreleased=False), [])
        warnings = release.build_warnings("1", "c" * 40, dirty=True, pushed=False, unreleased=True)
        self.assertEqual(len(warnings), 3)
        self.assertTrue(any("uncommitted" in w for w in warnings))
        self.assertTrue(any("remote" in w for w in warnings))
        self.assertTrue(any("Unreleased" in w for w in warnings))

    def test_unreleased_entries_are_found_in_the_changelog(self):
        with tempfile.TemporaryDirectory() as tmp:
            changelog = Path(tmp) / "CHANGELOG.md"
            changelog.write_text("# Changelog\n\n## Unreleased\n\n## 1.0 (5)\n- done\n")
            self.assertFalse(release.has_unreleased_entries(changelog))
            changelog.write_text("# Changelog\n\n## Unreleased\n- something\n\n## 1.0 (5)\n- done\n")
            self.assertTrue(release.has_unreleased_entries(changelog))
            self.assertFalse(release.has_unreleased_entries(Path(tmp) / "missing.md"))

    def test_dsyms_are_zipped_outside_the_archive_with_uuids(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            archive = self.make_archive(tmp)
            dest = tmp / "dsyms"
            uuids = {"Nanogram": ["AAAA-1"], "Nanogram.app.dSYM": ["AAAA-1"], "Sparkle.framework.dSYM": ["BBBB-2"]}
            found = release.archive_dsyms(archive, dest, "direct", "202611061200",
                                          uuids_of=lambda path: uuids[path.name])
            self.assertEqual(found, dest / "direct" / "202611061200")
            self.assertTrue((found / "Nanogram.app.dSYM.zip").is_file())
            self.assertTrue((found / "Sparkle.framework.dSYM.zip").is_file())
            listing = (found / "uuids.txt").read_text()
            self.assertIn("Nanogram.app.dSYM AAAA-1", listing)
            self.assertTrue(archive.is_dir())
            self.assertTrue((archive / "dSYMs" / "Nanogram.app.dSYM").is_dir())

    def test_a_rebuilt_number_holds_only_the_new_dsyms(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            archive = self.make_archive(tmp)
            dest = tmp / "dsyms"
            old = dest / "direct" / "7"
            old.mkdir(parents=True)
            (old / "stale.dSYM.zip").write_text("old")
            release.archive_dsyms(archive, dest, "direct", "7", uuids_of=lambda path: ["U"])
            self.assertFalse((old / "stale.dSYM.zip").exists())
            self.assertTrue((old / "Nanogram.app.dSYM.zip").exists())

    def test_a_dsym_that_does_not_match_the_app_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            archive = self.make_archive(tmp)
            uuids = {"Nanogram": ["AAAA-1"], "Nanogram.app.dSYM": ["CCCC-3"], "Sparkle.framework.dSYM": ["B"]}
            with self.assertRaises(config.ConfigError) as caught:
                release.archive_dsyms(archive, tmp / "dsyms", "direct", "9", uuids_of=lambda path: uuids[path.name])
            self.assertIn("does not match", str(caught.exception))
            self.assertFalse((tmp / "dsyms" / "direct" / "9").exists())

    def test_an_archive_without_dsyms_gives_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            archive = self.make_archive(tmp, with_dsym=False)
            self.assertIsNone(release.archive_dsyms(archive, tmp / "dsyms", "direct", "9", uuids_of=lambda path: ["U"]))

    def test_record_writes_build_info_next_to_the_artifacts_and_the_dsyms(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            origin = make_repo(tmp / "origin", {"a.txt": "a\n", "CHANGELOG.md": "## Unreleased\n"})
            import subprocess
            clone = tmp / "clone"
            subprocess.run(["git", "clone", "-q", str(origin), str(clone)], check=True, capture_output=True)
            archive = self.make_archive(tmp)
            out_dir = tmp / "out"
            out_dir.mkdir()
            printed = []
            release.record_build(archive, out_dir, "direct", "55", dsym_root=tmp / "dsyms", root=clone,
                                 uuids_of=lambda path: ["U"], say=printed.append)
            info = (out_dir / "BUILD-INFO.txt").read_text()
            self.assertIn("build 55\n", info)
            self.assertIn("commit " + git(clone, "rev-parse", "HEAD").strip() + "\n", info)
            self.assertIn("dirty no\n", info)
            self.assertIn("pushed yes\n", info)
            self.assertEqual((tmp / "dsyms" / "direct" / "55" / "BUILD-INFO.txt").read_text(), info)
            self.assertEqual(sorted(path.name for path in out_dir.iterdir()), ["BUILD-INFO.txt"])

    def test_record_survives_an_archive_without_dsyms(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            origin = make_repo(tmp / "origin", {"a.txt": "a\n"})
            archive = self.make_archive(tmp, with_dsym=False)
            out_dir = tmp / "out"
            out_dir.mkdir()
            printed = []
            release.record_build(archive, out_dir, "mas", "56", dsym_root=tmp / "dsyms", root=origin,
                                 uuids_of=lambda path: ["U"], say=printed.append)
            self.assertTrue((out_dir / "BUILD-INFO.txt").is_file())
            self.assertTrue(any("dSYM" in line for line in printed))


if __name__ == "__main__":
    unittest.main()
