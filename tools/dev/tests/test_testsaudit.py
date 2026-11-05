"""tools/tests runner audit (weakest-parts lane, 2026-11-05): anchors are found without compiling anything."""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, testsaudit  # noqa: E402

RUNNER = '''
import argparse
from pathlib import Path
root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=root / 'packages/TelegramMedia/Sources/AudioRecorder.swift')
def block(source, marker):
    a = source.index(marker); b = source.index('{', a) + 1
    return source[a:b]
source = Path('/tmp/Baseline-before.swift').read_text()
data = (root / 'packages' / 'TelegramMedia' / 'Sources' / 'DataItem.swift').read_text()
functions = '\\n'.join(block(source, marker) for marker in ['public func temporaryMediaPath', 'public func trimOpusFile'])
methods = [block(source, 'func applyTrim(')]
markers = ['private func replaceStore(']
x = source.index('public enum OtherThing')
if 'optional marker' in source:
    pass
y = source.replace('public ', '')
fixture = Path(__file__).with_name('Tests.swift').read_text()
out = root / 'build-output' / 'Result.txt'
'''


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ExtractTests(unittest.TestCase):
    def test_paths_from_literals_and_chains(self):
        paths, _ = testsaudit.extract(RUNNER)
        self.assertEqual(paths, ["packages/TelegramMedia/Sources/AudioRecorder.swift",
                                 "packages/TelegramMedia/Sources/DataItem.swift"])

    def test_anchors_from_search_methods_helpers_loops_and_marker_lists(self):
        _, anchors = testsaudit.extract(RUNNER)
        for expected in ("public func temporaryMediaPath", "public func trimOpusFile", "func applyTrim(",
                         "private func replaceStore(", "public enum OtherThing", "optional marker"):
            self.assertIn(expected, anchors)
        self.assertEqual(len(anchors), len(set(anchors)))

    def test_membership_and_loop_variable_anchors(self):
        text = "for name in ['func alpha(', 'func beta(']:\n    a = source.index(name)\nif 'class Gamma' in source:\n    pass\n"
        self.assertEqual(testsaudit.extract(text)[1], ["func alpha(", "func beta(", "class Gamma"])

    def test_replace_arguments_and_short_strings_are_not_anchors(self):
        _, anchors = testsaudit.extract(RUNNER)
        self.assertNotIn("public ", anchors)
        self.assertNotIn("{", anchors)

    def test_variables_assigned_a_chain_resolve(self):
        text = "base = root / 'packages' / 'X'\nsource = (base / 'Sources' / 'File.swift').read_text()\n"
        self.assertEqual(testsaudit.extract(text)[0], ["packages/X/Sources/File.swift"])

    def test_unknown_heads_and_output_paths_are_ignored(self):
        text = "a = directory / 'Tests/Generated.swift'\nb = Path('Tests/Other.swift')\nc = root / 'tmp.build'\n"
        self.assertEqual(testsaudit.extract(text)[0], [])

    def test_submodule_relative_literal_is_kept_for_core_lookup(self):
        text = "source_path = 'submodules/TelegramCore/Sources/Account/Account.swift'"
        self.assertEqual(testsaudit.extract(text)[0], ["submodules/TelegramCore/Sources/Account/Account.swift"])

    def test_broken_runner_gives_nothing(self):
        self.assertEqual(testsaudit.extract("def (:"), ([], []))

    def test_invalid_escape_sequences_do_not_warn_or_fail(self):
        self.assertEqual(testsaudit.extract("x = '\\(' \n")[1], [])


def git(repo, *args, date="2026-10-23T12:00:00"):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@example.com", GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=env)


