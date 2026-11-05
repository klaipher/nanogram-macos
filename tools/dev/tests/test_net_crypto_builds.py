"""Crypto libraries built by shell scripts get the app's memory-safety hardening (night/net-crypto, 2026-11-05).

Nanogram.xcconfig hardens the C, C++ and Objective-C Xcode compiles. OpenSSL (Configure + make) and
tde2e (CMake) are built by scripts that never see those settings, so the scripts pass the same flags
themselves. OpenSSL is cloned by tag and the tag must still name the pinned commit.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
XCCONFIG = ROOT / "nanogram" / "Nanogram.xcconfig"
OPENSSL = ROOT / "core-xprojects" / "openssl" / "OpenSSLEncryption" / "build.sh"
TDE2E = ROOT / "core-xprojects" / "tde2e" / "tde2e" / "build.sh"

C_HARDENING = ("-ftrivial-auto-var-init=zero", "-fstack-protector-strong")
LIBCXX_HARDENING = "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"


class OpenSslBuildTests(unittest.TestCase):
    def setUp(self):
        self.script = OPENSSL.read_text()

    def test_the_app_settings_still_use_the_flags_the_script_mirrors(self):
        xcconfig = XCCONFIG.read_text()
        for flag in C_HARDENING:
            self.assertRegex(xcconfig, rf"(?m)^OTHER_CFLAGS = .*{re.escape(flag)}")

    def test_configure_gets_the_c_hardening(self):
        configure = re.search(r"(?ms)^\s*\./Configure (.*?)--prefix=", self.script)
        self.assertIsNotNone(configure)
        arguments = configure.group(1).split()
        for flag in C_HARDENING:
            self.assertIn(flag, arguments)

    def test_a_moved_tag_stops_the_build(self):
        self.assertRegex(self.script, r'(?m)^OPENSSL_COMMIT="45e844fa2a14ec92d146bd8f5778ac130b6625fb"$')
        clone = self.script.index("git clone -b openssl-3.5.9 --depth 1")
        check = self.script.index('rev-parse HEAD)" != "$OPENSSL_COMMIT"')
        build = self.script.index("build_for darwin64")
        self.assertLess(clone, check)
        self.assertLess(check, build)
        self.assertRegex(self.script[check:build], r"exit 1")


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
        generators = self.script.index("cmake -DTD_GENERATE_SOURCE_FILES=ON")
        flags = self.script.index("HARDENING_FLAGS=")
        target = self.script.index("cmake --build . --target tde2e")
        self.assertLess(generators, flags)
        self.assertLess(flags, target)


if __name__ == "__main__":
    unittest.main()
