"""Pre-push reminder: a push that changes product code should also touch a change record.

The records are CHANGELOG.md (what changed, newest first) and NANOGRAM-CHANGES.md (how this repository
differs from upstream). The check looks at the whole pushed range, not at single commits, so an
integrator's changelog commit satisfies it for the branches it merges. It only warns; set
TG_CHANGELOG_STRICT=1 to make it block. See shared/development-pipeline.md.

Identical in nanogram-ios and nanogram-macos.
"""

import os

RECORD_FILES = ('CHANGELOG.md', 'NANOGRAM-CHANGES.md')

CODE_SUFFIXES = ('.swift', '.m', '.mm', '.h', '.c', '.cc', '.cpp', '.hpp', '.rs', '.metal', '.bzl', '.py', '.sh')
CODE_BASENAMES = ('BUILD', 'Package.swift', 'WORKSPACE', 'MODULE.bazel')

# Not product code: documentation, tests of the tooling, vendored trees, build outputs.
IGNORED_PREFIXES = (
    'docs/',
    '.github/',
    'third-party/',
    'core-xprojects/',
    'build-output/',
    'build-input/',
    'tools/dev/tests/',
    'tools/dev/lint/tests/',
)


def is_test_path(path):
    return '/Tests/' in '/' + path or path.startswith('Tests/') or os.path.basename(path).startswith('test_')


def is_product_code(path):
    if path.startswith(IGNORED_PREFIXES) or is_test_path(path):
        return False
    base = os.path.basename(path)
    return base in CODE_BASENAMES or base.endswith(CODE_SUFFIXES)


def is_record(path):
    return os.path.basename(path) in RECORD_FILES


def reminder(paths):
    """The message to print for the pushed paths, or None when nothing is missing."""
    paths = list(paths)
    code = [p for p in paths if is_product_code(p)]
    if not code or any(is_record(p) for p in paths):
        return None
    return ('{} product file(s) changed, but no CHANGELOG.md or NANOGRAM-CHANGES.md in the pushed range '
            '(e.g. {}). Add the entry (what changed, how, why) before the release, or ignore this if an '
            'integrator writes it.').format(len(code), code[0])
