#!/usr/bin/env python3
"""Lint and test guardrails for changed code.

  tglint.py install                    download the pinned SwiftLint (checksum verified)
  tglint.py lint [--base REV]          lint changed Swift lines (default: working tree vs HEAD)
  tglint.py lint --commits A..B        lint the lines B changes relative to A, as committed in B
  tglint.py affected-packages [--base REV] [paths]
                                       packages `tg test` runs: NanogramKit plus changed packages with Tests/
  tglint.py default-base               the merge-base with the branch's upstream or origin/<branch> (else HEAD)
  tglint.py pre-push REMOTE URL        git pre-push hook (reads refs on stdin): lint the pushed lines, then tg check
  tglint.py install-hook [--uninstall]

Ported from Telegram-iOS 5ac4d079 (tools/dev/lint/tglint.py). macOS changes: tools in
~/.cache/nanogram-macos/tools, submodules/ and core-xprojects/ are vendored, affected_packages (SwiftPM
packages with a Tests/ folder) replaces the Bazel affected_tests, and pre-push runs `tg check`.
See docs/local-development.md.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
LINT_DIR = os.path.join(ROOT, 'tools', 'dev', 'lint')
CONFIG = os.path.join(LINT_DIR, 'swiftlint.yml')

SWIFTLINT_VERSION = '0.65.1'
SWIFTLINT_URL = 'https://github.com/realm/SwiftLint/releases/download/{v}/portable_swiftlint.zip'.format(v=SWIFTLINT_VERSION)
# GitHub's asset digest for portable_swiftlint.zip (macOS universal binary).
SWIFTLINT_SHA256 = 'c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0'

ZERO_SHA = '0' * 40

# Not ours to lint: vendored code and build outputs.
EXCLUDED_PREFIXES = ('submodules/', 'third-party/', 'core-xprojects/', 'build-output/')

# Force operations in tests crash only the test run; report them, don't block on them.
TEST_DOWNGRADED_RULES = {'force_unwrapping', 'force_try', 'force_cast', 'implicitly_unwrapped_optional'}

WIDE_TYPES = r'(?:Int|Int64|UInt64|Double|Float|Float64|CGFloat|TimeInterval|CFAbsoluteTime|CFTimeInterval|Date)'

# Tested on every `tg test`, whatever changed.
ALWAYS_TESTED = ('NanogramKit',)


def tools_dir():
    return os.environ.get('TG_TOOLS_DIR', os.path.join(os.path.expanduser('~'), '.cache', 'nanogram-macos', 'tools'))


def swiftlint_path():
    return os.path.join(tools_dir(), 'swiftlint-' + SWIFTLINT_VERSION, 'swiftlint')


def git(*args, cwd=None, check=True, input=None):
    result = subprocess.run(['git'] + list(args), cwd=cwd or ROOT, input=input, capture_output=True, text=True,
                            encoding='utf-8', errors='replace')
    if check and result.returncode != 0:
        raise RuntimeError('git {} failed: {}'.format(' '.join(args), result.stderr.strip()))
    return result.stdout


# --- SwiftLint install -------------------------------------------------------

def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def cmd_install(_args):
    target = swiftlint_path()
    if os.path.exists(target):
        print('SwiftLint {} already installed: {}'.format(SWIFTLINT_VERSION, target))
        return 0
    directory = os.path.dirname(target)
    os.makedirs(os.path.dirname(directory), exist_ok=True)
    work = tempfile.mkdtemp(prefix='swiftlint-', dir=os.path.dirname(directory))
    try:
        archive = os.path.join(work, 'portable_swiftlint.zip')
        print('Downloading ' + SWIFTLINT_URL)
        with urllib.request.urlopen(SWIFTLINT_URL) as response, open(archive, 'wb') as out:
            shutil.copyfileobj(response, out)
        actual = sha256_of(archive)
        if actual != SWIFTLINT_SHA256:
            print('error: checksum mismatch for portable_swiftlint.zip: got {}, want {}'.format(actual, SWIFTLINT_SHA256), file=sys.stderr)
            return 1
        unpacked = os.path.join(work, 'unpacked')
        with zipfile.ZipFile(archive) as z:
            member = z.getinfo('swiftlint')
            z.extract(member, unpacked)
        binary = os.path.join(unpacked, 'swiftlint')
        os.chmod(binary, 0o755)
        os.makedirs(directory, exist_ok=True)
        os.replace(binary, target)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('Installed SwiftLint {} to {}'.format(SWIFTLINT_VERSION, target))
    return 0


# --- Changed lines -------------------------------------------------------------

HUNK_RE = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')


def parse_unified_diff(text):
    """Maps each new-side path in a `git diff -U0` to the set of added/changed line numbers."""
    changed = {}
    path = None
    for line in text.splitlines():
        if line.startswith('+++ '):
            target = line[4:]
            if target == '/dev/null':
                path = None
            else:
                path = target[2:] if target.startswith('b/') else target
                changed.setdefault(path, set())
            continue
        match = HUNK_RE.match(line)
        if match and path is not None:
            start = int(match.group(1))
            count = 1 if match.group(2) is None else int(match.group(2))
            changed[path].update(range(start, start + count))
    return {p: lines for p, lines in changed.items()}


def is_lintable(path):
    return path.endswith('.swift') and not path.startswith(EXCLUDED_PREFIXES)


def changed_lines_worktree(base):
    diff = git('diff', '-U0', '--no-color', '--no-ext-diff', '--diff-filter=AMR', '-M', base, '--', '*.swift')
    changed = parse_unified_diff(diff)
    for path in git('ls-files', '--others', '--exclude-standard', '--', '*.swift').splitlines():
        full = os.path.join(ROOT, path)
        with open(full, encoding='utf-8', errors='replace') as f:
            count = sum(1 for _ in f)
        changed[path] = set(range(1, count + 1))
    return {p: l for p, l in changed.items() if is_lintable(p) and l}


def changed_lines_commits(base, head):
    diff = git('diff', '-U0', '--no-color', '--no-ext-diff', '--diff-filter=AMR', '-M', base, head, '--', '*.swift')
    return {p: l for p, l in parse_unified_diff(diff).items() if is_lintable(p) and l}


# --- Violations ------------------------------------------------------------------

def is_test_path(path):
    return '/Tests/' in '/' + path or path.startswith('Tests/')


def declared_wide_before(source_lines, name, line):
    """True when `name` is declared with a 64-bit or floating type before `line` (1-based)."""
    escaped = re.escape(name)
    patterns = [
        re.compile(r'\b' + escaped + r'\s*:\s*' + WIDE_TYPES + r'\b(?!\.)'),
        re.compile(r'\b(?:let|var)\s+' + escaped + r'\s*=\s*' + WIDE_TYPES + r'\('),
    ]
    for text in source_lines[:max(0, line - 1)]:
        if any(p.search(text) for p in patterns):
            return True
    return False


def filter_violations(violations, changed, sources):
    """Keeps violations on changed lines and applies the repo's adjustments.

    violations: dicts with path (repo-relative), line, character, severity ('error'/'warning'), rule_id, reason.
    sources: path -> list of source lines.
    """
    kept = []
    for v in violations:
        lines = changed.get(v['path'])
        if not lines or v['line'] not in lines:
            continue
        v = dict(v)
        if v['rule_id'] == 'int32_timestamp_arithmetic':
            text = sources.get(v['path'], [])
            if 0 < v['line'] <= len(text):
                start = max(0, (v.get('character') or 1) - 1)
                match = re.match(r'\w+', text[v['line'] - 1][start:])
                if match and match.group(0) != 'Int32' and declared_wide_before(text, match.group(0), v['line']):
                    continue
        if v['severity'] == 'error' and is_test_path(v['path']) and v['rule_id'] in TEST_DOWNGRADED_RULES:
            v['severity'] = 'warning'
        kept.append(v)
    kept.sort(key=lambda v: (v['path'], v['line'], v.get('character') or 0))
    return kept


def run_swiftlint(files, cwd):
    binary = os.environ.get('TG_SWIFTLINT', swiftlint_path())
    if not os.path.exists(binary):
        raise FileNotFoundError(binary)
    violations = []
    for i in range(0, len(files), 200):
        chunk = files[i:i + 200]
        result = subprocess.run(
            [binary, 'lint', '--quiet', '--no-cache', '--reporter', 'json', '--config', CONFIG] + chunk,
            cwd=cwd, capture_output=True, text=True)
        if result.returncode not in (0, 2):
            raise RuntimeError('swiftlint failed ({}): {}'.format(result.returncode, result.stderr.strip()))
        for item in json.loads(result.stdout or '[]'):
            path = os.path.relpath(os.path.realpath(item['file']), os.path.realpath(cwd))
            violations.append({
                'path': path,
                'line': item.get('line') or 0,
                'character': item.get('character'),
                'severity': (item.get('severity') or '').lower(),
                'rule_id': item.get('rule_id'),
                'reason': item.get('reason'),
            })
    return violations


def read_lines(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read().split('\n')


def lint_changed(changed, commit=None):
    """Returns the kept violations. With `commit`, lints the files as committed there."""
    if not changed:
        return []
    files = sorted(changed)
    if commit is None:
        cwd = ROOT
        sources = {p: read_lines(os.path.join(ROOT, p)) for p in files}
        return filter_violations(run_swiftlint(files, cwd), changed, sources)
    work = tempfile.mkdtemp(prefix='tglint-')
    try:
        sources = {}
        for p in files:
            content = git('show', '{}:{}'.format(commit, p))
            dest = os.path.join(work, p)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'w', encoding='utf-8') as f:
                f.write(content)
            sources[p] = content.split('\n')
        return filter_violations(run_swiftlint(files, work), changed, sources)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def report(violations, strict):
    errors = 0
    for v in violations:
        if v['severity'] == 'error' or strict:
            errors += 1
        print('{}:{}:{}: {}: {} ({})'.format(v['path'], v['line'], v.get('character') or 1, v['severity'], v['reason'], v['rule_id']))
    return errors


def missing_swiftlint_message():
    return 'SwiftLint {} is not installed. Run: python3 tools/dev/lint/tglint.py install'.format(SWIFTLINT_VERSION)


def cmd_lint(args):
    if args.commits:
        if '...' in args.commits or '..' not in args.commits:
            print('error: --commits takes A..B', file=sys.stderr)
            return 2
        base, _, head = args.commits.partition('..')
        changed = changed_lines_commits(base, head or 'HEAD')
        commit = head or 'HEAD'
    else:
        changed = changed_lines_worktree(args.base)
        commit = None
    try:
        violations = lint_changed(changed, commit)
    except FileNotFoundError:
        print('error: ' + missing_swiftlint_message(), file=sys.stderr)
        return 2
    errors = report(violations, args.strict)
    print('tglint: {} changed Swift file(s), {} finding(s), {} blocking'.format(len(changed), len(violations), errors))
    return 1 if errors else 0


# --- Build flags -------------------------------------------------------------------

# Swift traps on overflow, failed force unwraps and bad casts unless these are set.
TRAP_REMOVING_FLAGS = r'-Ounchecked|-remove-runtime-asserts|-enforce-exclusivity=unchecked|-assert-config +Unchecked'


def find_trap_removing_flags(root=None):
    result = subprocess.run(
        ['git', 'grep', '-n', '-E', '-e', TRAP_REMOVING_FLAGS, '--', '*Package.swift', '*.xcconfig', '*.pbxproj',
         'tools/dev/tg', 'tools/dev/nanogram/*.py', ':!submodules', ':!third-party', ':!core-xprojects'],
        cwd=root or ROOT, capture_output=True, text=True)
    return result.stdout.splitlines()


# --- Affected packages -----------------------------------------------------------

PACKAGE_PATH_RE = re.compile(r'^packages/([^/]+)/.')


def affected_packages(paths, root=None):
    """SwiftPM packages under packages/ that have a Tests/ folder and whose files changed, sorted."""
    root = root or ROOT
    packages = set()
    for path in paths:
        match = PACKAGE_PATH_RE.match(path)
        if not match:
            continue
        directory = os.path.join(root, 'packages', match.group(1))
        if os.path.isfile(os.path.join(directory, 'Package.swift')) and os.path.isdir(os.path.join(directory, 'Tests')):
            packages.add(match.group(1))
    return sorted(packages)


def packages_to_test(paths, root=None):
    """ALWAYS_TESTED, then the affected packages."""
    affected = affected_packages(paths, root)
    return list(ALWAYS_TESTED) + [p for p in affected if p not in ALWAYS_TESTED]


def worktree_changed_paths(base='HEAD'):
    paths = git('diff', '--name-only', '--no-renames', base).splitlines()
    paths += git('ls-files', '--others', '--exclude-standard').splitlines()
    return sorted(set(paths))


def default_base():
    """Where unpushed work starts: the merge-base with the branch's upstream (else origin/<branch>), or HEAD."""
    upstream = git('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}', check=False).strip()
    if not upstream:
        branch = git('symbolic-ref', '--quiet', '--short', 'HEAD', check=False).strip()
        if branch and git('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/' + branch, check=False).strip():
            upstream = 'origin/' + branch
    if upstream:
        base = git('merge-base', 'HEAD', upstream, check=False).strip()
        if base:
            return base
    return 'HEAD'


