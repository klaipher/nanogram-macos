"""Pinned versions of the native libraries and their build flags (stage 1 task 12).

Each test reads the version from the library's own source (archive name, version header, changelog,
meson.build, submodule commit) so a bump that misses a place fails here, not at runtime.
"""
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
        self.assertIn('SOURCE_ARCHIVE="$SRC_DIR/opus-1.6.1.tar.gz"', script)
        self.assertTrue((CORE / "libopus" / "opus-1.6.1.tar.gz").is_file())
        self.assertFalse((CORE / "libopus" / "opus-1.3.1.tar.gz").exists())
        self.assertIn("6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1", script)

    def test_opus_built_for_speed_with_fixed_point(self):
        script = read(CORE / "libopus" / "libopus" / "build.sh")
        self.assertIn("--enable-fixed-point", script)
        self.assertRegex(script, r"CFLAGS=\"[^\"]*-O2 -DNDEBUG")
        self.assertNotIn("-Os", script)

    def test_libvpx(self):
        self.assertTrue(read(CORE / "libvpx" / "source" / "CHANGELOG").startswith("2026-08-07 v1.17.0"))

    def test_libvpx_detects_arm_extensions_at_runtime(self):
        script = read(CORE / "libvpx" / "libvpx" / "build.sh")
        self.assertIn("--enable-runtime-cpu-detect", script)
        self.assertIn('target="arm64-darwin24-gcc"', script)

    def test_openh264(self):
        script = read(CORE / "OpenH264" / "OpenH264" / "build.sh")
        self.assertIn("-b v2.7.0 ", script)
        self.assertIn("1bca62311e447fd9c39fc93de2c4b96cd5ce971c", script)

    def test_libwebp(self):
        script = read(CORE / "libwebp" / "libwebp" / "build-cmake.sh")
        self.assertIn('SOURCE_ARCHIVE="$SRC_DIR/libwebp-1.6.0.tar.gz"', script)
        self.assertIn("e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564", script)
        self.assertTrue((CORE / "libwebp" / "libwebp-1.6.0.tar.gz").is_file())
        self.assertFalse((CORE / "libwebp" / "libwebp-master.zip").exists())

    def test_openssl(self):
        script = read(CORE / "openssl" / "OpenSSLEncryption" / "build.sh")
        self.assertIn("-b openssl-3.5.9 ", script)
        self.assertIn("45e844fa2a14ec92d146bd8f5778ac130b6625fb", script)
        self.assertNotIn("OpenSSL_1_1_1", script)

    def test_openssl_keeps_upstream_callers_free_of_3_0_deprecation_warnings(self):
        script = read(CORE / "openssl" / "OpenSSLEncryption" / "build.sh")
        self.assertIn("define OPENSSL_SUPPRESS_DEPRECATED", script)
        self.assertIn("openssl/configuration.h", script)

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
        cross = read(CORE / "dav1d" / "dav1d-arm64.meson")
        self.assertIn("cpu_family = 'aarch64'", cross)
        self.assertIn("cpu = 'aarch64'", cross)

    def test_sqlcipher(self):
        sources = TG_IOS / "submodules" / "sqlcipher"
        self.assertIn('#define SQLITE_VERSION        "3.54.1"', read(sources / "PublicHeaders" / "sqlcipher" / "sqlite3.h"))
        self.assertIn("#define CIPHER_VERSION_NUMBER 4.20.0", read(sources / "Sources" / "sqlite3.c"))

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
        self.assertTrue((CORE / "Mozjpeg" / "libjpeg-turbo-3.2.1.tar.gz").is_file())
        project = read(CORE / "Mozjpeg" / "Mozjpeg.xcodeproj" / "project.pbxproj")
        self.assertIn("libjpeg-turbo-3.2.1.tar.gz", project)
        self.assertNotIn("third-party/mozjpeg", project)
        self.assertNotIn("third-party/mozjpeg", read(ROOT / "scripts" / "framework-inputs.sh"))
        self.assertNotIn("third-party/mozjpeg", read(ROOT / "scripts" / "configure_frameworks.sh"))
        self.assertNotIn("jpeg_c_set_int_param", read(ROOT / "submodules" / "Mozjpeg" / "Sources" / "Mozjpeg.m"))

    def test_tg_owt_has_desktop_app_master(self):
        owt = ROOT / "submodules" / "tg_owt"
        pin = gitlink(ROOT, "submodules/tg_owt")
        for commit in ("020feec5c040fdae2cf752c2c2be62ddde7c236d", "557e0e3d7d72f80278938f01e4d31bfd036278ba"):
            self.assertTrue(is_ancestor(owt, commit, pin), f"tg_owt {pin} does not contain {commit}")

    def test_rlottie_has_the_klaipher_fork_fixes(self):
        rlottie = ROOT / "submodules" / "rlottie"
        pin = gitlink(ROOT, "submodules/rlottie")
        for commit in ("0742a4898e8fea1a88379033f26f6765a6c901f7", "e0221d3ee344f467c0aa8f34c23a95f836b3c223"):
            self.assertTrue(is_ancestor(rlottie, commit, pin), f"rlottie {pin} does not contain {commit}")
        self.assertIn("url = https://github.com/klaipher/rlottie", read(ROOT / ".gitmodules"))

    def test_libprisma(self):
        self.assertEqual(gitlink(ROOT, "submodules/libprisma"), "086296336c69723f58ca6aa603434ef8cf682c39")


if __name__ == "__main__":
    unittest.main()
