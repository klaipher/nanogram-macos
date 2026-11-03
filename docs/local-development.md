# Local development

Everything goes through `tools/dev/tg`. Run `tools/dev/tg help` for the command list.

| Command | Does |
|---|---|
| `tg setup`, `tg doctor` | submodules, Rust toolchain, native libraries; check prerequisites |
| `tg frameworks [--verify-only]` | build the native libraries, arm64 only |
| `tg credentials` | write `NanogramSecrets.swift` from `~/.config/telegram-ios/api-credentials.json` |
| `tg build [--release] [--clean] [--edition mas\|direct]`, `tg run` | build (and launch) the app; every build runs the checks below |
| `tg xcode [mas\|direct]` | open the workspace in Xcode with our settings |
| `tg test`, `tg lint`, `tg warnings [--update]`, `tg check` | package tests, crash-risk lint, warning baseline, the pre-push gate |
| `tg sync-upstream` | merge upstream telegram-macos (see Keeping up with upstream) |
| `tg sparkle-key [sign <archive>]` | the direct edition's EdDSA update key |
| `tg testflight [--export-only]` | archive, export and upload the App Store edition |
| `tg release-direct [--allow-dirty]` | notarized dmg, appcast and source archive for the direct edition |

The settings live in our own files (`nanogram/`, `tools/dev/`, `packages/Nanogram*`); upstream's project files
and manifests change only by small, marked hook lines.

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

Strictness follows option A of the stage 1 design: strict for our code, a ratchet for upstream's. Our packages (`packages/Nanogram*`) build in Swift 6 mode with warnings as errors. Upstream code gets the same
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
- The hook is not installed for you: the owner runs `python3 tools/dev/lint/tglint.py install-hook` once per
  clone (`--uninstall` removes it).

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
honours only with a profile (Maps, Communication Notifications for H24). `tg testflight` signs with the full set and the App Store profile.
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

The direct edition updates with Sparkle 2.10.1 (`submodules/Sparkle` = sparkle-project/Sparkle `ab7d7129`, built
from source by the workspace) from `https://github.com/klaipher/nanogram-releases/releases/latest/download/appcast.xml`
(`SFEED_URL` in `nanogram/editions/direct.xcconfig`), with EdDSA signatures only: Info.plist `SUPublicEDKey` comes
from `SPARKLE_ED_PUBLIC_KEY` in the same file, and there is no DSA key. The mas edition has no Sparkle at all.

- Upstream's `AppUpdateViewController.swift` drives Sparkle 1's private driver classes, which Sparkle 2 removed, so
  it is compiled out under `NANOGRAM`. `Telegram-Mac/updater/NanogramUpdater.swift` gives the app the same API on
  an `SPUUpdater` with its own user driver: the update button, the settings row, the update screen and crash
  recovery work unchanged; updates are checked hourly and downloaded automatically, "Update" installs and
  relaunches, quitting with a ready update installs it. NanogramKit's `UpdateFlow` folds Sparkle's callbacks into
  one state (tested).
- `direct.xcconfig` does not build Sparkle's legacy `SUUpdater` (MainMenu.xib instantiates it and would start a
  second updater with the standard UI), legacy DSA support, or the installer and downloader XPC services (for
  sandboxed apps only).
- `tools/dev/tg sparkle-key` creates the private key once at `~/.config/nanogram-macos/sparkle_ed25519` (folder
  0700, file 0600: a base64 32-byte RFC 8032 seed, the format `sign_update --ed-key-file` reads) and prints the
  public key. It never overwrites an existing key and never prints the private one. Back the key up outside this
  Mac: losing it means installed copies reject every later update.