class AuditTests(unittest.TestCase):
    def make_repo(self, tmp):
        root = Path(tmp)
        git(root, "init", "-q", "-b", "main")
        git(root, "config", "commit.gpgsign", "false")
        write(root / "packages/TelegramMedia/Sources/AudioRecorder.swift",
              "public func temporaryMediaPath() {\n}\npublic func trimOpusFile() {\n}\nfunc applyTrim() {\n}\n")
        write(root / "packages/TelegramMedia/Sources/DataItem.swift", "class DataItem {\n}\n")
        write(root / "tools/tests/audio-trim-store/run.py", RUNNER)
        write(root / "tools/tests/no-runner/Tests.swift", "x")
        git(root, "add", ".")
        git(root, "commit", "-q", "-m", "first")
        return root

    def runner(self, root, name="audio-trim-store"):
        return next(r for r in testsaudit.audit(root) if r.name == name)

    def test_missing_anchors_are_listed_and_found_ones_are_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.runner(self.make_repo(tmp))
        self.assertEqual(result.unresolved, [])
        self.assertIn("private func replaceStore(", result.missing_anchors)
        self.assertIn("public enum OtherThing", result.missing_anchors)
        self.assertNotIn("public func trimOpusFile", result.missing_anchors)
        self.assertNotIn("func applyTrim(", result.missing_anchors)
        self.assertTrue(result.problem)

    def test_a_source_that_is_gone_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_repo(tmp)
            (root / "packages/TelegramMedia/Sources/DataItem.swift").unlink()
            result = self.runner(root)
        self.assertEqual(result.unresolved, ["packages/TelegramMedia/Sources/DataItem.swift"])

    def test_folder_without_run_py_is_listed(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.runner(self.make_repo(tmp), "no-runner")
        self.assertIsNone(result.runner)
        self.assertFalse(result.problem)

    def test_runner_is_stale_when_a_source_changed_after_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_repo(tmp)
            self.assertFalse(self.runner(root).stale)
            write(root / "packages/TelegramMedia/Sources/DataItem.swift", "class DataItem {\n  var x = 1\n}\n")
            git(root, "add", ".")
            git(root, "commit", "-q", "-m", "later", date="2026-11-04T12:00:00")
            result = self.runner(root)
        self.assertTrue(result.stale)
        self.assertEqual((result.last_touched, result.newest_source), ("2026-10-23", "2026-11-04"))

    def test_core_file_is_read_from_the_core_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_repo(tmp)
            write(root / "tools/tests/core-case/run.py", "p = 'submodules/TelegramCore/Sources/A.swift'\nx = s.index('func _internal_a(')\n")
            core = Path(tmp) / "core-checkout"
            write(core / "submodules/TelegramCore/Sources/A.swift", "func _internal_b() {\n}\n")
            found = next(r for r in testsaudit.audit(root, core=core) if r.name == "core-case")
        self.assertEqual(found.unresolved, [])
        self.assertEqual(found.missing_anchors, ["func _internal_a("])

    def test_render_summary_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_repo(tmp)
            lines = testsaudit.render(testsaudit.audit(root), problems_only=True)
            self.assertTrue(any("anchor not found in any source: 'private func replaceStore('" in l for l in lines))
            self.assertIn("2 folder(s), 1 without run.py, 1 with a missing source or anchor", lines[-1])
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(testsaudit.main(["--root", str(root)]), 0)
                self.assertEqual(testsaudit.main(["--root", str(root), "--strict"]), 1)
                self.assertEqual(testsaudit.main(["--root", str(root), "--only", "no-runner", "--strict"]), 0)
            self.assertIn("audio-trim-store", out.getvalue())

    def test_json_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_repo(tmp)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                testsaudit.main(["--root", str(root), "--json", "--only", "audio-trim-store"])
        data = json.loads(out.getvalue())
        self.assertEqual(data[0]["name"], "audio-trim-store")
        self.assertIn("private func replaceStore(", data[0]["missing_anchors"])


class RepositoryTests(unittest.TestCase):
    def test_runner_folders_are_listed_and_a_sample_is_analysable(self):
        base = config.ROOT / "tools/tests"
        folders = sorted(p.name for p in base.iterdir() if p.is_dir())
        with_runner = [name for name in folders if (base / name / "run.py").is_file()]
        self.assertGreater(len(with_runner), 100)
        sample = [testsaudit.audit_runner(base / name, testsaudit.Sources(config.ROOT)) for name in with_runner[:3]]
        self.assertTrue(all(r.runner for r in sample))
        self.assertTrue(any(r.candidates or r.anchors for r in sample))


if __name__ == "__main__":
    unittest.main()