def cmd_affected_packages(args):
    paths = args.paths or worktree_changed_paths(args.base or default_base())
    for package in packages_to_test(paths):
        print(package)
    return 0


def cmd_default_base(_args):
    print(default_base())
    return 0


# --- pre-push ----------------------------------------------------------------------

def push_base(remote, local_sha, remote_sha):
    """The commit the pushed range starts from, or None when it cannot be found."""
    if remote_sha != ZERO_SHA and subprocess.run(['git', 'cat-file', '-e', remote_sha + '^{commit}'],
                                                 cwd=ROOT, capture_output=True).returncode == 0:
        return git('merge-base', remote_sha, local_sha, check=False).strip() or remote_sha
    # New branch: start where it leaves what the remote already has.
    first = git('rev-list', '--reverse', local_sha, '--not', '--remotes=' + remote, check=False).split()
    if not first:
        return None
    parent = git('rev-parse', '--verify', '--quiet', first[0] + '^', check=False).strip()
    return parent or None


def parse_push_refs(text):
    refs = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4:
            refs.append(tuple(parts))
    return refs


def cmd_pre_push(args):
    if os.environ.get('TG_PRE_PUSH') == '0':
        return 0
    refs = parse_push_refs(sys.stdin.read())
    head = git('rev-parse', 'HEAD', check=False).strip()
    check_base = None
    blocking = 0
    for local_ref, local_sha, remote_ref, remote_sha in refs:
        if local_sha == ZERO_SHA:
            continue  # deleting a ref
        base = push_base(args.remote, local_sha, remote_sha)
        if base is None:
            print('tglint: {}: nothing new to check'.format(local_ref))
            continue
        if check_base is None or local_sha == head:
            check_base = base
        print('tglint: checking {} ({}..{})'.format(local_ref, base[:10], local_sha[:10]))
        try:
            violations = lint_changed(changed_lines_commits(base, local_sha), local_sha)
        except FileNotFoundError:
            print('error: ' + missing_swiftlint_message(), file=sys.stderr)
            print('(skip this check once with: git push --no-verify)', file=sys.stderr)
            return 1
        blocking += report(violations, os.environ.get('TG_LINT_STRICT') == '1')
    if blocking:
        print('tglint: {} blocking lint finding(s); push stopped. Fix them, or push with --no-verify.'.format(blocking), file=sys.stderr)
        return 1
    if os.environ.get('TG_PRE_PUSH_CHECK') == '0' or check_base is None:
        return 0
    if git('status', '--porcelain', '--untracked-files=no', check=False).strip():
        print('tglint: warning: the working tree has uncommitted changes; tg check runs on the working tree, not the pushed commits')
    tg = os.path.join(ROOT, 'tools', 'dev', 'tg')
    print('tglint: tools/dev/tg check --base ' + check_base[:10], flush=True)
    if subprocess.call([tg, 'check', '--base', check_base], cwd=ROOT) != 0:
        print('tglint: tg check failed; push stopped (skip once with: git push --no-verify)', file=sys.stderr)
        return 1
    return 0


