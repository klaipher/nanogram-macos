# Nanogram for macOS — design

Date: 2026-11-02. Status: draft for the owner's approval.

## Intent

Nanogram already exists on iOS: a fork of Telegram-iOS tuned to be faster and lighter, delivered through TestFlight.
The owner wants the same for the Mac: a fork of Telegram's official macOS client, kept in sync with upstream,
made modern and strict, quick to build, and then measurably faster and lighter to run, without making the UI worse.

## Decisions made by the owner

- **Name and app.** It is Nanogram too, and the **same app** as iOS: App Store Connect app 6829268176, bundle
  `org.klaipher.Nanogram`, with a macOS platform added (universal purchase).
- **Two ways to distribute**, both from the same code:
  - **App Store / TestFlight edition:** sandboxed, signed for the Mac App Store, delivered through TestFlight for Mac.
  - **Direct edition:** a plain `.app` (in a `.dmg`), signed with Developer ID, notarized by Apple, updating itself with
    Sparkle.
- **Order of work.**
  1. Update everything, modernize to the latest APIs, make it as strict as possible.
  2. Optimize the build for time and disk.
  3. Optimize the app itself (CPU, memory, battery, smoothness), as on iOS.
- **Maximum optimization in release builds**, as on iOS (`-O`, whole-module, `-O3` for C/C++, LTO, dead stripping).
- **Apple Silicon only.** No x86_64 slices, no Rosetta.
- **Keep syncing with upstream** (`TelegramMessenger/telegram-macos`), like the iOS fork. Every change must survive the
  next merge.
- **Strictness, option A.** Our code and every package we modify: Swift 6 language mode, complete data-race checking,
  warnings as errors. Upstream code we have not touched: the same checks as warnings, with a tracked count that may
  only go down.

## Goals

1. A private repo that builds Nanogram for macOS from a fresh clone with one command, on Xcode 27, Apple Silicon.
2. All dependencies current (native libraries, Rust toolchains, Swift tools), and the minimum macOS raised so dead
   compatibility code can go.
3. Strict by default as defined above, with lint in the same spirit as `tglint` on iOS.
4. A build that is markedly faster and smaller than upstream's (numbers below), for both a clean checkout and day to day.
5. Signed builds delivered to TestFlight for Mac with one command, like `tg testflight` on iOS.
6. Then: measured runtime improvements (launch, chat scrolling, memory with many chats and very active channels,
   idle CPU and energy), each change backed by a before/after measurement.

## Non-goals

- Intel Macs and macOS versions older than the chosen minimum.
- Upstream's private "labs" (`third-party/twidget`, `third-party/widget-sandbox`: scripted HTML bubbles, news tab);
  they are private and never ship.
- Rewriting upstream code for style alone.

## Anti-goals (failure even if it "works")

- A sync with upstream that takes days because our changes are spread through their files.
- Any visible UI or behaviour regression traded for a benchmark number.
- Optimizations nobody measured.
- Day-to-day builds slowed down by release-only optimization.
- Leaking secrets: api_id/api_hash, signing keys and the App Store Connect key stay out of the repo and out of logs.

## Constraints

- Upstream: `github.com/TelegramMessenger/telegram-macos` (master), GPL-2.0 — our repo must stay publishable under
  the same licence; it starts private like the iOS repo.
- Fork rules from upstream's README: own api_id, not called "Telegram", not their logo. Nanogram's dark Comet icon.
- Signing: team YGTMYL879P, paid account; App Store Connect API key already used by the iOS tooling.
- Upstream's build: an Xcode workspace (`Telegram-Mac.xcworkspace`) plus ~100 local Swift packages; native libraries
  built once by `scripts/configure_frameworks.sh` (stamp-cached per library); Rust libraries via rustup; telegram-ios as
  a submodule (pinned to release-13.1.1; Nanogram iOS is on 13.1.2).
- Machine: Apple Silicon, 10 cores, 32 GB, Xcode 27.2.

## Baseline (upstream as-is, measured 2026-11-02)

