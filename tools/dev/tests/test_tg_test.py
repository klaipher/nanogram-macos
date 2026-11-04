import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))


class TgTestPackageListTests(unittest.TestCase):
    """`tg test` (and so the test step of `tg check`) must fail when it cannot list the packages to test."""

    def run_tg_test(self, fake_tglint_body):
        scratch = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, scratch)
        os.makedirs(os.path.join(scratch, 'tools', 'dev', 'lint'))
        shutil.copy(os.path.join(ROOT, 'tools', 'dev', 'tg'), os.path.join(scratch, 'tools', 'dev', 'tg'))
        with open(os.path.join(scratch, 'tools', 'dev', 'lint', 'tglint.py'), 'w') as handle:
            handle.write(textwrap.dedent(fake_tglint_body))
        return subprocess.run(
            [os.path.join(scratch, 'tools', 'dev', 'tg'), 'test'],
            cwd=scratch, capture_output=True, text=True, timeout=60)

    def test_fails_when_the_package_list_command_fails(self):
        result = self.run_tg_test("""
            import sys
            sys.stderr.write('fatal: not a git repository\\n')
            sys.exit(128)
        """)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('cannot list the packages to test', result.stderr)

    def test_fails_when_the_package_list_is_empty(self):
        result = self.run_tg_test("""
            import sys
            sys.exit(0)
        """)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('no packages to test', result.stderr)


class TgTestRoutingTests(unittest.TestCase):
    """`tg test` routes each package to the right runner and stays loud about real failures."""

    def make_package(self, name, test_target=True, runner_exit=None):
        directory = os.path.join(self.scratch, 'packages', name)
        os.makedirs(os.path.join(directory, 'Tests'))
        with open(os.path.join(directory, 'Package.swift'), 'w') as handle:
            handle.write('let package = Package(targets: [%s])\n' % ('.testTarget(name: "T")' if test_target else ''))
        if runner_exit is not None:
            runner = os.path.join(directory, 'Tests', 'run-tests.sh')
            with open(runner, 'w') as handle:
                handle.write('#!/bin/bash\necho "runner %s" >> "$FAKE_LOG"\nexit %d\n' % (name, runner_exit))
            os.chmod(runner, 0o755)

    def run_with(self, packages):
        scratch = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, scratch)
        self.scratch = scratch
        for name, kwargs in packages:
            self.make_package(name, **kwargs)
        os.makedirs(os.path.join(scratch, 'tools', 'dev', 'lint'))
        shutil.copy(os.path.join(ROOT, 'tools', 'dev', 'tg'), os.path.join(scratch, 'tools', 'dev', 'tg'))
        with open(os.path.join(scratch, 'tools', 'dev', 'lint', 'tglint.py'), 'w') as handle:
            handle.write('print({!r})\n'.format('\n'.join(name for name, _ in packages)))
        bin_dir = os.path.join(scratch, 'bin')
        os.makedirs(bin_dir)
        swift = os.path.join(bin_dir, 'swift')
        with open(swift, 'w') as handle:
            handle.write('#!/bin/bash\necho "swift $*" >> "$FAKE_LOG"\ncase "$*" in *Failing*) exit 1;; esac\n')
        os.chmod(swift, 0o755)
        self.log = os.path.join(scratch, 'calls.log')
        open(self.log, 'w').close()
        result = subprocess.run(
            [os.path.join(scratch, 'tools', 'dev', 'tg'), 'test'],
            cwd=scratch, capture_output=True, text=True, timeout=60,
            env=dict(os.environ, PATH=bin_dir + os.pathsep + os.environ['PATH'], FAKE_LOG=self.log,
                     NANOGRAM_CACHE_DIR=os.path.join(scratch, 'cache')))
        with open(self.log) as handle:
            return result, handle.read()

    def test_package_with_a_runner_uses_it_instead_of_swift_test(self):
        result, calls = self.run_with([('Plain', {}), ('Native', {'runner_exit': 0})])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('runner Native', calls)
        self.assertEqual(calls.count('swift test'), 1, calls)
        self.assertNotIn('Native/', calls.replace('runner Native', ''))

    def test_package_without_a_test_target_is_skipped_with_a_note(self):
        result, calls = self.run_with([('NoTests', {'test_target': False})])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('no tests', result.stdout)
        self.assertEqual(calls, '')

    def test_failing_runner_fails_the_run(self):
        result, calls = self.run_with([('Native', {'runner_exit': 1}), ('Plain', {})])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('tests failed: Native', result.stderr)
        self.assertIn('swift test', calls)

    def test_failing_swift_test_fails_the_run(self):
        result, _ = self.run_with([('Failing', {})])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('tests failed: Failing', result.stderr)


if __name__ == '__main__':
    unittest.main()
