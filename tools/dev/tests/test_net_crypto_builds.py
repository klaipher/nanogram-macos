"""Crypto libraries built by shell scripts get the app's memory-safety hardening (night/net-crypto, 2026-11-05).

Nanogram.xcconfig hardens the C, C++ and Objective-C Xcode compiles. BoringSSL and tde2e (both CMake)
are built by scripts that never see those settings, so the scripts pass the same flags themselves.
BoringSSL is the one fork iOS and Android build too; the Mac builds it from the core's submodule.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
XCCONFIG = ROOT / "nanogram" / "Nanogram.xcconfig"
BORINGSSL = ROOT / "core-xprojects" / "boringssl" / "BoringSSL" / "build.sh"
TDE2E = ROOT / "core-xprojects" / "tde2e" / "tde2e" / "build.sh"

C_HARDENING = ("-ftrivial-auto-var-init=zero", "-fstack-protector-strong")
LIBCXX_HARDENING = "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"


class BoringSslBuildTests(unittest.TestCase):
    def setUp(self):
        self.script = BORINGSSL.read_text()

    def test_the_app_settings_still_use_the_flags_the_script_mirrors(self):
        xcconfig = XCCONFIG.read_text()
        for flag in C_HARDENING:
            self.assertRegex(xcconfig, rf"(?m)^OTHER_CFLAGS = .*{re.escape(flag)}")

    def test_the_script_passes_every_hardening_flag(self):
        match = re.search(r'(?m)^HARDENING_FLAGS="([^"]*)"$', self.script)
        self.assertIsNotNone(match)
        flags = match.group(1).split()
        for flag in C_HARDENING + (LIBCXX_HARDENING,):
            self.assertIn(flag, flags)
        self.assertIn('-DCMAKE_C_FLAGS="$HARDENING_FLAGS"', self.script)
        self.assertIn('-DCMAKE_CXX_FLAGS="$HARDENING_FLAGS"', self.script)

    def test_ios_builds_with_the_same_flags(self):
        bazelrc = (ROOT / "submodules" / "telegram-ios" / ".bazelrc")
        if not bazelrc.exists():
            self.skipTest("core submodule not checked out")
        text = bazelrc.read_text()
        for flag in C_HARDENING + (LIBCXX_HARDENING,):
            self.assertIn(flag, text)

    def test_release_options_match_ios(self):
        self.assertIn('-DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG"', self.script)
        self.assertIn('-DCMAKE_BUILD_TYPE=Release', self.script)
        self.assertIn('-DBUILD_SHARED_LIBS=OFF', self.script)
        self.assertIn('-DBUILD_TESTING=OFF', self.script)

    def test_the_assembly_stays_on_as_on_ios(self):
        self.assertNotIn("OPENSSL_NO_ASM", self.script)

    def test_it_builds_the_cores_submodule_and_downloads_nothing(self):
        self.assertIn("submodules/telegram-ios/third-party/boringssl/src", self.script)
        self.assertNotIn("git clone", self.script)
        self.assertNotIn("curl", self.script)

    def test_only_crypto_and_ssl_are_built(self):
        self.assertRegex(self.script, r"ninja -C \"\$OUT_DIR/\$ARCH\" crypto ssl")

    def test_the_outputs_have_the_layout_the_project_links(self):
        for path in ("boringssl/lib", "boringssl/include", "libcrypto.a", "libssl.a"):
            self.assertIn(path, self.script)

    def test_openssl_is_gone(self):
        self.assertFalse((ROOT / "core-xprojects" / "openssl").exists())


class TdE2eBuildTests(unittest.TestCase):
    def setUp(self):
        self.script = TDE2E.read_text()

    def test_target_build_gets_every_hardening_flag(self):
        match = re.search(r'(?m)^HARDENING_FLAGS="([^"]*)"$', self.script)
        self.assertIsNotNone(match)
        flags = match.group(1).split()
        for flag in C_HARDENING + (LIBCXX_HARDENING,):
            self.assertIn(flag, flags)
        self.assertIn('-DCMAKE_C_FLAGS="$HARDENING_FLAGS"', self.script)
        self.assertIn('-DCMAKE_CXX_FLAGS="$HARDENING_FLAGS"', self.script)

    def test_the_host_source_generators_stay_plain(self):
        generators = self.script.index("cmake -G Ninja -DTD_GENERATE_SOURCE_FILES=ON")
        flags = self.script.index("HARDENING_FLAGS=")
        target = self.script.index("cmake --build . --target tde2e")
        self.assertLess(generators, flags)
        self.assertLess(flags, target)


if __name__ == "__main__":
    unittest.main()
