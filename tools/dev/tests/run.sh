#!/bin/bash
# Runs the tooling test suites: Python unittest plus shellcheck on the shell entry points.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

python3 -m unittest discover -s tools/dev/tests "$@"

# The shared tools (cachegc, worktree, perfgate, native-libs, module-settings, upstream-sync, FFmpeg flag parity) have one
# set of tests in klaipher/nanogram-deps; they read this repository from NANOGRAM_REPO_ROOT.
if [ -d submodules/telegram-ios/shared/tests ]; then
    NANOGRAM_REPO_ROOT="$ROOT" python3 -m unittest discover -s submodules/telegram-ios/shared/tests -t submodules/telegram-ios/shared "$@"
else
    echo "shared tools tests skipped: submodules/telegram-ios/shared is not checked out" >&2
fi

if command -v shellcheck >/dev/null 2>&1; then
    scripts=(tools/dev/tg tools/dev/tests/*.sh)
    [ -f tools/dev/lint/pre-push ] && scripts+=(tools/dev/lint/pre-push)
    shellcheck -S warning "${scripts[@]}"
else
    echo "shellcheck not installed; skipping shell lint" >&2
fi
