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

## Day-to-day build speed

Most of a small incremental build is planning, not compiling: before it runs a single task, Xcode resolves the
package graph (~190 local packages), computes the target graph and loads its *build description*, the cached plan
of every task. Reusing the description costs under a second; recreating it costs 20–31 s and ~40 CPU s, and the
first build from a new environment cost 542 CPU s (2026-11-03 baseline).

**Fixed arguments and environment.** Xcode reuses a description only for the same build request in the same
environment. `tg build` therefore runs xcodebuild through `tools/dev/nanogram/xcbuild.py`, always with the same
arguments and only `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `DEVELOPER_DIR` and a fixed `PATH`; session
variables (an agent's `AI_AGENT`, `PYTHONPATH`, `SHLVL`, …) no longer reach it. After each build it prints

- `build description: reused`: the normal case;
- `build description: recreated (…)`: expected after an xcconfig or edition change, an Xcode update, a package
  graph change, extra `-- SETTING=value` arguments, or switching between `tg build`, Xcode's UI and a raw
  `xcodebuild`. Each of those keeps its own description; alternating between them recreates it every time.

Packages are not re-resolved on ordinary builds (`-disableAutomaticPackageResolution`, plus
`-skipPackagePluginValidation -skipMacroValidation`): builds stay offline and deterministic. `tg build --clean`
resolves, and so does `tg build --resolve-packages` without cleaning. A failure about `Package.resolved` prints
`hint: run tg build --clean to re-resolve packages`.

**Post-build checks.** `buildcheck` runs after every build (1–2 s). The editions check (codesign, `nm`, a full-bundle
endpoint scan: 4–9 s) runs only when the app changed: its fingerprint is the hash of the app's code signature
(CodeDirectory), which covers the executables, Info.plist, entitlements and, through CodeResources, every resource and
nested binary. File times cannot be used, because Xcode re-embeds Sparkle and re-signs the app on every build
(Sparkle's always-run script phases). A no-change build prints `editions: direct ok (unchanged since the last check)`.

**Debug settings** (`nanogram/Nanogram.xcconfig`, all `[config=Debug]`; Release keeps `-O`, whole-module, `-O3`,
ThinLTO and dead-code stripping):

| Setting | Why |
|---|---|
| `ENABLE_MODULE_VERIFIER = NO` | `VerifyModule` of Sparkle and CodeSyntax ran on every build, 2.2–8.4 s |
| `LM_SKIP_METADATA_EXTRACTION = YES` | 170 `ExtractAppIntentsMetadata` tasks, 49 s in a clean build; the app has no App Intents. Swift Build skips every App Intents metadata task for it (`AppIntentsMetadataTaskProducer`) |
| `DEBUG_INFORMATION_FORMAT = dwarf`, `SWIFT_COMPILATION_MODE = singlefile`, `GCC_OPTIMIZATION_LEVEL = 0` | Today's values, pinned against upstream drift |

`buildcheck` fails a Debug build whose log has a `VerifyModule`, `GenerateDSYMFile` or `ExtractAppIntentsMetadata` task.

**Compilation caching** (Debug only): `COMPILATION_CACHE_ENABLE_CACHING = YES` with one CAS for every checkout,
`~/.cache/nanogram-macos/CompilationCache`, capped by Xcode at 10 GB (`COMPILATION_CACHE_LIMIT_SIZE`). Adopted on
the numbers below (`build-output/stage2/task10/`, 2026-11-03, the three settings on the command line, otherwise the
same `tg build --clean`; loaded Mac, so compare CPU seconds):

| Build | Without the cache | With the cache |
|---|---|---|
| Clean Debug, empty CAS (cold) | 388 s, 2,260 CPU s (load 6→38) | 566 s, 2,348 CPU s (load 19→53, loaded): 4 % more CPU to fill the CAS |
| Clean Debug, warm CAS (`tg clean`, then the same build) | as above | 148 s, 434 CPU s (load 53→49, loaded); SwiftCompile + CompileC + SwiftEmitModule 53 s instead of 4,007 s cold; buildcheck and editions ok |
| No-change build after it (description recreated in both) | 35 s, 35.3 CPU s | 33 s, 35.5 CPU s |
| CAS size | — | 3.9 GB after the cold build, 4.0 GB after the warm and no-change builds |

The adoption rule was: warm compile CPU ≤ 50 % of cold (it is 1.3 %), a no-change build ≤ 3 CPU s more (+0.2 s) and
the CAS ≤ 10 GB. What it buys: a new worktree, `tg clean`, `tg warnings` or `tg check` (both start from a clean
build) and any build after an xcconfig change compile mostly from the CAS. The warm run used the same checkout path;
reuse of the CAS by a checkout at a different path was not measured. The 10 GB cap was never reached, so Xcode's
eviction was not observed; `tg prune` removes the CAS last, only when the cache root is over its cap.

**Considered and not done:** run-script phases with declared outputs (6 phases cost 1.2–1.4 s per build; it means
editing upstream's and Sparkle's projects), mergeable libraries and eager linking (the ~170 package modules already
link statically into one binary), changing `-jobs` (the Mac is shared; fewer jobs only slow us), `ONLY_ACTIVE_ARCH`,
explicit modules, index-while-building and dSYMs (already optimal: arm64 only, explicit modules on, index store off,
no dSYM in Debug).

Measured on 2026-11-03 (M-series, 10 cores, Xcode 27.2; the Mac was shared with other builds, load in brackets, so
compare CPU seconds):

| Build | Before stage 2 | Stage 2 |
|---|---|---|
| No-change `tg build`, description reused | 29–44 s, 36–39 CPU s (load 55–100) | 45 s, 41 CPU s for all of `tg build` (load 250→139) |
| No-change `tg build`, description recreated | 147–251 s, 77 CPU s | 137 s, 71 CPU s (load 274→250), only after a setting, environment or package change |
| First build in a different environment | 269 s, 542 CPU s | does not happen: the environment is fixed |
| Editions check on a no-change build | 4.4–8.6 s | skipped: `editions: direct ok (unchanged since the last check)` on every no-change build (Stage 2 results) |
| VerifyModule on every Debug build | 2.2–8.4 s | none: 0 `VerifyModule`, `ExtractAppIntentsMetadata` or `GenerateDSYMFile` tasks in a clean Debug build (Stage 2 results) |

The clean Debug, ChatUI, TGUIKit and Release builds were measured after both packages landed: see "Stage 2
results".

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

## Native libraries

`tg frameworks` brings the 12 native libraries plus tlottie up to date, then checks that every required output
exists and is arm64 only. `tg frameworks --verify-only` runs just the check. Per-library build times go to
`build-output/frameworks-timing.tsv`, the full log to `build-output/frameworks.log`.

Each library is one of:

- **current**: its stamp in the checkout equals the stamp of today's inputs and its outputs are present; nothing runs.
- **restored** from the shared cache `~/.cache/nanogram-macos/frameworks/<key>/` (every clone and worktree uses
  the same cache): the files are APFS clones (`cp -c`), so a restore costs no extra disk; tg then writes the
  checkout's own stamp, so upstream's script sees the library as up to date.
- **built** by upstream's `scripts/configure_frameworks.sh` with our xcconfig (`XCODE_XCCONFIG_FILE`) and
  `CMAKE_POLICY_VERSION_MINIMUM=3.5`. It runs only when at least one library is neither current nor cached (it then
  also syncs headers and rebuilds tlottie); otherwise tg syncs the headers itself and builds tlottie only if needed.
  Every library that ends up current and is not in the cache yet is stored, so the first run in any checkout seeds it.

The cache key is the sha256 of upstream's stamp (Xcode build, `deployment=`, `archs=`, the git tree of each input
plus a hash of uncommitted changes, the stamps of the libraries it depends on) with the `rust=` line replaced by
the pinned toolchain's `rustc -V` (`rust-toolchain.toml` of mtproto-engine), not whatever `cargo` is first on
`PATH`. tlottie gets the same kind of stamp (`core-xprojects/tlottie/build/.nanogram-stamp`). An entry holds only
what the app build and dependent library builds read: the required outputs, their `include/` trees, the headers
`sync-headers.sh` copies, and the two Rust xcframeworks (about 190 MB for all 13; the build directories are 1.7 GB).
The cache keeps the most recently used entries up to 3 GB (`NANOGRAM_FRAMEWORK_CACHE_MAX_GB`).

`tg frameworks --no-cache` (or `NANOGRAM_FRAMEWORK_CACHE=0`) neither reads nor writes the cache. To rebuild one
library from source, delete its `core-xprojects/<lib>/build` and run `tg frameworks --no-cache`. Upstream's script
gets `TMPDIR=~/.cache/nanogram-macos/tmp/frameworks-<pid>`, so the per-library DerivedData it creates there is
removed by `tg prune` even after an interrupted run.

Measured 2026-11-03 on the shared Mac (load average 160–230 on 10 cores from other workflows, so wall times are
upper bounds): seeding the cache from an up-to-date checkout 34 s (tlottie had no stamp yet); a run with
everything current 6 s wall, 3.6 CPU s (before: ≥ 54 s, because upstream's script always rebuilt tlottie);
restoring all 13 into a checkout with no `core-xprojects/*/build`, xcframeworks or `SharedHeaders` 20 s wall,
8 CPU s, after which `git status` was unchanged and `tg build` linked the app (buildcheck and editions ok).

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

## Disk and caches

Every build file outside the checkout lives under one cache root, `~/.cache/nanogram-macos`
(`NANOGRAM_CACHE_DIR`). `tg prune --dry-run` lists each top-level entry with its kind, size, owner checkout, last
use and what `tg prune` would do; `tg doctor` warns when the root is over its cap.

| Location | Created by | Cap | Cleaned by |
|---|---|---|---|
| `frameworks/<key>/` | `tg frameworks` (native-library cache, one entry per library and content) | 3 GB, least recently used first (`NANOGRAM_FRAMEWORK_CACHE_MAX_GB`) | `tg frameworks` after each run, `tg prune` |
| `DerivedData` (checkout `nanogram-macos`), `DerivedData-<suffix>` (checkout `nanogram-macos-<suffix>`) | `tg build`; `NANOGRAM_DERIVED_DATA` overrides | whole root | `tg clean` (`Build/`), `tg clean --all` (all of it), `tg prune` (checkout gone, unused 7 days, or over the cap) |
| `tmp/frameworks-<pid>/` | upstream's `configure_frameworks.sh` (per-library DerivedData, deleted when the script exits normally) | — | `tg prune` after 6 hours |
| `spm-*/`, `swiftpm/` | `swift build --scratch-path` runs outside the checkout | whole root | `tg prune` (unused 7 days, or over the cap) |
| `CompilationCache/` | Debug compilation caching, if enabled | whole root | `tg prune`, only when over the cap, last |
| everything else (`bin/`, `build-*.lock`, keys, tools, logs) | tools and workflows | — | never removed |

`tg prune` keeps the whole root under 40 GB (`NANOGRAM_CACHE_MAX_GB`, or `--max-gb N`): first it removes DerivedData
whose checkout no longer exists and build caches unused for 7 days, then, while still over the cap, the least
recently used SwiftPM scratch directories, then DerivedData, then the compilation cache. It never removes the current
checkout's DerivedData, anything whose checkout holds its build lock (`build-<checkout>.lock`, taken by `buildlock`),
anything used in the last 2 hours, or anything outside the cache root. `tg clean` refuses to run while this
checkout's build lock is held, so do not run it under `buildlock`.

The checkout itself holds only the native libraries' outputs (`core-xprojects/*/build`, the two Rust xcframeworks,
the generated `SharedHeaders`); after a restore from the cache they are APFS clones of the cache entries.

Measured 2026-11-03 (shared Mac; load average in brackets, 10 cores, so wall times are upper bounds and CPU
seconds are the comparable number):

| What | Result |
|---|---|
| Native libraries, `--no-cache`, from no build directories | 1,522 s wall, 1,698 user + 460 sys CPU s (load 147→58); stage 1 measured 777 s on an idle Mac. Per library: OpenH264 41, OpenSSL 270, libopus 114, libvpx 197, mozjpeg 19, libwebp 81, dav1d 16, ffmpeg 194, webrtc 363, tde2e 103, wallet-engine 63, mtproto-engine 21, tlottie 17 s |
| Native libraries restored from a warm cache, from no build directories, xcframeworks or `SharedHeaders` | 20 s wall, 8 CPU s (load 168) |
| Native libraries, everything current | 3–6 s wall (load 58–189) |
| Build directories + Rust xcframeworks after a full build | 1.65 GB in the checkout |
| One full cache set (13 entries) | 192 MB; a restored checkout's copies are clones of it |
| `DerivedData-stage2` after a clean debug build | 6.1 GB (stage 2 baseline; Build 4.1, ModuleCache 1.5, SDK explicit modules 0.5) |
| `tg prune --dry-run` on this Mac | 65.0 GB under the cache root (cap 40): four DerivedData (27.2 GB, all kept: current or a build running), 12 SwiftPM scratch directories (34.6 GB; 10 of them, 22.0 GB, would go over the cap; 2 used in the last 2 hours kept), `tgios-work` and other files kept |

Owner action: exclude `~/.cache/nanogram-macos` and the checkouts from ESET Endpoint Security's on-access scanning;
its `scand` process was among the top CPU users during every measured build.

## Stage 2 results

Measured 2026-11-03 on `nanogram/stage2` with both packages (`build-output/stage2/integrate/`: `*.run.txt` wall time
and load, `*.time.txt` `/usr/bin/time -l`, `*.log` xcodebuild with `-showBuildTimingSummary`). Every build ran
through `tg` under `buildlock`, one after another, on the shared Mac (M-series, 10 cores, Xcode 27.2). Load average
in brackets (1-minute value before → after); wall times are upper bounds, CPU seconds (user + sys of the whole
command) are the comparable number. Free disk 16–73 GB during the runs.

| What | Upstream (2026-11-02) | Stage 2 |
|---|---|---|
| Native libraries, empty `core-xprojects/*/build`, no Rust xcframeworks, empty cache | ~22 min universal, 2.3 GB (stage 1 arm64: 777 s on an idle Mac) | 958 s, 1,583 user + 390 sys CPU s (load 73→47, loaded); OpenSSL 269, webrtc 220, ffmpeg 93, libopus 73, OpenH264 65, libvpx 62, tde2e 57, wallet-engine 42, libwebp 23, mtproto-engine 13, mozjpeg 9, tlottie 9, dav1d 7 s; build dirs + xcframeworks 1.65 GB, cache 192 MB |
| Native libraries, fresh worktree: no build dirs or xcframeworks, warm cache | same as above | 7.6 s, 4.8 CPU s (load 46, loaded): 13 restored |
| Native libraries, everything current | upstream's script always rebuilt tlottie (≥ 54 s) | 2.4 s, 2.4 CPU s |
| Clean Debug `tg build --clean` from an empty DerivedData | 401 s, 6.1 GB | 388 s, 1,956 + 304 CPU s (load 6→38, loaded at the end); SwiftCompile 1,936 s (1,077 tasks), CompileC 311 s (514), SwiftDriver 300 s, SwiftEmitModule 216 s; 0 VerifyModule / ExtractAppIntentsMetadata / GenerateDSYMFile; DerivedData 5.7 GB (Build 3.7, ModuleCache 1.5) |
| No-change `tg build` | 34 s | 22 s, 17 + 3 CPU s (load 16→13), description reused, editions check skipped. The first two builds after `--clean` recreated the description: 35 s / 29 s, 35 / 32 CPU s |
| ChatUI body edit (`BigEmojiMessage.swift`, a string literal in a function) | 35 s | 32 s, 29 + 5 CPU s (load 13→10): 1 Swift task, 4 links, re-sign, editions check; reverting it 33 s |
| TGUIKit public API added (`public func` in `AnimationStyle.swift`) | 222 s | 265 s, 765 + 136 CPU s (load 14→12): 819 Swift compile tasks, the same count as upstream's log; reverting it 428 s, 820 + 143 CPU s (load 15→54, loaded) |
| Clean Release `tg build --release --clean` | 1,057 s universal, 11 GB | 1,507 s, 2,757 + 241 CPU s (load 20→128, 200 at the end: loaded); SwiftCompile 3,871 s (170 whole-module tasks), CompileC 326 s, GenerateDSYMFile 73 s; Build 3.4 GB, the module cache grew 1.5 → 3.0 GB (Debug and Release); **`buildcheck` failed**, see below |
| Release app | 610 MB universal (main 423 MB, share extension 166 MB) | 308 MB arm64 (main 215 MB, share extension 83 MB, Sparkle 1.3 MB, resources 19 MB) |
| Disk for one checkout | ~24 GB | ~10 GB: sources 2.5 GB (git objects live in the main clone), native libraries 192 MB in the shared cache (the checkout's 188 MB are clones of it), DerivedData 7.3 GB with Debug and Release (5.7 GB Debug only); `build-output` logs and app copies 1.1 GB on top |

`tools/dev/tests/run.sh` (244 tests, 9 skipped) and `tg check` (732 s, including a clean Debug build from an empty
DerivedData) passed before the measurements.

The ChatUI edits were measured again by comment and by string literal (`build-output/stage2/after/`, 12:27–12:46).
These runs are **loaded** (load 26–179 on 10 cores; the clean Debug run of that series waited 40 min for the build
lock and was replaced by a 740 s rebuild at load 119→180), so they only confirm the counts, not the times:

| Edit (`BigEmojiMessage.swift`) | Wall, CPU s (load) | Description | Work |
|---|---|---|---|
| Trailing comment, first run | 128 s, 72 CPU s (179→143, loaded) | recreated | 1 Swift task; binary unchanged, editions check skipped |
| Reverting it | 76 s, 61 CPU s (143→103, loaded) | recreated | 1 Swift task |
| Trailing comment, second run | 56 s, 43 CPU s (103→100, loaded) | reused | 1 Swift task, editions check skipped |
| Reverting it | 35 s, 32 CPU s (93→58, loaded) | reused | 1 Swift task |
| String literal | 43 s, 41 CPU s (58→39, loaded) | reused | 1 Swift task, link, re-sign, editions check |
| Reverting it | 34 s, 36 CPU s (37→26, loaded) | reused | 1 Swift task, link, re-sign, editions check |

A comment-only edit leaves the binary and its code signature unchanged, so the editions check is skipped; a string
literal changes the binary and the check runs. The unloaded number is the one above: 32 s, 34 CPU s.

**Release `buildcheck` fails.** 170 of the 225 links in the Release log have no `-flto=thin`: the app, the share
extension and the Swift-only package targets. Xcode adds `-flto=thin` (plus `-cache_path_lto`) to a link only through
`Clang.xcspec`'s `AdditionalLinkerArgs`, i.e. for targets that compile C (55 links have it, e.g. sqlcipher, libwebp,
Sparkle), and the Swift compiles get no `-lto=llvm-thin`, so `LLVM_LTO = YES_THIN` gives ThinLTO to the C code only.
The build itself succeeded; the editions check did not run. This is the stage 1 settings layer and check, first
exercised here by a real Release build: either the check accepts links of Swift-only targets, or the Swift code gets
ThinLTO (`-lto=llvm-thin` in `OTHER_SWIFT_FLAGS` for Release, a size and time trade-off to measure first).

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
