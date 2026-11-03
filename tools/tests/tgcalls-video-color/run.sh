#!/bin/sh
# Q14/Q5: the tgcalls Metal renderer (TGRTCMTLI420Renderer + Resources/shaders/MetalFunctions.metal)
# converts YCbCr with the frame's matrix and range. Offscreen Metal, no account, no window.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
MACOS="$ROOT/submodules/tgcalls/tgcalls/platform/darwin/macOS"
OUT="${TMPDIR:-/tmp}/tgcalls-video-color-tests"
xcrun clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=12.0 -I"$MACOS" \
  "$HERE/VideoColorTests.mm" "$MACOS/TGRTCVideoYUVConversion.mm" \
  -framework Foundation -framework CoreVideo -framework Metal -framework Accelerate -o "$OUT"
"$OUT" "$ROOT/Resources/shaders/MetalFunctions.metal"
