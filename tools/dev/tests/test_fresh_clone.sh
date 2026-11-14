#!/bin/bash
# A fresh `git clone --recurse-submodules` of our repo must succeed and leave every
# public submodule populated. NANOGRAM_FULL=1 also runs `tg setup && tg build`.
set -euo pipefail

REPO_URL="${NANOGRAM_REPO_URL:-https://github.com/klaipher/nanogram-macos.git}"
BRANCH="${NANOGRAM_BRANCH:-main}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

git clone --quiet --recurse-submodules --jobs 8 --branch "$BRANCH" "$REPO_URL" "$WORK/repo" \
    || fail "git clone --recurse-submodules failed"

cd "$WORK/repo"
[ -s submodules/tlottie/Cargo.toml ] || fail "submodules/tlottie/Cargo.toml missing"
[ -s submodules/telegram-ios/submodules/TelegramCore/Package.swift ] || fail "telegram-ios not populated"
[ -s third-party/twidget/Package.swift ] || fail "third-party/twidget (klaipher/twidget nanogram) not populated"
[ -s third-party/widget-sandbox/Package.swift ] || fail "third-party/widget-sandbox (klaipher/widget-sandbox nanogram) not populated"
[ -s submodules/telegram-ios/shared/shared-libraries.json ] || fail "the core's shared/ submodule not populated"

if [ "${NANOGRAM_FULL:-0}" = "1" ]; then
    export NANOGRAM_CACHE_DIR="$WORK/cache"
    tools/dev/tg setup || fail "tg setup failed"
    tools/dev/tg build || fail "tg build failed"
fi

echo "PASS: fresh clone"
