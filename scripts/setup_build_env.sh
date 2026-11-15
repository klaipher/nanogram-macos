#!/bin/bash
#
# setup_build_env.sh — Prepare a fresh macOS machine to build the core
# frameworks via scripts/configure_frameworks.sh.
#
# It installs every dependency, sets up Rosetta, initialises the required git
# submodules, applies the source patch needed for recent Xcode/clang, and (with
# --build) runs the framework build with the correct environment.
#
# Usage:
#   sh scripts/setup_build_env.sh            # install/prepare everything
#   sh scripts/setup_build_env.sh --build    # ...then also build the frameworks
#
# Safe to re-run: every step is idempotent.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null && pwd)"

# Full Xcode (NOT just Command Line Tools) is required by configure_frameworks.sh.
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
# CMake 4.x removed compatibility with cmake_minimum_required(VERSION < 3.5),
# which some bundled sources (mozjpeg, td) still declare. This lets them configure.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This script must be run on macOS."
ARCH="$(uname -m)"
log "Detected macOS on $ARCH"

# ---------------------------------------------------------------------------
# 1. Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Make brew available on the current shell (Apple Silicon vs Intel prefix).
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
else
  log "Homebrew already installed: $(brew --version | head -1)"
fi

# ---------------------------------------------------------------------------
# 2. Build tools (Homebrew packages)
#    NOTE: meson (dav1d) is required but was missing from the original
#    INSTALL.md list. Apple Silicon only: no x86 assemblers (nasm, yasm).
# ---------------------------------------------------------------------------
BREW_PACKAGES=(
  cmake        # libwebp / mozjpeg / tde2e / webrtc
  ninja        # webrtc, dav1d
  meson        # dav1d
  zlib
  autoconf
  libtool
  automake
  pkg-config
)
log "Installing build dependencies: ${BREW_PACKAGES[*]}"
brew install "${BREW_PACKAGES[@]}"

# ---------------------------------------------------------------------------
# 4. Xcode (full IDE, with command line tools selected)
# ---------------------------------------------------------------------------
if [ -d "$XCODE_DEVELOPER_DIR" ]; then
  ACTIVE="$(xcode-select -p 2>/dev/null || true)"
  if [ "$ACTIVE" != "$XCODE_DEVELOPER_DIR" ]; then
    warn "Active developer dir is '$ACTIVE'."
    warn "configure_frameworks.sh needs full Xcode. Select it with:"
    warn "    sudo xcode-select -s \"$XCODE_DEVELOPER_DIR\""
    warn "(or run this build via DEVELOPER_DIR, which --build below does automatically)."
  fi
  # Accept the license if needed (no-op if already accepted).
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild -version >/dev/null 2>&1 \
    || warn "Xcode may require accepting its license: sudo xcodebuild -license accept"
  log "Full Xcode found at $XCODE_DEVELOPER_DIR"
else
  warn "Full Xcode not found at $XCODE_DEVELOPER_DIR."
  warn "Install it from the App Store (Command Line Tools alone are NOT enough)."
fi

# ---------------------------------------------------------------------------
# 5. Git submodules
#    The framework projects build from submodule sources (webrtc, telegram-ios
#    third-party: td/dav1d/mozjpeg/ffmpeg, etc.). Requires SSH access to
#    github.com/gitlab.com, or HTTPS rewrites configured for those hosts.
# ---------------------------------------------------------------------------
log "Initialising git submodules (recursive; tg submodules leaves out the core's duplicates of webrtc, tgcalls, twidget, widget-sandbox and QuickJS)"
if ! "$REPO_DIR/tools/dev/tg" submodules; then
  warn "Submodule init failed. If you have no SSH keys for github/gitlab, enable HTTPS rewrites:"
  warn '    git config --global url."https://github.com/".insteadOf "git@github.com:"'
  warn '    git config --global url."https://gitlab.com/".insteadOf "git@gitlab.com:"'
  warn "then re-run this script."
fi

# ---------------------------------------------------------------------------
# 6. (no source patch any more)
#    The abseil lifetimebound workaround used to edit tg_owt's abseil in place here. WebRTC is now submodules/webrtc
#    (klaipher/webrtc, never edited); core-xprojects/webrtc/webrtc/build.sh applies the fork's guarded workaround to a
#    copy (set NANOGRAM_ABSEIL_WORKAROUND=0 to try the pristine abseil).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Done / optional build
# ---------------------------------------------------------------------------
log "Environment ready."
cat <<EOF

To build the frameworks, run with full Xcode selected and the CMake policy set:

    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \\
    CMAKE_POLICY_VERSION_MINIMUM=3.5 \\
    sh "$SCRIPT_DIR/configure_frameworks.sh"

Tip: configure_frameworks.sh only (re)builds a library when its build/ dir is
absent. If a previous run failed midway it leaves a partial build/ dir and the
next run will SKIP it. To force a clean rebuild, set scripts/rebuild to "yes"
(or delete the relevant core-xprojects/*/build dirs).
EOF

if [ "${1:-}" = "--build" ]; then
  log "Building frameworks (configure_frameworks.sh)"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  sh "$SCRIPT_DIR/configure_frameworks.sh"
  log "Framework build finished."
fi