| What | Result |
|---|---|
| Clone with submodules | 2.8 GB, ~12 min (fails without workarounds, see below) |
| Native libraries, universal | ~22 min, ~2.3 GB; OpenSSL 334 s, WebRTC 301 s, ffmpeg 158 s, OpenH264 101 s |
| App, clean debug build | 401 s (6.7 min), 6.1 GB DerivedData; Swift compile 1,644 s CPU across 1,072 tasks, 169 modules, C/ObjC 252 s CPU; ~2,500 warning lines (478 deprecated APIs, 52 ImplicitStrongCapture) |
| App, no-change rebuild | 34 s (nothing compiled: planning, package checks, script phases) |
| App, body edit in a screen package (ChatUI) | 35 s (3 files compiled — almost all overhead) |
| App, public API added to the hub TGUIKit | 222 s (2,845 Swift files recompiled) |
| App, clean release build (universal) | 1,057 s (17.6 min); Swift compile 3,883 s CPU, C/ObjC 619 s CPU; 11 GB DerivedData |
| Release app size | 610 MB universal (main binary 423 MB, share extension 166 MB), not stripped (plain build, not an archive) |
| Total on disk for one checkout | ~24 GB: sources 2.8 GB, native libraries 2.3 GB, debug 6.1 GB, release 11 GB |

Upstream build defects found while measuring (fix in the fork, offer upstream):

