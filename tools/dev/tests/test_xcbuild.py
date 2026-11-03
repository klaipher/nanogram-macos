"""The one xcodebuild invocation tg build uses: fixed arguments and a fixed environment, so Xcode keeps reusing
its cached build description (recreating it costs 20–30 s and ~40 CPU s per build)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, xcbuild  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
DERIVED = Path("/DD")
XCCONFIG = Path("/repo/nanogram/editions/direct.xcconfig")
CONDITIONS = "$(inherited) NANOGRAM STABLE"


def args(configuration="Debug", scheme="Telegram", clean=False, extra=(), **kwargs):
    return xcbuild.xcodebuild_args(configuration=configuration, scheme=scheme, derived=DERIVED, xcconfig=XCCONFIG,
                                   conditions=CONDITIONS, clean=clean, extra=list(extra), **kwargs)


def stage1_args(configuration, scheme):
    """Exactly what stage 1's cmd_build passed to xcodebuild."""
    return ["build", "-workspace", "Telegram-Mac.xcworkspace", "-scheme", scheme, "-configuration", configuration,
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(DERIVED),
            "-xcconfig", str(XCCONFIG), f"SWIFT_ACTIVE_COMPILATION_CONDITIONS={CONDITIONS}",
            "COMPILER_INDEX_STORE_ENABLE=NO", "-showBuildTimingSummary"]


def is_subsequence(needle, haystack):
    position = 0
    for item in haystack:
        if position < len(needle) and item == needle[position]:
            position += 1
    return position == len(needle)


class EnvironmentTests(unittest.TestCase):
    BASE = {"HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "TMPDIR": "/var/folders/x/T/",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "LANG": "en_US.UTF-8"}

    def test_env_drops_session_variables(self):
        env = xcbuild.build_env({**self.BASE, "AI_AGENT": "claude", "PYTHONPATH": "/repo/tools/dev",
                                 "OLDPWD": "/tmp", "SHLVL": "3", "PWD": "/repo", "TERM": "xterm"})
        for name in ("AI_AGENT", "PYTHONPATH", "OLDPWD", "SHLVL", "PWD", "TERM"):
            self.assertNotIn(name, env)
        self.assertEqual(env["PATH"], xcbuild.FIXED_PATH)
        self.assertEqual(set(env), set(xcbuild.ENV_ALLOWLIST) | {"PATH"})

    def test_env_is_stable_across_shells(self):
        one = xcbuild.build_env({**self.BASE, "PATH": "/usr/bin:/bin", "PWD": "/a", "FOO": "1"})
        two = xcbuild.build_env({**self.BASE, "PATH": "/opt/homebrew/bin:/x/bin:/usr/bin", "PWD": "/b",
                                 "AI_AGENT": "other", "CLAUDECODE": "1"})
        self.assertEqual(one, two)

    def test_lang_defaults(self):
        base = {k: v for k, v in self.BASE.items() if k != "LANG"}
        self.assertEqual(xcbuild.build_env(base)["LANG"], "en_US.UTF-8")

    def test_fixed_path_starts_with_pinned_rustup(self):
        self.assertTrue(xcbuild.FIXED_PATH.startswith(f"{config.RUSTUP_BIN}:"))


class ArgumentTests(unittest.TestCase):
    def test_args_include_package_flags(self):
        built = args()
        for flag in xcbuild.PACKAGE_FLAGS:
            self.assertIn(flag, built)

    def test_clean_build_resolves_packages(self):
        built = args(clean=True)
        self.assertNotIn("-disableAutomaticPackageResolution", built)
        self.assertIn("-skipPackagePluginValidation", built)
        self.assertIn("-skipMacroValidation", built)

    def test_resolve_packages_without_clean(self):
        built = args(resolve=True)
        self.assertNotIn("-disableAutomaticPackageResolution", built)

    def test_args_match_stage1_build(self):
        for configuration, scheme in (("Debug", "Telegram"), ("Release", "Release")):
            with self.subTest(configuration=configuration):
                built = args(configuration=configuration, scheme=scheme)
                self.assertTrue(is_subsequence(stage1_args(configuration, scheme), built), built)

    def test_extra_args_come_last(self):
        built = args(extra=["COMPILATION_CACHE_ENABLE_CACHING=YES"])
        self.assertEqual(built[-1], "COMPILATION_CACHE_ENABLE_CACHING=YES")

    def test_same_request_gives_same_args(self):
        self.assertEqual(args(), args())


class DescriptionTests(unittest.TestCase):
    def test_description_reused_detection(self):
        self.assertTrue(xcbuild.description_reused((FIXTURES / "stage2-description-reused.log").read_text()))
        self.assertFalse(xcbuild.description_reused((FIXTURES / "stage2-description-recreated.log").read_text()))

    def test_description_status_only_when_planned(self):
        self.assertEqual(xcbuild.description_status((FIXTURES / "stage2-description-reused.log").read_text()), "reused")
        self.assertTrue(xcbuild.description_status(
            (FIXTURES / "stage2-description-recreated.log").read_text()).startswith("recreated"))
        failed_early = "xcodebuild: error: Could not resolve package dependencies:\n"
        self.assertIsNone(xcbuild.description_status(failed_early))

    def test_package_resolution_hint(self):
        log = "error: Package.resolved file is out of date; disableAutomaticPackageResolution is set\n"
        self.assertTrue(xcbuild.needs_resolve_hint(log))
        self.assertFalse(xcbuild.needs_resolve_hint("** BUILD SUCCEEDED **\n"))


if __name__ == "__main__":
    unittest.main()
