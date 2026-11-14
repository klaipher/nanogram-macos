# AGENTS.md

This file provides guidance to coding agents working with code in this repository.


## Hard rules

- Marketing version follows upstream; only the build number changes. Never fetch upstream tags/branches into this repository by hand (`tg sync-upstream` only, released code only).
- A fix in shared code (the core, tgcalls, webrtc and every library in `submodules/telegram-ios/shared/shared-libraries.json`) lands in the single source (an official pin or ONE klaipher fork branch), then all three pins (iOS, Mac, Android) move the same day: iOS `main` first, then `tools/dev/tg core-bump` here. No vendored copies, no per-platform branches; `tools/dev/native/check_shared.py` (a wrapper around the core's `shared/`) runs in the pre-push hook.
- Never `--no-verify`. Never read `~/.config/telegram-ios`, keychains or signing material. No scheduled jobs.
- Agents do not build or launch the app (`tg build/check/test/warnings`, `xcodebuild`, `swift build/test`); one combined build at the end of a round. Pure-Python tests are fine.
- Work in your own worktree and branch under `~/Projects/wt/`, never in the main checkout.
- Mac releases go to the GitHub release (`tg release-direct`); Mac TestFlight only on request.

## Development pipeline (full text: [submodules/telegram-ios/shared/development-pipeline.md](submodules/telegram-ios/shared/development-pipeline.md))

1. Research and review in parallel lenses, with evidence. 2. Adversarial verification of every finding.
3. Fix confirmed findings on branches, tests first. 4. No builds by agents. 5. One combined build per platform at the end.
6. Fix what the build shows. 7. Push through the hooks. 8. Report: findings with evidence, decisions with trade-offs, open questions.

## Change records (see [docs/fork-records.md](docs/fork-records.md))

Every change that alters behaviour updates `CHANGELOG.md` (`## Unreleased`: what and how, with commit) and, when it changes how we differ from upstream, `NANOGRAM-CHANGES.md`. A fork submodule change also needs the fork's own records. Public notes (releases repo, appcast) are short and say which part got better, never how. The pre-push hook warns when a push of product code touches neither file.

## Disk and worktrees

DerivedData, SwiftPM scratch (`~/.cache/nanogram-macos/spm-*`) and the compilation cache are per checkout. `git worktree remove` finished worktrees, then `tools/dev/tg cache-cleanup`. Details in the pipeline doc and `docs/cache-cleanup.md`.

## Commands and docs

Everything goes through `tools/dev/tg` (`tg help`); the guide is [docs/local-development.md](docs/local-development.md); all documents are indexed in [docs/README.md](docs/README.md).

## Code Style

### Comments
- Do NOT add comments to code except for special markers like `//TODOLANG` (for strings that need localization) or similar task markers
- Code should be self-documenting through clear naming


## Useful Documents
Read the matching document before starting the task.

| Task | Document |
|---|---|
| Creating a new screen or controller | [docs/swift/TemplateController/README.md](docs/swift/TemplateController/README.md), template in [TemplateController.swift](docs/swift/TemplateController/TemplateController.swift) |
| Checking whether a feature exists on iOS, on the Mac or in official Telegram | [submodules/telegram-ios/shared/feature-parity.md](submodules/telegram-ios/shared/feature-parity.md) (one copy for iOS, Mac and Android in the core's `shared/` submodule, klaipher/nanogram-deps; update the row there when a feature lands) |
| HLS (adaptive) video playback | [packages/HLSPlayback/README.md](packages/HLSPlayback/README.md) |


## Architecture Overview

### Project Structure
- **Telegram-Mac/** - Thin app target: launch and hook installation (`app/`), the concrete `AccountContext` (`account/`), hook installers and bridges (`packages-integration/`), strings (`en.lproj/Localizable.strings`)
- **packages/** - Swift Package Manager modules; almost every feature and UI lives here
- **packages/TGUIKit/** - UI Library
- **TelegramShare/** - Share extension
- **submodules/** - Core libraries and telegram-ios shared code (TelegramCore, Postbox, SSignalKit)
- **core-xprojects/** - Native framework build projects (OpenH264, FFmpeg, WebRTC, etc.)
- **docs/** - Guides and code templates, not part of any target

### Main Modules
Only the modules you will touch most. Find anything else with `grep -rn "func NameController" packages`.

| Module | Use it for |
|---|---|
| `TGUIKit` | Views, `TableView`, `ViewController`, modals, `Window` |
| `TelegramContext` | `AccountContextProtocol`; packages take `any AccountContextProtocol` |
| `Localization` | `strings()`, generated from `Telegram-Mac/en.lproj/Localizable.strings` by `tools/swiftgen.sh` |
| `TelegramTheme` | The `theme` global, `TelegramPresentationTheme`, `deliverOnPrepareQueue` |
| `ColorPalette`, `TelegramIconsTheme` | Palette colors and `theme.icons` |
| `InAppSettings` | App preferences stored in Postbox, `FastSettings` |
| `TelegramUtils` | Telegram helpers shared by many features (formatting, peer status text, `bestWindow`) |
| `FoundationUtils`, `Strings`, `DateUtils`, `ObjcUtils` | Pure helpers with no Telegram UI |
| `TelegramMedia`, `TelegramMediaUtils`, `TelegramMediaResources` | Players, media fetching and saving, media resources |
| `LocalAnimations` | Bundled Lottie animations |
| `InputDataUI` | `InputDataController` list and form screens, `FeatureNavigationHooks` |
| `GeneralRows` | `GeneralRowItem` and the common table rows |
| `AlertsUI` | `alert`, `verifyAlert` |
| `AvatarUI`, `ShortPeerRow`, `SelectPeersUI`, `InputView`, `InlineStickerLayer` | Avatars, peer rows, peer pickers, text input, inline custom emoji |
| `ChatModeTypes`, `ChatHistoryModel`, `MessageUtils`, `MessageTextUtils` | Chat and message model shared by several screens |
| `ChatUI`, `ChatListUI`, `SettingsUI`, `PeerInfoUI` | The big screens: chat, chat list, settings, peer info |
| `PremiumUI`, `StarsUI`, `StoriesUI`, `CallsUI`, `GalleryUI`, `WalletUI`, ... | One `*UI` package per feature screen |

### Adding a Feature
- Add the screen to the package it belongs to; create a new package only for a standalone multi-file feature, copying `packages/GroupsInCommonUI/Package.swift`, then add it to the `Packages` group and link it to the `Telegram` target
- Build screens by following [docs/swift/TemplateController](docs/swift/TemplateController/README.md)
- App-only code (`AccountContext`, app singletons) is reached through a `<Name>Hooks` struct in the package, installed from `Telegram-Mac/packages-integration/hooks/` and `app/main.swift`
- Other features' screens are opened through `FeatureNavigationHooks`, never imported

### Dependencies
- Declare only modules whose symbols you actually use; never add dependencies "just in case"
- No screen package may depend on another screen package; existing ones are debt
- Keep feature code out of hubs (`TGUIKit`, `TelegramTheme`, `TelegramContext`, `Localization`, `TelegramUtils`, `InAppSettings`, `GeneralRows`, `InputDataUI`); a hub API change recompiles ~90 packages
- `*Share` products are for the share extension only

### Moving Code into Packages
- Packages enforce runtime exclusivity (the app has it off), so `inout` access conflicts can trap after a move
- `BETA`/`STABLE`/`ALPHA`/`APP_STORE` are false in packages in Xcode UI builds; only `buildbox/build-mac.sh` sets them
- App extensions like `Peer.isForum` and `Peer.displayLetters` shadow TelegramCore members; in a package call them through hooks