HOOK_MARKER = '# installed by tools/dev/lint/tglint.py'
HOOK_SCRIPT = '''#!/bin/sh
{marker}
# Runs the pre-push checks of the checkout being pushed from.
root="$(git rev-parse --show-toplevel)" || exit 1
if [ ! -x "$root/tools/dev/lint/pre-push" ]; then
  exit 0
fi
exec "$root/tools/dev/lint/pre-push" "$@"
'''.format(marker=HOOK_MARKER)


def cmd_install_hook(args):
    hooks = git('rev-parse', '--git-path', 'hooks').strip()
    hooks = hooks if os.path.isabs(hooks) else os.path.join(ROOT, hooks)
    path = os.path.join(hooks, 'pre-push')
    existing = None
    if os.path.exists(path):
        with open(path, encoding='utf-8', errors='replace') as f:
            existing = f.read()
    ours = existing is not None and HOOK_MARKER in existing
    if args.uninstall:
        if ours:
            os.remove(path)
            print('Removed ' + path)
        else:
            print('No tglint pre-push hook at ' + path)
        return 0
    if existing is not None and not ours:
        print('error: {} exists and is not ours; not replacing it'.format(path), file=sys.stderr)
        return 1
    os.makedirs(hooks, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(HOOK_SCRIPT)
    os.chmod(path, 0o755)
    print('Installed ' + path)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('install')
    lint = sub.add_parser('lint')
    lint.add_argument('--base', default='HEAD', help='compare the working tree with this revision')
    lint.add_argument('--commits', help='A..B: lint what B changes relative to A, as committed')
    lint.add_argument('--strict', action='store_true', help='warnings block too')
    affected = sub.add_parser('affected-packages')
    affected.add_argument('--base', help='compare the working tree with this revision (default: default-base)')
    affected.add_argument('paths', nargs='*')
    sub.add_parser('default-base')
    push = sub.add_parser('pre-push')
    push.add_argument('remote')
    push.add_argument('url', nargs='?')
    hook = sub.add_parser('install-hook')
    hook.add_argument('--uninstall', action='store_true')
    args = parser.parse_args(argv)
    return {
        'install': cmd_install,
        'lint': cmd_lint,
        'affected-packages': cmd_affected_packages,
        'default-base': cmd_default_base,
        'pre-push': cmd_pre_push,
        'install-hook': cmd_install_hook,
    }[args.command](args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
