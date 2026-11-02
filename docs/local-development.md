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

