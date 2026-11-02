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

## Identity, credentials and editions

- Bundle `org.klaipher.Nanogram`, share extension `org.klaipher.Nanogram.MacShare`, team `YGTMYL879P`, one app
  group `YGTMYL879P.org.klaipher.Nanogram` for both editions. Xcode has no per-target xcconfig conditions, so
  `Nanogram.xcconfig` picks the bundle ID (and the edition file the entitlements) by `TARGET_NAME`; every other
  target keeps its own value. Upstream's project file is untouched.
- `tg credentials` (run by `tg build` and `tg xcode`) writes the gitignored
  `packages/ApiCredentials/Sources/ApiCredentials/NanogramSecrets.swift` (mode 0600) from
  `~/.config/telegram-ios/api-credentials.json`, only when it changes. It prints the path, never the values.
- Local builds sign with the team's Apple Development identity and no provisioning profile.

| | `mas` (TestFlight / App Store) | `direct` (Developer ID, Sparkle) |
|---|---|---|
| Build | `tg build --edition mas` | `tg build` / `tg build --edition direct` |
| Conditions | `NANOGRAM STABLE NANOGRAM_MAS` | `NANOGRAM STABLE` |
| Sandbox | yes | no (hardened runtime) |
| Sparkle | compiled out, not linked, not embedded | embedded |
| Entitlements | `nanogram/entitlements/Nanogram-MAS.entitlements` | `Nanogram-Direct.entitlements` |

The share extension is sandboxed in both (`NanogramShare.entitlements`). Every `tg build` also runs
`tools/dev/nanogram/editions.py`, which fails the build if an edition is wrong (sandbox, app group, hardened
runtime, any Sparkle symbol or load command in the mas binaries). It also keeps an APFS clone of each
edition's app in `build-output/apps/<Configuration>-<edition>/`, so both editions exist side by side for tests.
Switching edition changes a compilation condition, so the next build recompiles every Swift module.

### Two editions on one Mac

Both editions use the same bundle ID, app group and data folder (`SOURCE` from the configuration: `debug` for
Debug builds, `stable` for Release, in either edition), so switching editions keeps accounts and cache, and Debug
builds never touch a Release build's data. Only one Nanogram may run at a time: `SingleInstance.ensure()`
(NanogramKit, called first thing in `main.swift`) makes a later launch activate the running instance and quit
before it touches the shared data. Two simultaneous launches resolve to the older one (lower pid on a tie).

`NANOGRAM_LAUNCH_TESTS=1 python3 -m unittest tools/dev/tests/test_editions.py` launches the direct build, then
the mas build, and checks that the second quits within 5 s and the first stays frontmost.

Checked on 2026-11-02 without an account (code level; the owner has no Telegram account on this Mac): each Debug
edition launched alone reaches the login screen and writes to the same
`~/Library/Group Containers/YGTMYL879P.org.klaipher.Nanogram/debug/` folder, including the same pre-login account
record, so the sandboxed mas build reads what the direct build wrote. Still to do with a real account: log in on
direct, quit, open mas and see the same account and chats without logging in again.

Local signing uses no provisioning profile, so local mas builds sign with
`Nanogram-MAS-Development.entitlements`: the distribution set `Nanogram-MAS.entitlements` minus keys macOS
honours only with a profile (Maps). `tg testflight` signs with the full set and the App Store profile.
Shaders: Xcode 27 copies `.copy("*.metal")` package resources as source, and MetalEngine then traps at launch.
CallVideoLayer, DustLayer and MetalEngine compile their shaders (XCODE27.md item 3), and `buildcheck` fails any
app that ships a `.metal` file.

## Branding and Telegram-owned endpoints

- The app is `Nanogram.app/Contents/MacOS/Nanogram` (`PRODUCT_NAME` for the `Telegram` target in
  `Nanogram.xcconfig`); its Swift module stays `Telegram`, because the MainMenu.xib files name it. The app menu
  says Nanogram: `Branding.apply(to:)` (NanogramKit) renames "About/Hide/Quit Telegram" at launch instead of
  editing seven xib files; Telegram features ("Telegram Premium", "Telegram FAQ") keep their names.
  `appName` (TelegramUtils) is "Nanogram" under `NANOGRAM`, which renames window titles, alerts and About.
- Icon: the dark Comet. `Telegram-Mac/AppIcon.icon` (macOS 26+) is the iOS fork's `Nanogram.icon`; the
  pre-26 PNGs in `AppIcon.appiconset` and `TelegramShare/icon.icns` are rendered from `nanogram/icon/NanogramComet.svg`
  by `swift tools/dev/nanogram/render-mac-icon.swift` (re-run after changing the SVG).
- Under `NANOGRAM`: no crash-report bot (`macos_stable_updater_bot`; the chat-list crash card is hidden), no
  MTProto updater channel (the internal updater source is never chosen), App Store links go to our app
  (id6829268176), crash recovery's website button opens our releases page. No Telegram Sparkle feed in either
  edition: `SFEED_URL` is empty for mas and our appcast for direct.
- `tg build` fails when any file in the bundle contains a Telegram update, crash-bot or store endpoint, or when
  the app, executable, share extension or copyright still say Telegram (`tools/dev/nanogram/branding.py`).

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
