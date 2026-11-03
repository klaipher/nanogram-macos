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
compile (read from Xcode's response files) with `-flto=thin` (Xcode 27 links ThinLTO bitcode without a link flag),
and no Swift compile with runtime exclusivity checks (M17).

### Building from Xcode

```sh
tools/dev/tg xcode          # direct edition; `tg xcode mas` for the App Store edition
```

It opens the workspace with `XCODE_XCCONFIG_FILE` pointing at the edition xcconfig, which Xcode applies like
`-xcconfig`. Quit Xcode first: an Xcode that is already running keeps its old environment.

## Strictness, lint and `tg check`

Our packages (`packages/Nanogram*`) build in Swift 6 mode with warnings as errors. Upstream code gets the same
data-race checks as warnings (`-strict-concurrency=complete` in `nanogram/Nanogram.xcconfig`); TelegramCore's
manifest adds `-warnings-as-errors`, so there `-no-warnings-as-errors` keeps them warnings (Swift has no umbrella
diagnostic group to pass to `-Wwarning`).

```sh
tools/dev/tg warnings           # clean debug build, then compare with nanogram/warnings-baseline.json
tools/dev/tg warnings --update  # write the counts as the new baseline (after fixing warnings, or a sync)
tools/dev/tg lint               # SwiftLint on changed Swift lines (working tree vs HEAD; --base REV, --commits A..B)
tools/dev/tg test               # swift test: NanogramKit + changed packages that have Tests/ (or name packages)
tools/dev/tg check              # tooling tests, lint, tg warnings (its build runs buildcheck), tg test
python3 tools/dev/lint/tglint.py install-hook   # pre-push hook: lint the pushed lines, then tg check
```

- `tg warnings` counts unique `path:line:col: warning:` lines per package (`packages/<P>`,
  `submodules/telegram-ios/{submodules,third-party}/<P>`, `submodules/<P>`, else `app`). A count may only go down;
  only `tg sync-upstream` raises it. It needs a clean build because Xcode does not repeat the warnings of files it
  does not recompile.
- `tg lint` is `tools/dev/lint/tglint.py`, ported from the iOS fork (Telegram-iOS `5ac4d079`): crash-risk rules
  only (force try/cast/unwrap, Int32 timestamp overflow, narrowing conversions), changed lines only, with
  `submodules/`, `third-party/`, `core-xprojects/` and `build-output/` excluded. SwiftLint 0.65.1 is downloaded
  (checksum checked) into `~/.cache/nanogram-macos/tools` on first use.
- `tg check` and `tg test` look at the changes since the merge-base with the branch's upstream (or
  `origin/<branch>`); pass `--base REV` to choose. Every step runs and the failures are listed at the end.
  The pre-push hook skips once with `git push --no-verify`; `TG_PRE_PUSH_CHECK=0` lints only.

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

## Sparkle (direct edition)

The direct edition updates from `https://github.com/klaipher/nanogram-releases/releases/latest/download/appcast.xml`
(`SFEED_URL` in `nanogram/editions/direct.xcconfig`), with EdDSA signatures only: Info.plist `SUPublicEDKey` comes
from `SPARKLE_ED_PUBLIC_KEY` in the same file, and there is no DSA key. We stay on upstream's Sparkle 1.21 (it
checks EdDSA for `.zip` app updates; installer packages would need DSA): Sparkle 2 would rewrite upstream's
updater file. Nothing is published from here; the owner publishes releases and the appcast.

- `tools/dev/tg sparkle-key` creates the private key once at `~/.config/nanogram-macos/sparkle_ed25519` (folder
  0700, file 0600: a base64 32-byte RFC 8032 seed, the format Sparkle 2's `sign_update --ed-key-file` reads) and
  prints the public key. It never overwrites an existing key and never prints the private one. Back the key up
  outside this Mac: losing it means installed copies reject every later update.
- `tools/dev/tg sparkle-key sign <archive>` prints the appcast enclosure attributes
  (`sparkle:edSignature="…" length="…"`). Sparkle 1.21's own `generate_keys`/`sign_update` keep the key in the
  login Keychain only, so `tools/dev/nanogram/sparkle.py` builds a small helper from Sparkle's vendored ed25519
  code into `~/.cache/nanogram-macos/sparkle-ed25519/`; the key reaches it on stdin only.
- `tg build` fails a direct app without our feed or a valid `SUPublicEDKey`, and a mas app with any feed.

Xcode can reuse a cached build description without re-reading an edition xcconfig (seen here: build mas, edit
`direct.xcconfig`, build direct → the new setting missing from Info.plist). `tg build` therefore drops the cached
`XCBuildData/*.xcbuilddata` descriptions when the edition's xcconfig files changed since that edition's last build;
compiled objects stay, so the build is still incremental.

## Release builds: `tg testflight` and `tg release-direct`

Both archive the `Release` scheme with the edition xcconfig (`tools/dev/nanogram/release.py`), stamp the build
number, run `buildcheck` in release mode and the edition and branding checks on the archived app, and export with
Xcode's automatic signing through the App Store Connect API key (`~/.config/telegram-ios/asc/asc.json` +
`AuthKey_<id>.p8`, team key with the Admin role). Xcode creates the distribution certificates and profiles it needs
(`-allowProvisioningUpdates`). Output: `build-output/testflight/<build>/` and `build-output/direct/<build>/`.