1. The private submodules make `git clone --recurse-submodules` fail, which also leaves rlottie and tlottie empty.
2. `scripts/xcode27.sh` misses `core-xprojects/mtproto-engine`, which then fails at macOS 10.13.
3. Rust bug: with `MACOSX_DEPLOYMENT_TARGET` ≥ 12.0, host proc-macro crates fail to load ("can't find crate for
   `zeroize_derive`"), Rust 1.91 and 1.96. Hits the wallet engine's Swift-bindings step under Xcode 27. Fix: unset the
   variable for host-only cargo steps.
4. `buildbox`/`.claude` contain upstream developers' local settings (broad command allow-lists); drop from the fork.

## How it is built (decided above)

### Merge-friendly by construction

- **Our settings live in our files.** Shared `.xcconfig` files (deployment target, architectures, strictness,
  optimization) that upstream's projects point to, plus one idempotent script that re-applies the pointers and package
  settings after a sync. A sync conflicts in a few lines, not in every project file.
- **Our code lives in our places.** New code goes in separate files and packages, wired in through upstream's own hook
  pattern (`<Name>Hooks`), not inlined into their files.
- **Generic fixes go upstream** as pull requests when the owner agrees, so they come back for free.
- **Sync tool**, like `tg sync-upstream` on iOS: fetch, merge, re-apply our settings, build, test, report conflicts.

### Stage 1 — update, modernize, strict

- Toolchain: Xcode 27 as the only supported Xcode; the minimum macOS raised (builder's proposal, see open items).
- Native libraries: move each to its current release where upstream's build allows, arm64 only.
- Swift tools versions and package platforms brought up to match.
- Strictness per option A; a checked-in baseline of the warning count per package that CI refuses to grow.
- Lint for our code (port the relevant `tglint` rules).
- Dead weight out: the private labs submodules and Intel-only build tools. Sparkle stays for the direct edition
  (updated to its current release) and is compiled out of the App Store edition.

### Stage 2 — build time and disk

- arm64 only (expected to roughly halve native-library time and size).
- Native libraries built once and cached by content hash outside the checkout, shared between clones and worktrees;
  a fresh clone downloads or reuses them instead of rebuilding (OpenSSL + WebRTC alone are ~10 of the 22 minutes).
- Day-to-day configuration tuned for incremental speed; release configuration carries all optimization.
- Disk: one shared DerivedData location with a size cap and a cleanup command; no per-library throwaway DerivedData.
- Measure every change against the baseline table.

### Stage 3 — the app itself

- Reuse upstream's perflab harnesses (`tools/perflab`, `docs/perflab`) where they fit, and the iOS audit method:
  measure, change, re-measure, no UI regressions.
- Scenarios: few chats; many chats and channels including very active ones; launch; long chat scrolling; media;
  idle CPU and energy; memory over time.

## Delivery

- Repo `klaipher/nanogram-macos`, private, default branch `main`, upstream as remote `upstream`.
- One entry point like `tools/dev/tg` on iOS: setup, build, run, test, lint, sync-upstream, testflight.
- TestFlight for Mac through the App Store Connect API, same key handling as iOS (`tg testflight`).
- Direct edition: `tg release-direct` builds, signs with Developer ID, notarizes, staples, makes the `.dmg`, the Sparkle
  update archive and its signed appcast entry. Sparkle's EdDSA private key stays outside the repo like the other keys.

## Calls I made (owner may override)

- **Separate repo** rather than a folder in the iOS repo.
- **telegram-ios stays decoupled at first.** The submodule follows the commit upstream Mac pins (today 13.1.1), so a Mac
  sync never waits on the iOS fork. The iOS fork is on 13.1.2 plus ~200 commits that changed TelegramCore/Postbox
  through Bazel files the Mac build does not use. Core improvements are ported to the Mac on purpose in stage 3, on a
  `nanogram-mac` branch of our telegram-ios fork, not by sharing the iOS main branch.
- **What "a package we modify" means for strictness A:** a package whose Swift or C sources we change. Settings-only
  edits (tools version, platforms, flags) do not count. In upstream hub packages (TGUIKit, ChatUI, …) we add our code
  as new files/targets, and only those are strict-as-errors; one small fix in a hub does not flip the whole hub.
  New warnings that arrive with an upstream sync go into the tracked baseline and never block a sync.
- **Deprecated APIs and old `#available` checks in upstream files** are fixed only where we already work or through
  upstream pull requests; the rest stay in the warning baseline.
- **Edition:** the TestFlight build is sandboxed (required) but built without the `APP_STORE` flag, like the iOS fork
  (`is_appstore_build=false`): no StoreKit purchases with Telegram's product IDs; Premium goes through the web flow.
  Testers are internal only, as on iOS, so no Beta App Review.
- **Both editions behave the same** apart from signing, sandbox and Sparkle: neither uses the `APP_STORE` flag.
- **Data:** the two editions share one app group so a user switching between them keeps their accounts and cache
  (builder verifies this is possible with a sandboxed and a non-sandboxed build; if not, document what moves).
- **CI** is a local gate on this Mac (`tg check` before push), like the iOS fork. **The native-library cache is
  local** and content-addressed (shared by all clones and worktrees on this Mac); no remote cache.
- Release-build baseline and numeric targets are set by the builder from the baseline table.
- **Decided while planning stage 1** (see the plan):
  - Minimum macOS **15.0**; share extension `org.klaipher.Nanogram.MacShare`; app group `YGTMYL879P.org.klaipher.Nanogram`.
  - Sparkle stays on upstream's **1.21** (it supports EdDSA) instead of Sparkle 2, because Sparkle 2 would mean
    rewriting upstream's updater file and a conflict on every sync.
  - Upstream `Package.swift` files are **not** bumped (190 manifests = constant conflicts); the deployment target,
    architecture and optimization reach them from our xcconfig and command-line settings instead.
  - Library updates inside telegram-ios (FFmpeg 9.0.2, dav1d 1.5.4) go on a small `nanogram-mac` branch of our
    telegram-ios fork: upstream Mac's pin + library-bump commits only, rebased on each sync. TDLib and mozjpeg stay.

## Open items

None blocking. Decided after review:

- **Direct edition hosting:** a separate public repo `klaipher/nanogram-releases` holding only GitHub Releases. Each
  release carries the `.dmg`, the Sparkle `appcast.xml` (the app checks
  `https://github.com/klaipher/nanogram-releases/releases/latest/download/appcast.xml`) and the matching source archive
  (GPL). The code repo stays private. Nothing is uploaded without the owner's OK for that version.
- **Stage 3 test data:** the owner's account (number kept in local, uncommitted settings only). The owner types login
  codes; measurements only read and scroll; traces stay on this Mac; reports hold numbers only, no message content.