- `tools/dev/tg sparkle-key sign <archive>` prints the appcast enclosure attributes
  (`sparkle:edSignature="…" length="…"`). `tools/dev/nanogram/sparkle.py` builds a small helper from Sparkle's
  vendored ed25519 code into `~/.cache/nanogram-macos/sparkle-ed25519/`; the key reaches it on stdin only.
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
- `tg testflight [--export-only]`: mas edition, signed with the distribution entitlements (Maps and Communication Notifications included) and the App
  Store profile, exported as a signed `.pkg`, uploaded with `xcrun altool` (xcodebuild's own upload refuses the API
  key). Before building, it checks (read-only) that the App Store Connect app has the macOS platform and stops with
  one line if not. `--export-only` signs and stops. The export asks App Store Connect for the next build number
  and has once hung there for 14 minutes; it now stops after 600 s with a "run it again" line, and the retry of the
  same archive usually finishes in about a minute.
- `tg release-direct [--allow-dirty]`: direct edition, exported with Developer ID, notarized (`notarytool`) and
  stapled, put in an APFS ULFO `.dmg` that is signed with the same Developer ID (Gatekeeper checks the disk
  image's own signature), notarized and stapled too, signed for Sparkle (`appcast.xml`, one item,
  enclosure `…/releases/download/v<version>-<build>/Nanogram-<version>-<build>.dmg`), plus
  `Nanogram-<version>-<build>-source.tar.gz` (`git archive` of the superproject and every submodule). It refuses
  uncommitted tracked changes, so the source archive matches the binary. Nothing is uploaded: the owner creates
  the GitHub release in `klaipher/nanogram-releases` with the dmg, `appcast.xml` and the source archive. When
  `notarytool`'s polling times out after Apple has the upload, it waits on that submission id instead of failing.
  Check a dmg with `xcrun stapler validate <dmg>` and
  `spctl -a -t open --context context:primary-signature -vv <dmg>` ("accepted", "Notarized Developer ID").

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

Owner rule: we sync only code Telegram has released.

- macOS: telegram-macos has no release tags, so take upstream only up to a commit that bumps the shipped build
  number (`CFBundleVersion` in `Telegram-Mac/Info.plist`, upstream's "Bump the build number to <N>" or a release
  merge such as `24295527 Merge branch 'release' into master (13.1)`). Commits after the last such bump wait for
  the next one. `tg sync-upstream` fast-forwards to the tip of `telegram/master`, so when the tip is past the last
  bump, run it with `--no-build`, then `git merge --abort` (or skip the command) and merge the bump commit by
  hand: `git merge --no-ff <bump-commit>`.
- iOS core (TelegramCore, Postbox and the rest in `submodules/telegram-ios`): only official `release-*` tags of
  Telegram-iOS, imported as snapshots (see The shared Telegram core below).

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
4. If upstream moved its `submodules/telegram-ios` pin, it says so and prints rebase commands for the old
   `nanogram-mac` branch. Do not run them: the core now lives on the history-free `mac/core` branch, and a rebase
   onto upstream's pin would pull Telegram's history into it. Update the core as described in The shared Telegram
   core below, to the iOS release the new Mac pin belongs to.
5. After a clean merge: `git submodule update --init --recursive`, the local submodule fixes (`localfixes.py`),
   `tg frameworks` (rebuilds only libraries whose stamp changed), `tg warnings --update` (a clean debug build with
   buildcheck and the edition checks; warnings that arrive with upstream code join
   `nanogram/warnings-baseline.json` and never block a sync), then `tg check`. Commit the baseline if it changed.

