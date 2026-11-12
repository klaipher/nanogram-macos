"""Tests for tools/dev/lint/tglint.py, ported from Telegram-iOS 5ac4d079 (tools/dev/lint/tests/test_tglint.py).

macOS changes: lintable paths (submodules/ is vendored here), affected_packages instead of Bazel
affected_tests, pre-push runs `tg check`. The SwiftLint tests are skipped when the pinned SwiftLint
is not installed (python3 tools/dev/lint/tglint.py install).
"""

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools', 'dev', 'lint'))

import tglint  # noqa: E402

FIXTURES = os.path.join(HERE, 'fixtures')
HAVE_SWIFTLINT = os.path.exists(os.environ.get('TG_SWIFTLINT', tglint.swiftlint_path()))


def run(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def make_repo():
    path = tempfile.mkdtemp(prefix='tglint-test-')
    run(['git', 'init', '-q', '-b', 'main'], path)
    run(['git', 'config', 'user.email', 't@example.com'], path)
    run(['git', 'config', 'user.name', 't'], path)
    run(['git', 'config', 'commit.gpgsign', 'false'], path)
    run(['git', 'config', 'core.hooksPath', '.git/hooks'], path)
    return path


def write(root, rel, text):
    full = os.path.join(root, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w') as f:
        f.write(text)


def commit_all(root, message='c'):
    run(['git', 'add', '-A'], root)
    run(['git', 'commit', '-q', '-m', message], root)
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, check=True, capture_output=True, text=True).stdout.strip()


def fixture(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return f.read()


class RepoTestCase(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()
        self.addCleanup(shutil.rmtree, self.repo, True)
        patcher = mock.patch.object(tglint, 'ROOT', self.repo)
        patcher.start()
        self.addCleanup(patcher.stop)


class HookEnvironmentTests(unittest.TestCase):
    def check_new_repository_under_hook_environment(self, scrub):
        repo = make_repo()
        worktree = tempfile.mkdtemp(prefix='tglint-worktree-')
        scratch = tempfile.mkdtemp(prefix='tglint-scratch-')
        for path in (repo, worktree, scratch):
            self.addCleanup(shutil.rmtree, path, True)
        os.rmdir(worktree)
        run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'base'], repo)
        run(['git', 'worktree', 'add', '-q', '--detach', worktree], repo)
        environment = dict(os.environ, GIT_DIR=os.path.join(repo, '.git', 'worktrees', os.path.basename(worktree)))
        if scrub:
            tglint.scrub_git_hook_environment(environment)
        subprocess.run(['git', 'init', '-q', os.path.join(scratch, 'new')], cwd=scratch, env=environment, capture_output=True)
        return subprocess.run(['git', 'config', '--get', 'core.bare'], cwd=repo, capture_output=True, text=True).stdout.strip()

    def test_a_push_from_a_worktree_reinitialises_the_repository_without_the_scrub(self):
        self.assertEqual(self.check_new_repository_under_hook_environment(scrub=False), 'true')

    def test_a_test_repository_made_under_the_hook_leaves_the_pushing_repository_alone(self):
        self.assertEqual(self.check_new_repository_under_hook_environment(scrub=True), 'false')


class DiffParsingTests(unittest.TestCase):
    def test_added_and_changed_lines(self):
        diff = '\n'.join([
            'diff --git a/A.swift b/A.swift',
            '--- a/A.swift',
            '+++ b/A.swift',
            '@@ -3 +3 @@',
            '@@ -10,0 +11,2 @@',
            '@@ -20,3 +22,0 @@',
            'diff --git a/New.swift b/New.swift',
            '--- /dev/null',
            '+++ b/New.swift',
            '@@ -0,0 +1,3 @@',
            'diff --git a/Gone.swift b/Gone.swift',
            '--- a/Gone.swift',
            '+++ /dev/null',
            '@@ -1,2 +0,0 @@',
        ])
        self.assertEqual(tglint.parse_unified_diff(diff), {'A.swift': {3, 11, 12}, 'New.swift': {1, 2, 3}})

    def test_vendored_paths_are_not_linted(self):
        for path in ('submodules/telegram-ios/submodules/TelegramCore/Sources/A.swift', 'submodules/Sparkle/X.swift',
                     'third-party/libprisma/X.swift', 'core-xprojects/webrtc/X.swift', 'build-output/X.swift'):
            self.assertFalse(tglint.is_lintable(path), path)
        self.assertFalse(tglint.is_lintable('packages/A/README.md'))
        for path in ('packages/NanogramKit/Sources/NanogramKit/Nanogram.swift', 'packages/TGUIKit/Sources/Window.swift',
                     'Telegram-Mac/app/AppDelegate.swift', 'TelegramShare/ShareViewController.swift'):
            self.assertTrue(tglint.is_lintable(path), path)

    def test_tools_dir_is_ours(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('TG_TOOLS_DIR', None)
            self.assertEqual(tglint.tools_dir(), os.path.join(os.path.expanduser('~'), '.cache', 'nanogram-macos', 'tools'))


class FilterTests(unittest.TestCase):
    def violation(self, line, rule='int32_timestamp_arithmetic', path='packages/A/Sources/A.swift', character=1, severity='error'):
        return {'path': path, 'line': line, 'character': character, 'severity': severity, 'rule_id': rule, 'reason': 'r'}

    def test_only_changed_lines_are_kept(self):
        source = {'packages/A/Sources/A.swift': ['until + 1', 'until + 1']}
        kept = tglint.filter_violations([self.violation(1), self.violation(2)], {'packages/A/Sources/A.swift': {2}}, source)
        self.assertEqual([v['line'] for v in kept], [2])

    def test_name_declared_wide_earlier_is_dropped(self):
        lines = [
            'func until(_ second: Int64) -> Double { 0 }',
            'let statusTimestamp = Int64(statusTimestamp)',
            'let x = until(statusTimestamp + 1)',
            'let y = until(second + 1)',
        ]
        path = 'packages/A/Sources/A.swift'
        violations = [self.violation(3, character=15), self.violation(4, character=15)]
        kept = tglint.filter_violations(violations, {path: {3, 4}}, {path: lines})
        # `statusTimestamp` was widened on line 2; `second` is only wide inside `until`, but the
        # file-level check cannot tell scopes apart and drops it too (documented limitation).
        self.assertEqual(kept, [])

    def test_int32_name_is_kept(self):
        lines = [
            'case let .present(statusTimestamp):',
            '    return until(statusTimestamp + 1)',
        ]
        path = 'packages/A/Sources/A.swift'
        kept = tglint.filter_violations([self.violation(2, character=18)], {path: {2}}, {path: lines})
        self.assertEqual(len(kept), 1)

    def test_wide_declaration_after_the_use_does_not_count(self):
        lines = [
            'let a = lastActivity + 30',
            'var lastActivity: Int64 = 0',
        ]
        path = 'packages/A/Sources/A.swift'
        kept = tglint.filter_violations([self.violation(1, character=9)], {path: {1}}, {path: lines})
        self.assertEqual(len(kept), 1)

    def test_force_rules_in_tests_are_warnings(self):
        path = 'packages/A/Tests/ATests/ATests.swift'
        kept = tglint.filter_violations([self.violation(1, rule='force_try', path=path)], {path: {1}}, {path: ['try! f()']})
        self.assertEqual(kept[0]['severity'], 'warning')
        kept = tglint.filter_violations([self.violation(1, path=path)], {path: {1}}, {path: ['until + 1']})
        self.assertEqual(kept[0]['severity'], 'error')


class UpstreamMergeTests(RepoTestCase):
    path = 'Telegram-Mac/A.swift'

    def setUp(self):
        super().setUp()
        write(self.repo, self.path, 'let a = 1\n')
        self.base = commit_all(self.repo)

    def branch_with_line(self, branch, line):
        run(['git', 'checkout', '-q', '-b', branch, self.base], self.repo)
        write(self.repo, self.path, 'let a = 1\n' + line + '\n')
        commit_all(self.repo, branch)
        run(['git', 'checkout', '-q', 'main'], self.repo)

    def merge_then_add_ours(self, branch):
        run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', 'merge', '-q', '--no-ff', '-m', 'merge', branch], self.repo)
        with open(os.path.join(self.repo, self.path)) as f:
            text = f.read()
        write(self.repo, self.path, text + 'let ours = y as! Z\n')
        return commit_all(self.repo, 'ours')

    def test_lines_merged_from_upstream_are_not_ours(self):
        self.branch_with_line('upstream', 'let theirs = x as! Y')
        head = self.merge_then_add_ours('upstream')
        self.assertEqual(tglint.changed_lines_commits(self.base, head), {self.path: {3}})
        self.assertEqual(tglint.changed_lines_worktree(self.base), {self.path: {3}})

    def test_lines_merged_from_our_own_branch_stay_ours(self):
        self.branch_with_line('feature', 'let theirs = x as! Y')
        head = self.merge_then_add_ours('feature')
        self.assertEqual(tglint.changed_lines_commits(self.base, head), {self.path: {2, 3}})


class AffectedPackagesTests(RepoTestCase):
    def setUp(self):
        super().setUp()
        write(self.repo, 'packages/A/Package.swift', '')
        write(self.repo, 'packages/A/Sources/A/A.swift', '')
        write(self.repo, 'packages/A/Tests/ATests/ATests.swift', '')
        write(self.repo, 'packages/B/Package.swift', '')
        write(self.repo, 'packages/B/Sources/B/B.swift', '')
        write(self.repo, 'packages/NanogramKit/Package.swift', '')
        write(self.repo, 'packages/NanogramKit/Tests/NanogramKitTests/T.swift', '')
        commit_all(self.repo)

    def test_affected_packages(self):
        packages = tglint.affected_packages([
            'packages/B/Sources/B/B.swift',            # no Tests/ folder
            'packages/A/Tests/ATests/ATests.swift',
            'packages/A/Sources/A/A.swift',
            'Telegram-Mac/app/AppDelegate.swift',       # not a package
            'submodules/telegram-ios/submodules/TelegramCore/Sources/A.swift',
            'packages/Gone/Sources/Gone.swift',         # deleted package
            'packages/A',                               # submodule-like path without a file part
        ], root=self.repo)
        self.assertEqual(packages, ['A'])

    def test_packages_to_test_always_has_nanogram_kit(self):
        self.assertEqual(tglint.packages_to_test([], root=self.repo), ['NanogramKit'])
        self.assertEqual(tglint.packages_to_test(['packages/A/Package.swift', 'packages/NanogramKit/Package.swift'],
                                                 root=self.repo), ['NanogramKit', 'A'])

    def test_changed_paths_against_base(self):
        base = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()
        write(self.repo, 'packages/A/Sources/A/A.swift', 'let a = 1\n')
        commit_all(self.repo)
        write(self.repo, 'packages/B/Sources/B/New.swift', '')  # untracked
        self.assertEqual(tglint.worktree_changed_paths(base), ['packages/A/Sources/A/A.swift', 'packages/B/Sources/B/New.swift'])

    def test_real_repo_packages(self):
        packages = tglint.affected_packages(['packages/NanogramKit/Sources/NanogramKit/Nanogram.swift',
                                             'packages/TGUIKit/Sources/Window.swift'], root=REPO)
        self.assertEqual(packages, ['NanogramKit', 'TGUIKit'])


class DefaultBaseTests(RepoTestCase):
    def test_head_without_upstream(self):
        write(self.repo, 'a.txt', '1')
        commit_all(self.repo)
        self.assertEqual(tglint.default_base(), 'HEAD')

    def test_merge_base_with_upstream(self):
        write(self.repo, 'a.txt', '1')
        first = commit_all(self.repo)
        remote = tempfile.mkdtemp(prefix='tglint-remote-')
        self.addCleanup(shutil.rmtree, remote, True)
        run(['git', 'init', '-q', '--bare', remote], self.repo)
        run(['git', 'remote', 'add', 'origin', remote], self.repo)
        run(['git', 'push', '-q', '-u', 'origin', 'main'], self.repo)
        write(self.repo, 'a.txt', '2')
        commit_all(self.repo)
        self.assertEqual(tglint.default_base(), first)

    def test_origin_branch_without_upstream(self):
        write(self.repo, 'a.txt', '1')
        first = commit_all(self.repo)
        remote = tempfile.mkdtemp(prefix='tglint-remote-')
        self.addCleanup(shutil.rmtree, remote, True)
        run(['git', 'init', '-q', '--bare', remote], self.repo)
        run(['git', 'remote', 'add', 'origin', remote], self.repo)
        run(['git', 'push', '-q', 'origin', 'main'], self.repo)  # no -u: no upstream configured
        write(self.repo, 'a.txt', '2')
        commit_all(self.repo)
        self.assertEqual(tglint.default_base(), first)


class PushRangeTests(RepoTestCase):
    def setUp(self):
        super().setUp()
        write(self.repo, 'a.txt', '1')
        self.first = commit_all(self.repo)
        self.remote = tempfile.mkdtemp(prefix='tglint-remote-')
        self.addCleanup(shutil.rmtree, self.remote, True)
        run(['git', 'init', '-q', '--bare', self.remote], self.repo)
        run(['git', 'remote', 'add', 'origin', self.remote], self.repo)
        run(['git', 'push', '-q', 'origin', 'main'], self.repo)

    def test_existing_branch_starts_at_remote_commit(self):
        write(self.repo, 'a.txt', '2')
        head = commit_all(self.repo)
        self.assertEqual(tglint.push_base('origin', head, self.first), self.first)

    def test_new_branch_starts_where_it_leaves_the_remote(self):
        run(['git', 'switch', '-q', '-c', 'feature'], self.repo)
        write(self.repo, 'b.txt', '1')
        commit_all(self.repo)
        write(self.repo, 'b.txt', '2')
        head = commit_all(self.repo)
        self.assertEqual(tglint.push_base('origin', head, tglint.ZERO_SHA), self.first)

    def test_nothing_new(self):
        self.assertIsNone(tglint.push_base('origin', self.first, tglint.ZERO_SHA))

    def test_parse_refs(self):
        text = 'refs/heads/main {} refs/heads/main {}\n'.format('a' * 40, tglint.ZERO_SHA)
        self.assertEqual(tglint.parse_push_refs(text), [('refs/heads/main', 'a' * 40, 'refs/heads/main', tglint.ZERO_SHA)])


class PrePushTests(PushRangeTests):
    def push(self, env=None):
        write(self.repo, 'a.txt', '2')
        head = commit_all(self.repo)
        stdin = 'refs/heads/main {} refs/heads/main {}\n'.format(head, self.first)
        calls = []

        def fake_call(cmd, cwd=None):
            calls.append(cmd)
            return 0

        with mock.patch.dict(os.environ, env or {}), mock.patch('sys.stdin', io.StringIO(stdin)), \
                mock.patch.object(tglint, 'lint_changed', return_value=[]), \
                mock.patch.object(tglint.subprocess, 'call', side_effect=fake_call), \
                mock.patch('sys.stdout', io.StringIO()):
            status = tglint.cmd_pre_push(mock.Mock(remote='origin'))
        return status, calls

    def test_runs_tg_check_from_the_push_base(self):
        status, calls = self.push()
        self.assertEqual(status, 0)
        self.assertEqual(calls, [[os.path.join(self.repo, 'tools', 'dev', 'tg'), 'check', '--base', self.first]])

    def test_lint_only(self):
        status, calls = self.push({'TG_PRE_PUSH_CHECK': '0'})
        self.assertEqual((status, calls), (0, []))

    def test_blocking_finding_stops_the_push(self):
        write(self.repo, 'a.txt', '2')
        head = commit_all(self.repo)
        stdin = 'refs/heads/main {} refs/heads/main {}\n'.format(head, self.first)
        finding = {'path': 'packages/A/Sources/A.swift', 'line': 1, 'character': 1, 'severity': 'error',
                   'rule_id': 'force_try', 'reason': 'r'}
        with mock.patch('sys.stdin', io.StringIO(stdin)), \
                mock.patch.object(tglint, 'lint_changed', return_value=[finding]), \
                mock.patch.object(tglint.subprocess, 'call') as call, \
                mock.patch('sys.stdout', io.StringIO()), mock.patch('sys.stderr', io.StringIO()):
            self.assertEqual(tglint.cmd_pre_push(mock.Mock(remote='origin')), 1)
        call.assert_not_called()


class InstallHookTests(RepoTestCase):
    def test_install_and_uninstall(self):
        args = mock.Mock(uninstall=False)
        with mock.patch('sys.stdout', io.StringIO()):
            self.assertEqual(tglint.cmd_install_hook(args), 0)
            hook = os.path.join(self.repo, '.git', 'hooks', 'pre-push')
            with open(hook) as f:
                self.assertIn(tglint.HOOK_MARKER, f.read())
            self.assertTrue(os.access(hook, os.X_OK))
            args.uninstall = True
            self.assertEqual(tglint.cmd_install_hook(args), 0)
            self.assertFalse(os.path.exists(hook))

    def test_foreign_hook_is_kept(self):
        write(self.repo, '.git/hooks/pre-push', '#!/bin/sh\necho mine\n')
        with mock.patch('sys.stderr', io.StringIO()):
            self.assertEqual(tglint.cmd_install_hook(mock.Mock(uninstall=False)), 1)
        with open(os.path.join(self.repo, '.git', 'hooks', 'pre-push')) as f:
            self.assertIn('echo mine', f.read())


class InstallTests(unittest.TestCase):
    def test_checksum_mismatch_installs_nothing(self):
        tools = tempfile.mkdtemp(prefix='tglint-tools-')
        self.addCleanup(shutil.rmtree, tools, True)
        with mock.patch.dict(os.environ, {'TG_TOOLS_DIR': tools}), \
                mock.patch('urllib.request.urlopen', return_value=io.BytesIO(b'not the release')), \
                mock.patch('sys.stdout', io.StringIO()), mock.patch('sys.stderr', io.StringIO()) as err:
            self.assertEqual(tglint.cmd_install(None), 1)
            self.assertIn('checksum mismatch', err.getvalue())
            self.assertFalse(os.path.exists(tglint.swiftlint_path()))
            self.assertEqual(os.listdir(tools), [])


class OverflowTrapsStayOnTests(RepoTestCase):
    """Swift traps on integer overflow unless built with -Ounchecked; keep it that way."""

    def test_detects_unchecked_flags(self):
        write(self.repo, 'packages/A/Package.swift', 'unsafeFlags(["-Ounchecked"])\n')
        write(self.repo, 'nanogram/Nanogram.xcconfig', 'OTHER_SWIFT_FLAGS = -enforce-exclusivity=unchecked\n')
        write(self.repo, 'third-party/x/Package.swift', 'unsafeFlags(["-Ounchecked"])\n')
        write(self.repo, 'submodules/x/Package.swift', 'unsafeFlags(["-Ounchecked"])\n')
        commit_all(self.repo)
        self.assertEqual(tglint.find_trap_removing_flags(self.repo), [
            'nanogram/Nanogram.xcconfig:1:OTHER_SWIFT_FLAGS = -enforce-exclusivity=unchecked',
            'packages/A/Package.swift:1:unsafeFlags(["-Ounchecked"])',
        ])

    def test_repo_keeps_traps(self):
        if not os.path.exists(os.path.join(REPO, '.git')):
            self.skipTest('not in a git checkout')
        self.assertEqual(tglint.find_trap_removing_flags(REPO), [])


@unittest.skipUnless(HAVE_SWIFTLINT, 'SwiftLint not installed (python3 tools/dev/lint/tglint.py install)')
class SwiftLintRulesTests(RepoTestCase):
    """Runs the real config on the iOS code that crashed at launch (2c51ac0d) and on its fix (aee7088e)."""

    def lint_new_file(self, rel, text):
        write(self.repo, 'README', '')
        commit_all(self.repo)
        write(self.repo, rel, text)
        return tglint.lint_changed(tglint.changed_lines_worktree('HEAD'))

    def test_launch_crash_code_is_blocked(self):
        violations = self.lint_new_file('packages/P/Sources/P.swift', fixture('presence_2c51ac0d.swift.txt'))
        overflow = [v['line'] for v in violations if v['rule_id'] == 'int32_timestamp_arithmetic' and v['severity'] == 'error']
        # until(statusTimestamp + 1), until(statusTimestamp + 31), lastActivity + 30, until(activeUntil + 1)
        self.assertEqual(overflow, [27, 37, 46, 48])
        conversions = [v['line'] for v in violations if v['rule_id'] == 'narrowing_integer_conversion']
        self.assertEqual(conversions, [22])  # let now = Int32(timestamp)

    def test_fix_passes(self):
        violations = self.lint_new_file('packages/P/Sources/P.swift', fixture('presence_aee7088e.swift.txt'))
        self.assertEqual([v for v in violations if v['severity'] == 'error'], [])

    def test_vendored_file_is_not_linted(self):
        violations = self.lint_new_file('submodules/P/Sources/P.swift', 'let a = try! f()\n')
        self.assertEqual(violations, [])

    def test_only_changed_lines_of_existing_code(self):
        write(self.repo, 'packages/P/Sources/P.swift', 'func f(_ until: Int32) -> Int32 {\n    return until + 1\n}\n')
        commit_all(self.repo)
        write(self.repo, 'packages/P/Sources/P.swift', 'func f(_ until: Int32) -> Int32 {\n    return until + 1\n}\nlet x = [1].first!\n')
        violations = tglint.lint_changed(tglint.changed_lines_worktree('HEAD'))
        self.assertEqual([(v['line'], v['rule_id']) for v in violations], [(4, 'force_unwrapping')])

    def test_committed_content_is_linted(self):
        write(self.repo, 'README', '')
        base = commit_all(self.repo)
        write(self.repo, 'packages/P/Sources/P.swift', 'let a = try! f()\n')
        head = commit_all(self.repo)
        write(self.repo, 'packages/P/Sources/P.swift', 'let a = 1\n')  # uncommitted fix is not what is pushed
        violations = tglint.lint_changed(tglint.changed_lines_commits(base, head), head)
        self.assertEqual([(v['line'], v['rule_id'], v['severity']) for v in violations], [(1, 'force_try', 'error')])

    def test_force_operations_and_precision(self):
        source = '\n'.join([
            'import Foundation',
            'func f(_ any: Any, _ s: String?, _ d: Double, _ messageTimestamp: Int32) throws -> Int32 {',
            '    let a = any as! Int',                                  # 3 force_cast
            '    let b = try! JSONSerialization.data(withJSONObject: [])',  # 4 force_try
            '    let c = s!',                                            # 5 force_unwrapping
            '    let e = messageTimestamp + 86400',                       # 6 overflow
            '    let g = Int32(d)',                                      # 7 conversion
            '    let h = Int32(clamping: Int64(d))',                     # 8 ok
            '    let i = Int32(exactly: d) ?? 0',                        # 9 ok
            '    let j = d + 1.0',                                       # 10 ok: floating literal
            '    // until + 1 in a comment',                             # 11 ok
            '    let k = "timestamp + 1"',                               # 12 ok: string
            '    let l = Int64(messageTimestamp) + 1',                   # 13 ok: widened
            '    let m = Int32(Date().timeIntervalSince1970) + 30',      # 14 overflow (and conversion)
            '    let n = update + 1',                                    # 15 ok: not a timestamp name
            '    let o = Int32(5)',                                      # 16 ok: literal
            '    _ = (a, b, c, e, g, h, i, j, k, l, m, n, o)',
            '    return 0',
            '}',
            'let update = 1',
        ])
        violations = self.lint_new_file('packages/P/Sources/P.swift', source)
        found = sorted((v['line'], v['rule_id']) for v in violations)
        self.assertEqual(found, [
            (3, 'force_cast'),
            (4, 'force_try'),
            (5, 'force_unwrapping'),
            (6, 'int32_timestamp_arithmetic'),
            (7, 'narrowing_integer_conversion'),
            (14, 'int32_timestamp_arithmetic'),
            (14, 'narrowing_integer_conversion'),
        ])


    def test_discarded_member_list_subscription(self):
        source = '\n'.join([
            'func f(_ context: Context, _ peerId: PeerId, _ set: DisposableSet) {',
            '    _ = context.peerChannelMemberCategoriesContextsManager.admins(peerId: peerId, updated: { _ in })',  # 2
            '    let _ = context.peerChannelMemberCategoriesContextsManager.recent(peerId: peerId, updated: { _ in })',  # 3
            '    _ = (context.peerChannelMemberCategoriesContextsManager.banned(peerId: peerId, updated: { _ in }))',  # 4
            '    let (disposable, _) = context.peerChannelMemberCategoriesContextsManager.admins(peerId: peerId, updated: { _ in })',  # 5 ok
            '    set.add(disposable)',
            '    _ = context.peerChannelMemberCategoriesContextsManager.updateMemberBannedRights(peerId: peerId).start()',  # 7 ok
            '    // _ = context.peerChannelMemberCategoriesContextsManager.admins(',  # 8 ok: comment
            '}',
        ])
        violations = self.lint_new_file('packages/P/Sources/P.swift', source)
        found = sorted((v['line'], v['severity']) for v in violations if v['rule_id'] == 'discarded_member_list_subscription')
        self.assertEqual(found, [(2, 'error'), (3, 'error'), (4, 'error')])


@unittest.skipUnless(HAVE_SWIFTLINT, 'SwiftLint not installed (python3 tools/dev/lint/tglint.py install)')
class RepoMemberListSubscriptionsTests(unittest.TestCase):
    """Every member-list subscription in the app keeps its disposable (port of iOS 42e24c27)."""

    def test_repo_keeps_member_list_disposables(self):
        if not os.path.exists(os.path.join(REPO, '.git')):
            self.skipTest('not in a git checkout')
        files = subprocess.run(
            ['git', 'grep', '-l', 'peerChannelMemberCategoriesContextsManager', '--', '*.swift',
             ':!submodules', ':!third-party', ':!core-xprojects'],
            cwd=REPO, capture_output=True, text=True).stdout.split()
        self.assertTrue(files)
        violations = tglint.run_swiftlint(files, REPO)
        found = sorted('{}:{}'.format(v['path'], v['line']) for v in violations
                       if v['rule_id'] == 'discarded_member_list_subscription')
        self.assertEqual(found, [])


if __name__ == '__main__':
    unittest.main()
