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


if __name__ == '__main__':
    unittest.main()