Rehearsed 2026-11-02 in a temporary clone: `telegram/master` had nothing new since the fork (exit "nothing to
merge"); replaying our commits onto upstream's tip minus 5 and syncing merged those 5 real upstream commits
(23 files) cleanly in about a second, and the result was byte-identical to `nanogram/stage1`; an edit on a line
upstream changed stopped with that one path listed, `MERGE_HEAD` set and nothing committed.

## The shared Telegram core

`submodules/telegram-ios` is not Telegram-iOS: it comes from our iOS fork's repository,
`https://github.com/klaipher/nanogram.git`, branch `mac/core` (`.gitmodules`). That repository holds no Telegram
history: its `upstream` branch is one snapshot commit per official Telegram-iOS release (`b46f1ec6 Import upstream
Telegram-iOS release-13.1.1`, then `0650eac5 … release-13.1.2`), each with `Upstream-Tag:` and `Upstream-Commit:`
trailers. `mac/core` is our Mac core work (the Xcode 27 MetalEngine fix, FFmpeg, the runtime H-items, …) on top of
the release-13.1.1 snapshot; the superproject pins `9f63c699`, whose tree equals the core the Mac merge built.

Rules for the core checkout:

- Commits go on the local branch `mac/core`, on top of the current pin. Never merge or rebase anything that carries
  Telegram's history into it (no `Telegram-iOS` branches, no `fetch` of tags; fetch with `--no-tags`).
- The checkout's push URL is set to `DISABLED` on purpose; the owner pushes `mac/core` to `klaipher/nanogram`.
- After a core commit, point the superproject at it (`git add submodules/telegram-ios`) and commit there.

Moving the core to a new Telegram-iOS release, without its history:

1. In the iOS repository (`~/Projects/nanogram-ios`): `tools/dev/tg sync-upstream release-<X>`. It fetches only
   that tag (`--depth 1 --no-tags`) and adds a snapshot commit with that tree to `upstream`, whose only parent is
   the previous snapshot. The iOS fork merges it into its `main` as usual.
2. In `submodules/telegram-ios`: fetch that `upstream` branch from `klaipher/nanogram` (`git fetch --no-tags
   origin upstream`), check out `mac/core` and `git merge <snapshot commit>`. The merge brings only the snapshot
   chain, so `mac/core` stays history-free. Resolve the conflicts in our core commits.
3. Build and test the Mac app on it (`tg build`, `tg check`, `tg warnings --update` if upstream warnings moved),
   then commit the new pin in the superproject.

Upstream's Mac app pins a Telegram-iOS commit, not a tag. Move the core to the newest `release-*` tag that
contains that pin (`git tag --contains <pin>` in a Telegram-iOS clone, or the first release after it), never to a
commit past the newest tag.

Other forks we pin: `submodules/tgcalls` = `klaipher/tgcalls` branch `nanogram-mac` (the iOS fork's tgcalls plus
two Mac build commits), `submodules/rlottie` = `klaipher/rlottie` branch `nanogram-mac`. Run
`git submodule sync --recursive` after `.gitmodules` URLs change; existing checkouts keep their old remotes until then.

## Debug Settings and feature switches

The app menu has **Nanogram → Debug Settings…** (`packages/NanogramDebug`, installed by `AppDelegate`). Signed in,
it opens upstream's Developer screen, which gains a **Debug Switches…** row; signed out, or with Option held, it
opens the switches window. Upstream's five-click gesture still works.

Switches are `NanogramDebugOption`s registered in `NanogramDebugSettings.shared`, stored in the app's
UserDefaults as `nanogram.debug.<id>`; an unset key means the default. Reset one or all from the window.

| Switch (`id`) | Section | Default | Effect |
|---|---|---|---|
| `display.maxFrameRate` | Display | off | caps the shared display link that drives app animations at 60 or 30 Hz |
| `media.jpegWideGamut` | Media | off | Display P3 photos are sent with their ICC profile instead of being flattened to sRGB |
| `media.systemPictureInPicture` | Media | off | gallery videos use macOS picture-in-picture instead of Telegram's floating player (web and HLS videos keep Telegram's) |
| `translation.onDeviceBeforeMacOS26` | Translation | off | on macOS 15–25, translate on device with Apple's Translation models; off uses Telegram's server. macOS 26+ always translates on device |
| `voice.onDeviceTranscription` | Voice | **on** | non-Premium accounts transcribe voice messages with Apple's on-device speech recognition, labelled on-device; off uses Telegram's server (Premium or trial) |

Add a switch by declaring a `static let debugOption = NanogramDebugOption.toggle(…)` (or `.choice`) next to the
feature, registering it in `AppDelegate.installNanogramDebugMenu()`, and reading it through
`NanogramDebugSettings.shared` (`bool`, `choice`, `observe` for live changes). Ship new behaviour behind a switch
that defaults to off until it is proven on a real account.
