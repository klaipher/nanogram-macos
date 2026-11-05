# How Nanogram for macOS differs from Telegram for macOS

Upstream: https://github.com/TelegramMessenger/telegram-macos (remote `telegram`), imported only as released code
(a shipped build-number bump; there are no tags) on the branch `upstream` (5c8b687e, 2026-11-01). Ours:
`nanogram/integration` (339 commits ahead of `upstream` at 2026-11-05, 569 files differ in `packages/`, `submodules/`,
`Telegram-Mac/`). Overview: [NANOGRAM.md](NANOGRAM.md). Builds: [CHANGELOG.md](CHANGELOG.md). Format:
[docs/fork-records.md](docs/fork-records.md). Last checked against `git diff upstream..HEAD --stat`: 2026-11-05.

First version, assembled from NANOGRAM.md, docs/local-development.md and the CHANGELOG. Entries marked (check) were
not re-verified against the code; correct them on the next change in that area.

### Settings layer instead of project edits
- What: our build settings are passed with `-xcconfig` (deployment target 15.0, arm64 only, release optimization,
  edition conditions); upstream's project files and manifests change only by small marked hook lines.
- Where: `nanogram/Nanogram.xcconfig`, `nanogram/editions/`, `tools/dev/tg`, `tools/dev/nanogram/buildcheck.py`.
- Upstream: no. Sync: conflicts are rare because we leave their files alone; after a merge run `tg frameworks`, `tg warnings --update`, `tg check`.

### Two editions, identity, distribution
- What: `mas` (App Store/TestFlight) and `direct` (Developer ID, notarized dmg, Sparkle 2.10.1 from klaipher/nanogram-releases),
  both sandboxed; own bundle id and team; Telegram's update, crash-bot and store endpoints removed.
- Where: `nanogram/editions/`, `tools/dev/tg testflight|release-direct`, docs/local-development.md "Identity, credentials and editions", "Sparkle".
- Upstream: no.

### Shared core from the iOS repository
- What: `submodules/telegram-ios` is klaipher/nanogram `main` (history-free), not Telegram-iOS; tgcalls, tg_owt and
  rlottie come from our forks; parity gate with the iOS repository.
- Where: `.gitmodules`, `docs/mac-core-paths.txt`, `tools/dev/parity/`, `tg core-bump`.
- Sync: core moves only through `tg core-bump`; see docs/local-development.md "The shared Telegram core".

### Strictness and guardrails
- What: `packages/Nanogram*` build in Swift 6 with warnings as errors; upstream code may only lower its warning count;
  `tg check` as pre-push gate (crash-risk lint on changed lines, warning baseline, package tests).
- Where: `nanogram/warnings-baseline.json`, `tools/dev/lint/`, `tools/dev/tests/`.

### Security hardening
- What: sandboxed direct edition and hardened Sparkle updates, sticker/emoji decoding in an isolated XPC helper (Debug
  Settings switch), Lockdown Mode policy, memory-safety C flags, optional Enhanced Security entitlements.
- Where: `packages/NanogramDecoder`, `nanogram/entitlements/`, docs/decoder-isolation.md, docs/security-audit/.
- Upstream: partly.

### Runtime efficiency
- What: the M*/H*/R* items of the runtime-efficiency specs (chat-list and chat open latency, rendering, timers,
  power governor for calls, ScreenCaptureKit screen share, VideoToolbox paths) and PerfLab to measure them. (check)
- Where: docs/superpowers/specs/2026-11-02-macos-runtime-efficiency-specs.md, 2026-11-03-macos-round2-specs.md, docs/perflab/, `packages/PerfLab`.

### Features and switches
- What: Nanogram Debug Settings window (experiments off by default except on-device voice transcription), HTML
  message widgets, iOS-style first display, accessibility work. (check)
- Where: `packages/NanogramDebug`, `packages/NanogramRuntime`, `packages/NanogramKit`, docs/accessibility/.

### Branding
- What: Nanogram name and Sphere app icon in both editions, Telegram-owned endpoints removed; a lint keeps Telegram's name and logo out.
- Where: `nanogram/NanogramAppIcons`, `tools/dev/lint/branding.py` (check).
