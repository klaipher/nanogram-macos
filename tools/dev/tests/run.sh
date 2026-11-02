#!/bin/bash
# Runs the tooling test suites: Python unittest plus shellcheck on the shell entry points.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

python3 -m unittest discover -s tools/dev/tests "$@"

if command -v shellcheck >/dev/null 2>&1; then
    scripts=(tools/dev/tg tools/dev/tests/*.sh)
    [ -f tools/dev/lint/pre-push ] && scripts+=(tools/dev/lint/pre-push)
    shellcheck -S warning "${scripts[@]}"
else
    echo "shellcheck not installed; skipping shell lint" >&2
fi
