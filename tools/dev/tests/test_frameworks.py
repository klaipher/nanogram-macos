import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, frameworks  # noqa: E402


def populate(root):
    outputs = frameworks.required_outputs(root)
    for path in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x")
    return outputs


class VerifyOutputsTests(unittest.TestCase):
    def test_required_outputs_cover_every_library(self):
        with tempfile.TemporaryDirectory() as tmp:
            names = {p.name for p in frameworks.required_outputs(Path(tmp))}
        for name in ("libssl.a", "libopenh264.a", "libdav1d.a", "libtde2e.a", "libwallet_engine.a",
                     "libmtproto_engine_ffi.a", "libmac_framework_objc_static.a", "libtlottie.a"):
            self.assertIn(name, names)

    def test_xcframework_slices_are_arm64_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [str(p) for p in frameworks.required_outputs(Path(tmp))]
        self.assertTrue(any("/macos-arm64/" in p for p in paths))
        self.assertFalse(any("x86_64" in p for p in paths))

    def test_verify_outputs_rejects_fat_lib(self):
        with tempfile.TemporaryDirectory() as tmp:
            populate(Path(tmp))
            problems = frameworks.verify_outputs(Path(tmp), archs_of=lambda path: ["x86_64", "arm64"])
        self.assertTrue(problems)
        self.assertTrue(all("x86_64" in p for p in problems), problems)
        self.assertTrue(any("libssl.a" in p for p in problems))

    def test_verify_outputs_accepts_arm64(self):
        with tempfile.TemporaryDirectory() as tmp:
            populate(Path(tmp))
            self.assertEqual(frameworks.verify_outputs(Path(tmp), archs_of=lambda path: ["arm64"]), [])

    def test_verify_outputs_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = populate(Path(tmp))
            next(p for p in outputs if p.name == "libssl.a").unlink()
            problems = frameworks.verify_outputs(Path(tmp), archs_of=lambda path: ["arm64"])
        self.assertEqual(len(problems), 1)
        self.assertIn("libssl.a", problems[0])
        self.assertIn("missing", problems[0])


class BuildEnvironmentTests(unittest.TestCase):
    def test_build_env_comes_from_our_xcconfig(self):
        env = frameworks.build_environment(Path("/tmp/timing.tsv"), base={})
        self.assertEqual(env["XCODE_XCCONFIG_FILE"], str(config.ROOT / "nanogram" / "Nanogram.xcconfig"))
        self.assertEqual(env["MACOSX_DEPLOYMENT_TARGET"], "15.0")
        self.assertEqual(env["ARCHS"], "arm64")
        self.assertEqual(env["CMAKE_POLICY_VERSION_MINIMUM"], "3.5")
        self.assertEqual(env["BUILD_TIMING_LOG"], "/tmp/timing.tsv")

    def test_makes_run_in_parallel(self):
        env = frameworks.build_environment(Path("/tmp/timing.tsv"), base={})
        self.assertEqual(env["MAKEFLAGS"], f"-j{os.cpu_count()}")

    def test_callers_makeflags_win(self):
        env = frameworks.build_environment(Path("/tmp/timing.tsv"), base={"MAKEFLAGS": "-j2"})
        self.assertEqual(env["MAKEFLAGS"], "-j2")

    def test_conditional_settings_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            xcconfig = Path(tmp) / "a.xcconfig"
            xcconfig.write_text("// c\nARCHS = arm64\nLLVM_LTO[config=Release] = YES_THIN\n#include \"b.xcconfig\"\n")
            self.assertEqual(frameworks.xcconfig_settings(xcconfig), {"ARCHS": "arm64"})


class RustScriptTests(unittest.TestCase):
    SCRIPTS = ("core-xprojects/wallet-engine/wallet-engine/build.sh",
               "core-xprojects/mtproto-engine/mtproto-engine/build.sh",
               "core-xprojects/tlottie/build.sh")

    def test_every_cargo_call_unsets_deployment_target(self):
        for script in self.SCRIPTS:
            text = (config.ROOT / script).read_text()
            calls = [line for line in text.splitlines() if re.search(r'"\$CARGO_BIN" (build|run|rustc)', line)]
            self.assertTrue(calls, script)
            for line in calls:
                self.assertIn("env -u MACOSX_DEPLOYMENT_TARGET", line, f"{script}: {line.strip()}")
            self.assertNotIn("DEPLOYMENT_TARGET=", text, script)
            self.assertNotIn("x86_64", text, script)


class NativeBuildFlagTests(unittest.TestCase):
    def script(self, path):
        return (config.ROOT / path).read_text()

    def test_ffmpeg_builds_no_muxers_encoders_or_network(self):
        text = self.script("core-xprojects/ffmpeg/ffmpeg/build.sh")
        self.assertNotIn("--enable-muxer", text)
        self.assertNotIn("--enable-encoder", text)
        self.assertNotRegex(text, r"--enable-(demuxer|parser)=[^ ]*libopus")
        for flag in ("network", "securetransport", "bzlib", "iconv", "appkit", "avfoundation", "coreimage", "metal", "sdl2"):
            self.assertIn(f"--disable-{flag}", text)

    def test_openssl_configure_drops_unused_algorithms(self):
        text = self.script("core-xprojects/openssl/OpenSSLEncryption/build.sh")
        configure = text[text.index("./Configure"):text.index("--prefix=", text.index("./Configure"))]
        for option in ("no-quic", "no-engine", "no-legacy", "no-autoload-config", "no-sm4", "no-ml-dsa", "no-ssl3"):
            self.assertIn(option, configure)
        for kept in ("no-srtp", "no-dtls", "no-ec ", "no-chacha", "no-poly1305", "no-dh "):
            self.assertNotIn(kept, configure)

    def test_webrtc_stays_below_the_macos_15_screen_capture_obsoletions(self):
        text = self.script("core-xprojects/webrtc/webrtc/build.sh")
        self.assertIn("-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", text)

    def test_tlottie_aborts_on_panic(self):
        self.assertIn("--config 'profile.release.panic=\"abort\"'", self.script("core-xprojects/tlottie/build.sh"))

    def test_wallet_engine_builds_only_its_staticlib(self):
        text = self.script("core-xprojects/wallet-engine/wallet-engine/build.sh")
        self.assertRegex(text, r'"\$CARGO_BIN" rustc \\\n\s+--package wallet-engine \\\n\s+--lib \\\n\s+--crate-type staticlib')


if __name__ == "__main__":
    unittest.main()
