import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lint'))

import changelog_reminder as cr  # noqa: E402


class ChangelogReminderTests(unittest.TestCase):
    def test_code_without_record_is_reported(self):
        message = cr.reminder(['submodules/Postbox/Sources/Foo.swift', 'docs/x.md'])
        self.assertIn('1 product file', message)
        self.assertIn('Foo.swift', message)

    def test_record_anywhere_in_range_satisfies(self):
        self.assertIsNone(cr.reminder(['a/b.swift', 'CHANGELOG.md']))
        self.assertIsNone(cr.reminder(['a/b.swift', 'NANOGRAM-CHANGES.md']))

    def test_docs_tests_and_vendored_trees_are_not_product_code(self):
        paths = ['docs/a.md', 'Tests/Foo/BarTests.swift', 'submodules/X/Tests/XTests.swift',
                 'third-party/libfoo/foo.c', 'tools/dev/tests/test_x.py', 'README.md']
        self.assertIsNone(cr.reminder(paths))

    def test_build_files_count_as_code(self):
        self.assertTrue(cr.is_product_code('submodules/X/BUILD'))
        self.assertTrue(cr.is_product_code('packages/X/Package.swift'))
        self.assertTrue(cr.is_product_code('tools/dev/tg') is False)

    def test_empty_push(self):
        self.assertIsNone(cr.reminder([]))


if __name__ == '__main__':
    unittest.main()