- Version = upstream's `MARKETING_VERSION`; build number = `TG_BUILD_NUMBER` or `date +%Y%m%d%H%M`. Upstream's
  Info.plists carry a literal `CFBundleVersion` that upstream bumps by hand, so the build number is stamped into the
  archived app and share extension (re-signed with the same identity; export signs them again) instead of editing
  those files.
- Release-only command-line settings (`python3 -m nanogram.release settings`, also used by `tg build --release`):
  `SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off`, so the packages, not only the app target, drop runtime exclusivity checks in
  Release (runtime spec M17); Debug builds and `swift test` keep them. `buildcheck --release` fails any Swift compile
  that still checks. When `Telegram-Mac/OrderFiles/Telegram.order` exists (written by the launch order file
  generator, runtime spec M31), `NANOGRAM_ORDER_FILE` points the app's Release link at it.
- `tg testflight [--export-only]`: mas edition, signed with the distribution entitlements (Maps included) and the App
  Store profile, exported as a signed `.pkg`, uploaded with `xcrun altool` (xcodebuild's own upload refuses the API
  key). Before building, it checks (read-only) that the App Store Connect app has the macOS platform and stops with
  one line if not. `--export-only` signs and stops.
- `tg release-direct [--allow-dirty]`: direct edition, exported with Developer ID, notarized (`notarytool`) and
  stapled, put in an APFS ULFO `.dmg` that is notarized and stapled too, signed for Sparkle (`appcast.xml`, one item,
  enclosure `…/releases/download/v<version>-<build>/Nanogram-<version>-<build>.dmg`), plus
  `Nanogram-<version>-<build>-source.tar.gz` (`git archive` of the superproject and every submodule). It refuses
  uncommitted tracked changes, so the source archive matches the binary. Nothing is uploaded: the owner creates
  the GitHub release in `klaipher/nanogram-releases` with the dmg, `appcast.xml` and the source archive.

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

## Keeping up with upstream

`upstream` holds Telegram's real history (`telegram/master`, no snapshot commits), so our merges have proper
bases and a generic fix can go upstream as a pull request. Only upstream's commits ever land on `upstream`.

```sh
tools/dev/tg sync-upstream             # on main, with a clean working tree
tools/dev/tg sync-upstream --no-build  # fetch and merge only
tools/dev/tg sync-upstream --after-merge  # post-merge steps after you resolved a conflicted merge
```

What it does (`tools/dev/nanogram/sync.py`, then `tools/dev/tg`):

1. Fetches `telegram/master` (the `telegram` remote is added if missing) and fast-forwards `upstream` to it with
   a compare-and-swap `update-ref`. If `upstream` is ahead of or has diverged from `telegram/master` it stops:
   upstream rewrote history, or one of our commits landed on `upstream` — look before resetting anything.
2. `git merge upstream` into the current branch. A merge with nothing new exits quietly; uncommitted changes to
   tracked files stop it (a dirty submodule working tree, such as the local MetalEngine fix, does not).
3. On conflicts nothing is resolved or committed: the merge stays in progress, the conflicted paths are listed
   and the exit status is 1. Resolve, `git add`, `git commit`, then `tools/dev/tg sync-upstream --after-merge`;
   or `git merge --abort`. Our changes sit in our own files and small hook lines, so conflicts should be few.
4. If upstream moved its `submodules/telegram-ios` pin, it prints the commands that rebase our `nanogram-mac`
   branch of the telegram-ios fork onto the new pin (`git rebase --onto <new> <old> nanogram-mac`) and point the
   superproject at it. That rebase is done by hand: its conflicts are TelegramCore code, not tooling.
5. After a clean merge: `git submodule update --init --recursive`, the local submodule fixes (`localfixes.py`),
   `tg frameworks` (rebuilds only libraries whose stamp changed), `tg warnings --update` (a clean debug build with
   buildcheck and the edition checks; warnings that arrive with upstream code join
   `nanogram/warnings-baseline.json` and never block a sync), then `tg check`. Commit the baseline if it changed.

Rehearsed 2026-11-02 in a temporary clone: `telegram/master` had nothing new since the fork (exit "nothing to
merge"); replaying our commits onto upstream's tip minus 5 and syncing merged those 5 real upstream commits
(23 files) cleanly in about a second, and the result was byte-identical to `nanogram/stage1`; an edit on a line
upstream changed stopped with that one path listed, `MERGE_HEAD` set and nothing committed.
