"""The code-block highlighter is one copy, the klaipher/libprisma fork the iOS core pins at third-party/libprisma/libprisma.

The Mac `CodeSyntax` framework compiles the fork's C++ core and its one `apple/Syntaxer.{h,mm}` and the app bundles its
grammars.dat, so the depth cap, the regex-search budget and the language list are the ones the iOS host test pins.
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
CORE_PRISMA = ROOT / "submodules" / "telegram-ios" / "third-party" / "libprisma"
PRISMA_FORK = CORE_PRISMA / "libprisma"
CORE_REGEX = ROOT / "submodules" / "telegram-ios" / "third-party" / "boost_regex" / "regex" / "include"
CODE_SYNTAX = ROOT / "submodules" / "CodeSyntax" / "CodeSyntax" / "CodeSyntax.xcodeproj" / "project.pbxproj"


def read(path: Path) -> str:
    return Path(path).read_text(errors="replace")


class SharedHighlighterTests(unittest.TestCase):
    def test_no_second_copy_is_a_submodule(self):
        modules = read(ROOT / ".gitmodules")
        self.assertNotIn("submodules/libprisma", modules)
        self.assertNotIn("submodules/regex", modules)
        self.assertFalse((ROOT / "submodules" / "libprisma" / "libprisma").exists())

    def test_code_syntax_compiles_the_core_copy(self):
        project = read(CODE_SYNTAX)
        self.assertIn("../../../telegram-ios/third-party/libprisma/libprisma", project)
        self.assertIn("$PROJECT_DIR/../../telegram-ios/third-party/boost_regex/regex/include/", project)
        self.assertIn("$PROJECT_DIR/../../telegram-ios/third-party/libprisma/libprisma/libprisma", project)
        self.assertIn("BOOST_REGEX_MAX_BLOCKS=1536", project)
        self.assertNotIn("../../../libprisma", project)
        self.assertNotIn("../../regex/include", project)
        self.assertNotIn("boost_regex/include/", project)

    def test_the_mac_keeps_no_syntaxer_copy(self):
        for name in ("Syntaxer.h", "Syntaxer.mm"):
            self.assertFalse((CODE_SYNTAX.parents[1] / "CodeSyntax" / name).exists(), name)

    def test_app_bundles_the_core_grammars(self):
        project = read(ROOT / "Telegram.xcodeproj" / "project.pbxproj")
        self.assertIn("submodules/telegram-ios/third-party/libprisma/libprisma/libprisma/grammars.dat", project)
        self.assertNotIn("submodules/libprisma/libprisma/grammars.dat", project)

    def test_core_highlighter_holds_its_bounds_on_this_platform(self):
        compiler = shutil.which("clang++")
        if compiler is None:
            self.skipTest("clang++ not installed")
        sources = PRISMA_FORK / "libprisma"
        test = CORE_PRISMA / "Tests" / "SyntaxHighlighterRecursionTests.cpp"
        self.assertTrue(test.exists(), "bump submodules/telegram-ios to a core with the shared libprisma")
        with tempfile.TemporaryDirectory() as work:
            binary = Path(work) / "highlighter-tests"
            build = subprocess.run(
                [compiler, "-std=c++17", "-O2", "-pthread", "-DBOOST_REGEX_MAX_BLOCKS=1536", f"-I{CORE_REGEX}", f"-I{sources}", str(test)]
                + [str(sources / name) for name in ("SyntaxHighlighter.cpp", "LanguageTree.cpp", "TokenList.cpp", "Highlight.cpp")]
                + ["-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr[-2000:])
            run = subprocess.run([str(binary), str(sources / "grammars.dat")],
                                 capture_output=True, text=True, timeout=300)
            self.assertEqual(run.returncode, 0, run.stderr[-2000:])
            self.assertIn("ALL PASS", run.stderr)


if __name__ == "__main__":
    unittest.main()
