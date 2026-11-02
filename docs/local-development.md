# Local development

Everything goes through `tools/dev/tg`. Run `tools/dev/tg help` for the command list.

## Prerequisites

- Apple Silicon Mac, macOS 15 or newer, **Xcode 27.x** selected (`xcode-select -p`) with the Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`).
- Homebrew: `cmake ninja meson pkg-config autoconf automake libtool rustup` (`scripts/setup_build_env.sh` installs
  them). No x86 assemblers (`nasm`, `yasm`) and no Rosetta: everything is built for arm64 only.
- `~/.config/telegram-ios/api-credentials.json` with your own `api_id`/`api_hash` (never committed).

`tools/dev/tg doctor` checks all of this and prints one line per problem with the fix.

## First build

```sh
tools/dev/tg setup    # submodules, the Rust toolchain pinned upstream, native libraries
tools/dev/tg build    # debug app, direct edition
```

## Our settings layer

Our build settings live in `nanogram/Nanogram.xcconfig` (deployment target 15.0, `arm64` only, release
optimization) and the edition files in `nanogram/editions/`. Upstream's project files and package manifests stay
untouched: `tg build` passes the edition xcconfig with `-xcconfig`, which ranks above project and target settings,
and passes the compilation conditions (`NANOGRAM`, `STABLE`, `NANOGRAM_MAS`) as command-line build settings.

Every `tg build` ends with `buildcheck` (`tools/dev/nanogram/buildcheck.py`), which reads the build log and the built
app and fails the build when any compile or link was not `arm64-apple-macos15.0`, any Mach-O in the bundle has
a non-arm64 slice, or the main binary's `minos` is not 15.0. Release builds must also show `-O3` for every C
compile (read from Xcode's response files) and `-flto=thin` at every link.

### Building from Xcode

```sh
tools/dev/tg xcode          # direct edition; `tg xcode mas` for the App Store edition
```

It opens the workspace with `XCODE_XCCONFIG_FILE` pointing at the edition xcconfig, which Xcode applies like
`-xcconfig`. Quit Xcode first: an Xcode that is already running keeps its old environment.

## Native libraries

`tg frameworks` runs upstream's `scripts/configure_frameworks.sh` with our xcconfig (`XCODE_XCCONFIG_FILE`) and
`CMAKE_POLICY_VERSION_MINIMUM=3.5`, then checks that every required output exists and is arm64 only.
`tg frameworks --verify-only` runs just the check. Per-library times go to `build-output/frameworks-timing.tsv`.

What we changed in the build scripts:

- arm64 only: the scripts that hard-coded `arm64 x86_64` (OpenH264, dav1d, tde2e, the three Rust libraries) build
  one slice; the others follow `ARCHS` from the xcconfig. The OpenSSL and mozjpeg single-architecture paths were
  broken upstream (outputs in the wrong place) and are fixed.
- The minimum macOS comes from `MACOSX_DEPLOYMENT_TARGET` (15.0 from the xcconfig) instead of hard-coded
  10.13 (OpenSSL, dav1d).
- Rust: every cargo call runs under `env -u MACOSX_DEPLOYMENT_TARGET`. With the variable at 12.0 or higher, host
  proc-macro crates fail to load ("can't find crate for `zeroize_derive`", Rust 1.91 and 1.96). The Rust objects
  then default to macOS 11.0, which links fine into a 15.0 app.
- The framework stamp records `archs=` next to `deployment=`, so changing either rebuilds the libraries.
- webrtc (tg_owt) is compiled for macOS 14.0: its desktop capturer calls `CGDisplayStream*` and
  `CGWindowListCreateImage*`, which are obsoleted (a hard error) at a 15.0 deployment target. Its objects link
  into the 15.0 app and behave exactly as upstream's (which builds them for 10.13 against the same SDK). Moving
  it to ScreenCaptureKit belongs upstream.

### Measured (2026-11-02, M-series 10 cores, Xcode 27.2, clean `core-xprojects/*/build`)

| Library | Universal (upstream) | arm64 only |
|---|---:|---:|
| OpenH264 | 101 s | 59 s |
| OpenSSL | 334 s | 197 s |
| libopus | 75 s | 43 s |
| libvpx | 85 s | 40 s |
| mozjpeg | 38 s | 21 s |
| libwebp | 29 s | 15 s |
| dav1d | 23 s | 6 s |
| ffmpeg | 158 s | 76 s |
| webrtc | 301 s | 171 s |
| tde2e | 57 s | 39 s |
| wallet-engine | 105 s | 91 s |
| mtproto-engine | 18 s | 11 s |
| tlottie | 16 s | 8 s |
| **Total** | **~1,340 s (22 min)** | **777 s (13.0 min)** |
| Disk (build dirs + Rust xcframeworks) | 2.7 GB | 2.0 GB |

Upstream's universal run also failed twice in the wallet engine (the Rust host proc-macro bug above) before a
manual workaround; the arm64 run built every library on the first try (webrtc after the 14.0 fix).
