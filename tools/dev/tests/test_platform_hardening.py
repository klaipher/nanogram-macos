import plistlib
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "dev"))

from nanogram import enhanced_security, release  # noqa: E402

XCCONFIG = ROOT / "nanogram" / "Nanogram.xcconfig"
EDITIONS = ROOT / "nanogram" / "editions"
ENTITLEMENTS = ROOT / "nanogram" / "entitlements"
HARDENED = "com.apple.security.hardened-process"
BASES = ("Nanogram-Direct", "Nanogram-MAS", "Nanogram-MAS-Development")


def settings(path):
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        match = re.match(r"^([A-Za-z0-9_]+(?:\[[^\]]*\])*)\s*=\s*(.*)$", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def entitlements(name):
    return plistlib.loads((ENTITLEMENTS / f"{name}.entitlements").read_bytes())


class CompilerHardeningTests(unittest.TestCase):
    def setUp(self):
        self.settings = settings(XCCONFIG)

    def test_zero_initialised_automatic_variables(self):
        self.assertIn("-ftrivial-auto-var-init=zero", self.settings["OTHER_CFLAGS"])
        self.assertIn("-ftrivial-auto-var-init=zero", self.settings["OTHER_CPLUSPLUSFLAGS"])

    def test_strong_stack_protector(self):
        self.assertIn("-fstack-protector-strong", self.settings["OTHER_CFLAGS"])
        self.assertIn("-fstack-protector-strong", self.settings["OTHER_CPLUSPLUSFLAGS"])

    def test_libcxx_fast_hardening(self):
        self.assertIn("_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST",
                      self.settings["GCC_PREPROCESSOR_DEFINITIONS[config=Release]"])
        self.assertNotIn("GCC_PREPROCESSOR_DEFINITIONS", self.settings)

    def test_settings_keep_what_targets_already_define(self):
        for key in ("OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "GCC_PREPROCESSOR_DEFINITIONS[config=Release]"):
            self.assertTrue(self.settings[key].startswith("$(inherited)"), key)

    def test_ffmpeg_is_built_with_the_strong_stack_protector(self):
        script = (ROOT / "core-xprojects" / "ffmpeg" / "ffmpeg" / "build.sh").read_text()
        self.assertRegex(script, r'EXTRA_CFLAGS="[^"]*-fstack-protector-strong')


class EnhancedSecurityTests(unittest.TestCase):
    def test_variants_are_the_base_plus_the_soft_mode_keys(self):
        for base in BASES:
            expected = dict(entitlements(base))
            expected.update(enhanced_security.SOFT_MODE_KEYS)
            self.assertEqual(entitlements(f"{base}-EnhancedSecurity"), expected, base)

    def test_soft_mode_keys(self):
        keys = enhanced_security.SOFT_MODE_KEYS
        self.assertIs(keys[HARDENED], True)
        self.assertEqual(keys[HARDENED + ".enhanced-security-version-string"], "1")
        self.assertIs(keys[HARDENED + ".checked-allocations"], True)
        self.assertIs(keys[HARDENED + ".checked-allocations.soft-mode"], True)
        self.assertNotIn(HARDENED + ".dyld-ro", keys)
        self.assertNotIn(HARDENED + ".platform-restrictions-string", keys)

    def test_the_default_entitlements_carry_none_of_it(self):
        for base in BASES + ("NanogramShare",):
            self.assertFalse([key for key in entitlements(base) if key.startswith(HARDENED)], base)

    def test_off_by_default_and_editions_follow_the_switch(self):
        base = settings(XCCONFIG)
        self.assertEqual(base["NANOGRAM_ENHANCED_SECURITY"], "$(NANOGRAM_ENHANCED_SECURITY_REQUEST:default=NO)")
        self.assertEqual(base["NANOGRAM_ENTITLEMENTS_SUFFIX_YES"], "-EnhancedSecurity")
        self.assertEqual(base["NANOGRAM_ENTITLEMENTS_SUFFIX_NO"], "")
        self.assertEqual(base["NANOGRAM_ENTITLEMENTS_SUFFIX"], "$(NANOGRAM_ENTITLEMENTS_SUFFIX_$(NANOGRAM_ENHANCED_SECURITY))")
        direct = settings(EDITIONS / "direct.xcconfig")
        self.assertEqual(direct["NANOGRAM_ENTITLEMENTS_Telegram"],
                         "nanogram/entitlements/Nanogram-Direct$(NANOGRAM_ENTITLEMENTS_SUFFIX).entitlements")
        mas = settings(EDITIONS / "mas.xcconfig")
        self.assertEqual(mas["NANOGRAM_MAS_ENTITLEMENTS"],
                         "nanogram/entitlements/Nanogram-MAS-Development$(NANOGRAM_ENTITLEMENTS_SUFFIX).entitlements")
        self.assertEqual(direct["NANOGRAM_ENTITLEMENTS_TelegramShare"], "nanogram/entitlements/NanogramShare.entitlements")

    def test_generator_output_matches_the_committed_files(self):
        for base in BASES:
            generated = enhanced_security.hardened_entitlements(ENTITLEMENTS / f"{base}.entitlements")
            self.assertEqual(generated, (ENTITLEMENTS / f"{base}-EnhancedSecurity.entitlements").read_bytes(), base)

    def test_release_uses_the_variant_only_when_asked(self):
        plain = release.distribution_entitlements("mas", enhanced_security=False)
        hardened = release.distribution_entitlements("mas", enhanced_security=True)
        self.assertEqual(plain, ENTITLEMENTS / "Nanogram-MAS.entitlements")
        self.assertEqual(hardened, ENTITLEMENTS / "Nanogram-MAS-EnhancedSecurity.entitlements")
        self.assertIsNone(release.distribution_entitlements("direct", enhanced_security=True))

    def test_release_settings_carry_the_request(self):
        self.assertNotIn("NANOGRAM_ENHANCED_SECURITY_REQUEST=YES", release.release_settings(environ={}))
        for value in ("1", "YES", "yes", "true"):
            self.assertIn("NANOGRAM_ENHANCED_SECURITY_REQUEST=YES",
                          release.release_settings(environ={"NANOGRAM_ENHANCED_SECURITY": value}), value)
        self.assertNotIn("NANOGRAM_ENHANCED_SECURITY_REQUEST=YES",
                         release.release_settings(environ={"NANOGRAM_ENHANCED_SECURITY": "0"}))


if __name__ == "__main__":
    unittest.main()
