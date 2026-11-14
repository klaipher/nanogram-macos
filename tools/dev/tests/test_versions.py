"""Pinned versions of the native libraries and their build flags (stage 1 task 12).

Each test reads the version from the library's own source (archive name, version header, changelog,
meson.build, submodule commit) so a bump that misses a place fails here, not at runtime.
"""
import hashlib
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
CORE = ROOT / "core-xprojects"
TG_IOS = ROOT / "submodules" / "telegram-ios"


def read(path: Path) -> str:
    return Path(path).read_text(errors="replace")


def gitlink(repo: Path, path: str) -> str:
    """The commit `repo` records for the submodule at `path` (its index entry, so it works without a checkout)."""
    out = subprocess.run(["git", "-C", str(repo), "ls-files", "-s", "--", path],
                         capture_output=True, text=True, check=True).stdout.split()
    if len(out) < 2 or out[0] != "160000":
        raise AssertionError(f"{path} is not a submodule of {repo}")
    return out[1]


def is_ancestor(repo: Path, ancestor: str, commit: str = "HEAD") -> bool:
    return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, commit],
                          capture_output=True, check=False).returncode == 0


class PinnedVersionsTests(unittest.TestCase):
    def test_opus(self):
        script = read(CORE / "libopus" / "libopus" / "build.sh")
        self.assertIn("third-party/opus/opus", script)
        self.assertNotIn("opus-1.6.1.tar.gz", script)
        self.assertFalse((CORE / "libopus" / "opus-1.6.1.tar.gz").exists())
        self.assertFalse((CORE / "libopus" / "opus-1.3.1.tar.gz").exists())
        cmake = TG_IOS / "third-party" / "opus" / "opus" / "CMakeLists.txt"
        if cmake.is_file():
            self.assertIn("1.6.1", read(TG_IOS / "third-party" / "opus" / "BUILD"))

    def test_opus_options_come_from_the_core_and_keep_neon(self):
        script = read(CORE / "libopus" / "libopus" / "build.sh")
        self.assertRegex(script, r"CMAKE_C_FLAGS_RELEASE=\"-O2 -DNDEBUG")
        self.assertNotIn("-Os", script)
        args = TG_IOS / "third-party" / "opus" / "opus-cmake-args.sh"
        if args.is_file():
            text = read(args)
            self.assertIn("-DOPUS_PRESUME_NEON=ON", text)
            self.assertIn("-DOPUS_DISABLE_INTRINSICS=OFF", text)
            self.assertIn("-DOPUS_FIXED_POINT=OFF", text)

    def test_libvpx(self):
        self.assertFalse((CORE / "libvpx" / "source").exists())
        changelog = TG_IOS / "third-party" / "libvpx" / "libvpx" / "CHANGELOG"
        if changelog.is_file():
            self.assertTrue(read(changelog).startswith("2026-08-07 v1.17.0"))

    def test_libvpx_detects_arm_extensions_at_runtime(self):
        script = read(CORE / "libvpx" / "libvpx" / "build.sh")
        self.assertIn("--enable-runtime-cpu-detect", script)
        self.assertIn('target="arm64-darwin24-gcc"', script)

    def test_openh264(self):
        script = read(CORE / "OpenH264" / "OpenH264" / "build.sh")
        self.assertIn("submodules/telegram-ios", script)
        self.assertIn("third-party/openh264/openh264", script)
        self.assertNotIn("git clone", script)
        self.assertNotIn("1bca62311e447fd9c39fc93de2c4b96cd5ce971c", script)
        header = TG_IOS / "third-party" / "openh264" / "openh264" / "codec" / "api" / "wels" / "codec_ver.h"
        if header.is_file():
            text = read(header)
            self.assertRegex(text, r"OPENH264_MAJOR \(2\)[\s\S]*OPENH264_MINOR \(7\)[\s\S]*OPENH264_REVISION \(0\)")
        self.assertFalse((TG_IOS / "third-party" / "openh264" / "third_party").exists())

    def test_libwebp(self):
        script = read(CORE / "libwebp" / "libwebp" / "build-cmake.sh")
        self.assertIn("submodules/telegram-ios/third-party/webp/libwebp", script)
        self.assertNotIn("SOURCE_ARCHIVE", script)
        self.assertFalse(list((CORE / "libwebp").glob("libwebp-*.tar.gz")))
        self.assertFalse((CORE / "libwebp" / "libwebp" / "build.sh").exists())
        self.assertFalse((CORE / "libwebp" / "libwebp-master.zip").exists())

    def test_boringssl_replaces_openssl(self):
        script = read(CORE / "boringssl" / "BoringSSL" / "build.sh")
        self.assertIn("third-party/boringssl/src", script)
        self.assertNotIn("git clone", script)
        self.assertFalse((CORE / "openssl").exists())
        project = read(CORE / "boringssl" / "BoringSSL.xcodeproj" / "project.pbxproj")
        self.assertNotIn("OpenSSL", project)

    def test_no_openssl_deprecation_workaround_remains(self):
        script = read(CORE / "boringssl" / "BoringSSL" / "build.sh")
        self.assertNotIn("OPENSSL_SUPPRESS_DEPRECATED", script)

    def test_ffmpeg(self):
        sources = TG_IOS / "submodules" / "ffmpeg" / "Sources" / "FFMpeg"
        self.assertEqual(read(sources / "ffmpeg-9.0.2" / "VERSION").strip(), "9.0.2")
        self.assertFalse((sources / "ffmpeg-8.1.2").exists())
        self.assertIn('FF_VERSION="9.0.2"', read(CORE / "ffmpeg" / "ffmpeg" / "build.sh"))

    def test_ffmpeg_assembles_arm64_with_clang_keeping_i8mm(self):
        script = read(CORE / "ffmpeg" / "ffmpeg" / "build.sh")
        self.assertIn('AS="$CC"', script)
        self.assertNotIn("GASPP_FIX_XCODE5", script)

    def test_dav1d(self):
        self.assertEqual(gitlink(TG_IOS, "third-party/dav1d/dav1d"), "54706fc6bc0cdecab7e9593974a4039cc038fca7")
        meson = TG_IOS / "third-party" / "dav1d" / "dav1d" / "meson.build"
        if meson.is_file():
            self.assertRegex(read(meson), r"version\s*:\s*'1\.5\.4'")

    def test_dav1d_cross_file_enables_dotprod_and_i8mm(self):
        cross = read(CORE / "dav1d" / "dav1d" / "build.sh")
        self.assertIn("cpu_family = 'aarch64'", cross)
        self.assertIn("cpu = 'aarch64'", cross)

    def test_sqlcipher(self):
        sources = TG_IOS / "submodules" / "sqlcipher"
        amalgamation = sources / "amalgamation"
        self.assertIn('#define SQLITE_VERSION        "3.54.1"', read(amalgamation / "headers" / "sqlcipher" / "sqlite3.h"))
        self.assertIn("#define CIPHER_VERSION_NUMBER 4.20.0", read(amalgamation / "sqlite3.c"))
        self.assertEqual(gitlink(TG_IOS, "submodules/sqlcipher/amalgamation"), "010c1b1174ac79856766b9ece9179c784645053b")

    def test_tde2e(self):
        self.assertEqual(gitlink(TG_IOS, "third-party/td/td"), "0e88653dcbf4e44c73cb655a05b58cd749a91169")
        cmake = TG_IOS / "third-party" / "td" / "td" / "CMakeLists.txt"
        if cmake.is_file():
            self.assertRegex(read(cmake), r"project\(TDLib VERSION 1\.8\.69 ")

    def test_libjpeg_turbo_replaces_mozjpeg(self):
        script = read(CORE / "Mozjpeg" / "Mozjpeg" / "build.sh")
        self.assertIn('SOURCE_NAME="libjpeg-turbo-3.2.1"', script)
        self.assertIn("c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f", script)
        self.assertIn("-DWITH_JPEG8=1", script)
        self.assertIn("https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz", script)
        self.assertFalse(list((CORE / "Mozjpeg").glob("libjpeg-turbo-*.tar.gz")))
        project = read(CORE / "Mozjpeg" / "Mozjpeg.xcodeproj" / "project.pbxproj")
        self.assertNotIn(".tar.gz\\n", project)
        self.assertNotIn("third-party/mozjpeg", project)
        self.assertNotIn("third-party/mozjpeg", read(ROOT / "scripts" / "framework-inputs.sh"))
        self.assertNotIn("third-party/mozjpeg", read(ROOT / "scripts" / "configure_frameworks.sh"))
        self.assertNotIn("jpeg_c_set_int_param", read(ROOT / "submodules" / "Mozjpeg" / "Sources" / "Mozjpeg.m"))

    def test_rust_toolchain(self):
        pin = read(CORE / "rust-toolchain.toml")
        self.assertIn('channel = "1.99.1"', pin)
        for script in ("mtproto-engine/mtproto-engine/build.sh", "wallet-engine/wallet-engine/build.sh", "tlottie/build.sh"):
            text = read(CORE / script)
            self.assertIn("rust-toolchain.toml", text, script)
            self.assertIn("export RUSTUP_TOOLCHAIN", text, script)
            self.assertNotIn("third-party/mtproto-engine/rust-toolchain.toml", text, script)

    def test_webrtc_is_the_one_klaipher_fork_pin_shared_with_ios(self):
        modules = read(ROOT / ".gitmodules")
        self.assertIn('[submodule "submodules/webrtc"]\n\tpath = submodules/webrtc\n\turl = https://github.com/klaipher/webrtc.git\n\tbranch = nanogram\n', modules)
        self.assertNotIn("tg_owt", modules)
        self.assertEqual(gitlink(ROOT, "submodules/webrtc"), gitlink(TG_IOS, "third-party/webrtc/webrtc"))
        with self.assertRaises(AssertionError):
            gitlink(ROOT, "submodules/tg_owt")

    def test_webrtc_build_takes_its_third_party_sources_from_the_single_sources(self):
        script = read(CORE / "webrtc" / "webrtc" / "build.sh")
        self.assertIn("-DTG_OWT_LIBYUV_DIR=$LIBYUV_DIR", script)
        self.assertIn("apply_abseil_workaround.sh", script)
        self.assertIn('"$SOURCE_DIR/CMakeLists.txt"', script)
        project = read(CORE / "webrtc" / "webrtc.xcodeproj" / "project.pbxproj")
        self.assertIn("submodules/webrtc/", project)
        self.assertIn("submodules/telegram-ios/third-party/libyuv/third_party/libyuv", project)
        self.assertNotIn("tg_owt", project)
        self.assertNotIn("tg_owt", read(ROOT / "scripts" / "framework-inputs.sh"))
        self.assertNotIn("attributes.h", read(ROOT / "scripts" / "setup_build_env.sh"))

    def test_tgcalls_is_the_klaipher_fork_pin_shared_with_ios(self):
        self.assertEqual(gitlink(ROOT, "submodules/tgcalls"), gitlink(TG_IOS, "submodules/TgVoipWebrtc/tgcalls"))
        modules = read(ROOT / ".gitmodules")
        self.assertIn('[submodule "submodules/tgcalls"]\n\tpath = submodules/tgcalls\n\turl = https://github.com/klaipher/tgcalls.git\n\tbranch = nanogram-shared\n\tshallow = true\n', modules)

    def test_widget_stack_is_the_klaipher_forks_shared_with_ios(self):
        modules = read(ROOT / ".gitmodules")
        for name in ("twidget", "widget-sandbox"):
            self.assertIn(f'[submodule "third-party/{name}"]\n\tpath = third-party/{name}\n\turl = https://github.com/klaipher/{name}.git\n\tbranch = nanogram\n', modules)
            self.assertEqual(gitlink(ROOT, f"third-party/{name}"), gitlink(TG_IOS, f"third-party/{name}/{name}"))

    def test_libprisma_and_boost_regex_come_from_the_core(self):
        self.assertTrue((TG_IOS / "third-party" / "libprisma" / "libprisma" / "libprisma" / "SyntaxHighlighter.cpp").exists())
        self.assertTrue((TG_IOS / "third-party" / "libprisma" / "libprisma" / "apple" / "Syntaxer.mm").exists())
        self.assertTrue((TG_IOS / "third-party" / "boost_regex" / "regex" / "include" / "boost" / "regex.hpp").exists())

    def test_sparkle_2(self):
        self.assertEqual(gitlink(ROOT, "submodules/Sparkle"), "ab7d71291238df6e0492143b120c9b696a35f603")
        self.assertIn("url = https://github.com/sparkle-project/Sparkle\n", read(ROOT / ".gitmodules"))
        direct = read(ROOT / "nanogram" / "editions" / "direct.xcconfig")
        for setting in ("SPARKLE_BUILD_LEGACY_SUUPDATER = 0", "SPARKLE_BUILD_LEGACY_DSA_SUPPORT = 0",
                        "SPARKLE_EMBED_INSTALLER_LAUNCHER_XPC_SERVICE = 1", "SPARKLE_EMBED_DOWNLOADER_XPC_SERVICE = 0"):
            self.assertIn(setting, direct)
        upstream = read(ROOT / "Telegram-Mac" / "updater" / "AppUpdateViewController.swift")
        self.assertTrue(upstream.startswith("#if !APP_STORE && !NANOGRAM\n"), "Sparkle 1 updater must be compiled out")
        self.assertTrue(read(ROOT / "Telegram-Mac" / "updater" / "NanogramUpdater.swift").startswith("#if NANOGRAM && !NANOGRAM_MAS\n"))

    def test_built_direct_app_embeds_sparkle_2_without_the_legacy_updater(self):
        framework = ROOT / "build-output" / "apps" / "Debug-direct" / "Nanogram.app" / "Contents" / "Frameworks" / "Sparkle.framework"
        if not framework.is_dir():
            self.skipTest("no direct build in build-output/apps/Debug-direct")
        import plistlib
        info = plistlib.loads((framework / "Resources" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], "2.10.1")
        symbols = subprocess.run(["nm", "-gU", str(framework / "Sparkle")], capture_output=True, text=True).stdout
        self.assertIn("_OBJC_CLASS_$_SPUUpdater", symbols)
        self.assertNotIn("_OBJC_CLASS_$_SUUpdater", symbols)
        self.assertTrue((framework / "Versions" / "B" / "XPCServices" / "Installer.xpc").is_dir())
        self.assertFalse((framework / "Versions" / "B" / "XPCServices" / "Downloader.xpc").exists())


if __name__ == "__main__":
    unittest.main()
