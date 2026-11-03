import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import buildcheck  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
CLANG = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"


def compile_line(target, extra=""):
    return (f"CompileC /DD/x.o /src/x.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler "
            f"(in target 'X' from project 'P')\n    cd /src\n    {CLANG} -x c -target {target} {extra} -c /src/x.c -o /DD/x.o\n")


def link_line(extra=""):
    return (f"Ld /DD/X normal arm64 (in target 'X' from project 'P')\n    cd /src\n"
            f"    {CLANG} -target arm64-apple-macos15.0 {extra} -o /DD/X\n")


class LogTests(unittest.TestCase):
    def test_universal_log_rejected(self):
        problems = buildcheck.check_log((FIXTURES / "build-universal.log").read_text())
        self.assertTrue(any("x86_64" in p for p in problems), problems)
        self.assertTrue(any("'fileop'" in p for p in problems), problems)

    def test_arm64_15_log_accepted(self):
        self.assertEqual(buildcheck.check_log((FIXTURES / "build-debug-arm64.log").read_text()), [])

    def test_old_min_version_rejected(self):
        problems = buildcheck.check_log(compile_line("arm64-apple-macos12.0"))
        self.assertEqual(len(problems), 1)
        self.assertIn("macos12.0", problems[0])

    def test_compile_line_without_target_rejected(self):
        log = "CompileC /DD/x.o (in target 'X' from project 'P')\n    cd /src\n    " + CLANG + " -x c -c /src/x.c\n"
        self.assertTrue(buildcheck.check_log(log))

    def test_empty_log_rejected(self):
        self.assertTrue(buildcheck.check_log("** BUILD SUCCEEDED **\n"))

    def test_no_op_build_log_accepted(self):
        log = ("Command line invocation:\n    xcodebuild build -workspace W.xcworkspace\n\n"
               "Build settings from command line:\n    ARCHS = arm64\n\nCreateBuildDescription\n\n"
               "** BUILD SUCCEEDED **\n")
        self.assertEqual(buildcheck.check_log(log), [])

    def test_failed_no_op_log_rejected(self):
        log = "Command line invocation:\n    xcodebuild build\n\nBuild settings from command line:\n\n** BUILD FAILED **\n"
        self.assertTrue(buildcheck.check_log(log))

    def test_release_requires_O3_from_response_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            resp = Path(tmp) / "common-args.resp"
            resp.write_text("-fmessage-length=0 -Os -fobjc-arc\n")
            log = compile_line("arm64-apple-macos15.0", f"@{resp}") + link_line("-flto=thin")
            problems = buildcheck.check_log(log, release=True)
            self.assertTrue(any("-Os" in p for p in problems), problems)
            resp.write_text("-fmessage-length=0 -O3 -flto=thin -fobjc-arc\n")
            self.assertEqual(buildcheck.check_log(log, release=True), [])

    def test_release_requires_thin_lto_compiles(self):
        # Xcode 27 passes no -flto=thin at the link (seen in the first real release archive): ThinLTO shows as
        # bitcode compiles, which the linker optimizes; relocatable package merges (ld -r) carry no LTO flag.
        log = compile_line("arm64-apple-macos15.0", "-O3") + link_line()
        problems = buildcheck.check_log(log, release=True)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("-flto=thin", problems[0])
        self.assertIn("C compile", problems[0])
        good = compile_line("arm64-apple-macos15.0", "-O3 -flto=thin") + link_line() + link_line("-r")
        self.assertEqual(buildcheck.check_log(good, release=True), [])

    def test_debug_does_not_require_release_flags(self):
        self.assertEqual(buildcheck.check_log(compile_line("arm64-apple-macos15.0", "-O0") + link_line()), [])

    def test_release_swift_without_unchecked_exclusivity_rejected(self):
        # M17: Release passes SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off on the command line so it reaches the packages,
        # not only the app target (whose pbxproj already has it off). The log escapes '=' as '\='.
        def swift(target, extra):
            return (f"SwiftDriver {target} normal arm64 com.apple.xcode.tools.swift.compiler "
                    f"(in target '{target}' from project 'P')\n    cd /src\n    builtin-SwiftDriver -- "
                    f"/usr/bin/swiftc -module-name {target} -O {extra} -target arm64-apple-macos15.0\n")
        base = compile_line("arm64-apple-macos15.0", "-O3 -flto=thin") + link_line("-flto=thin")
        log = base + swift("Telegram", "-enforce-exclusivity\\=unchecked") + swift("Postbox", "")
        problems = buildcheck.check_log(log, release=True)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("exclusivity", problems[0])
        self.assertIn("'Postbox'", problems[0])
        self.assertNotIn("'Telegram'", problems[0])
        fixed = base + swift("Telegram", "-enforce-exclusivity\\=unchecked") + \
            swift("Postbox", "-enforce-exclusivity\\=unchecked")
        self.assertEqual(buildcheck.check_log(fixed, release=True), [])
        self.assertEqual(buildcheck.check_log(base + swift("Postbox", "").replace(" -O ", " -Onone "),
                                              release=False), [])


def build_binary(directory, archs, minos):
    source = Path(directory) / "main.c"
    source.write_text("int main(void) { return 0; }\n")
    out = Path(directory) / "main"
    args = ["xcrun", "clang", f"-mmacosx-version-min={minos}", str(source), "-o", str(out)]
    for arch in archs:
        args[2:2] = ["-arch", arch]
    subprocess.run(args, check=True)
    return out


def fake_app(directory, binary):
    app = Path(directory) / "Fake.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources").mkdir()
    (app / "Contents" / "Resources" / "data.txt").write_text("not a binary")
    (app / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        "<key>CFBundleExecutable</key><string>Fake</string></dict></plist>\n")
    target = app / "Contents" / "MacOS" / "Fake"
    target.write_bytes(binary.read_bytes())
    target.chmod(0o755)
    return app


class BinaryTests(unittest.TestCase):
    def test_arm64_15_binary_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(tmp, build_binary(tmp, ["arm64"], "15.0"))
            self.assertEqual(buildcheck.check_binary(app), [])

    def test_fat_binary_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(tmp, build_binary(tmp, ["arm64", "x86_64"], "15.0"))
            problems = buildcheck.check_binary(app)
            self.assertTrue(any("x86_64" in p for p in problems), problems)

    def test_old_minos_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(tmp, build_binary(tmp, ["arm64"], "12.0"))
            problems = buildcheck.check_binary(app)
            self.assertTrue(any("12.0" in p for p in problems), problems)


    def test_uncompiled_metal_shader_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(tmp, build_binary(tmp, ["arm64"], "15.0"))
            resources = app / "Contents" / "Resources" / "MetalEngine_MetalEngine.bundle" / "Contents" / "Resources"
            resources.mkdir(parents=True)
            (resources / "MetalEngineShaders.metal").write_text("kernel void k() {}")
            problems = buildcheck.check_binary(app)
            self.assertTrue(any("MetalEngineShaders.metal" in p and "metallib" in p for p in problems), problems)

class FindAppTests(unittest.TestCase):
    def test_find_app_picks_the_app_with_an_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            products = Path(tmp)
            (products / "Helper.app" / "Contents").mkdir(parents=True)
            (products / "Nanogram.app" / "Contents" / "PlugIns" / "Share.appex").mkdir(parents=True)
            self.assertEqual(buildcheck.find_app(products), products / "Nanogram.app")

    def test_find_app_missing_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError):
                buildcheck.find_app(Path(tmp))


if __name__ == "__main__":
    unittest.main()
