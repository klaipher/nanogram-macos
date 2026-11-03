#!/bin/bash
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
webp="$package_root/../../core-xprojects/libwebp/build/libwebp/lib"
for library in libwebp.a libwebpdemux.a libsharpyuv.a; do
    [[ -f "$webp/$library" ]] || { echo "Missing native library: $webp/$library" >&2; exit 1; }
done
cd "$package_root"
exec swift test -Xlinker "$webp/libwebp.a" -Xlinker "$webp/libwebpdemux.a" -Xlinker "$webp/libsharpyuv.a" "$@"
