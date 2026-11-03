# Nanogram for macOS

Nanogram is an unofficial Telegram client for macOS, forked from
[Telegram for macOS](https://github.com/TelegramMessenger/telegram-macos) and kept in sync with its released code.
It is the Mac sibling of Nanogram for iOS: the same app, tuned to build faster and run lighter.

- Apple Silicon only, macOS 15 or newer, Xcode 27.
- Identity: `org.klaipher.Nanogram` (share extension `org.klaipher.Nanogram.MacShare`), team `YGTMYL879P`, one app
  group `YGTMYL879P.org.klaipher.Nanogram`. The app is `Nanogram.app`; Telegram's update, crash-bot and store
  endpoints are removed.
- Two editions from one codebase, sharing accounts and data, one running at a time:
  - `mas`: App Store / TestFlight, sandboxed, no Sparkle (`tools/dev/tg testflight`).
  - `direct`: Developer ID, notarized dmg, Sparkle 2.10.1 updates from
    [klaipher/nanogram-releases](https://github.com/klaipher/nanogram-releases) (`tools/dev/tg release-direct`).
- Settings layer: our build settings sit in `nanogram/Nanogram.xcconfig` and `nanogram/editions/`, passed with
  `-xcconfig`; upstream's project files stay untouched apart from small hook lines.
- Strictness: our `packages/Nanogram*` build in Swift 6 with warnings as errors; upstream code may only lower its
  warning count (`nanogram/warnings-baseline.json`). `tg check` is the pre-push gate (crash-risk lint on changed
  lines, the warning baseline, package tests).
- Telegram core: `submodules/telegram-ios` comes from our iOS repository
  [klaipher/nanogram](https://github.com/klaipher/nanogram), branch `mac/core`, which carries no Telegram history.
- Upstream sync: only released code. macOS up to a shipped build-number bump (telegram-macos has no tags); the core
  from official Telegram-iOS `release-*` tags, imported as snapshots.
- Experiments ship behind switches in **Nanogram → Debug Settings…**; all but on-device voice transcription are off by default.

Developer entry point: `tools/dev/tg` and [docs/local-development.md](docs/local-development.md).
Design and plans: `docs/superpowers/specs/`, `docs/superpowers/plans/`.

Licensed under GPL-2.0 like the upstream project. Not affiliated with Telegram.
