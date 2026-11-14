# Module build settings

Generated from `tools/dev/native/module-settings.json` by `tools/dev/native/module_settings.py --write`. The same file and doc live in the iOS and the Mac repo. Do not edit by hand.

## Platform-wide settings

| Setting | iOS (Bazel) | Mac (Xcode) | Kept equal? |
|---|---|---|---|
| Swift optimisation, Release | -O (swift.opt_uses_osize off) | -O; -Osize for 12 cold feature modules | yes, except the 12 listed Mac modules |
| Swift optimisation, Debug | -Onone (fastbuild/dbg) | -Onone | yes |
| Whole-module optimisation, Release | on (swift.opt_uses_wmo) | on (SWIFT_COMPILATION_MODE=wholemodule) | yes |
| C, C++, Objective-C LTO, Release | ThinLTO (-flto=thin) | ThinLTO (LLVM_LTO=YES_THIN), also -O3 | yes |
| Rust LTO, Release | fat | fat (--config in core-xprojects scripts) | yes |
| Dead-code stripping, Release | on (--features=dead_strip) | on (DEAD_CODE_STRIPPING=YES) | yes |

Why the platform differences stay:

- Mac builds 12 cold feature modules -Osize in Release to keep the binary small (NANOGRAM_SWIFT_OPT_* in nanogram/Nanogram.xcconfig); iOS builds every module -O. Both are -Onone in Debug.
- iOS links Rust with fat LTO (cross-crate); the Mac builds the Rust engines with fat LTO too (--config in the core-xprojects build scripts: tlottie via its crate profile, wallet-engine and mtproto-engine via --config). Same compiler (native-libs.json, rust). Native libraries are cached by stamp, so the link time is not paid in the dev loop.
- Both apps link Release with order files: iOS for MtProtoKit, SwiftSignalKit, Postbox, TelegramCore and TelegramUI (Telegram/BUILD, OrderFiles/*.order); the Mac through tools/dev/orderfile.py. The files are separate.

## Swift language mode per module

iOS builds 903 Swift modules (44 in Swift 6 mode); the Mac builds 263 package targets (8 in Swift 6 mode). 44 modules are built by both apps; 6 of them differ in language mode.

| Module | iOS | Mac | Status |
|---|---|---|---|
| ChatListUI | Swift 5 | Swift 5 | equal |
| DiskWriteAccounting | Swift 6 | Swift 5 | differs (allow-listed) |
| Emoji | Swift 5 | Swift 5 | equal |
| FlatBuffers | Swift 5 | Swift 5 | equal |
| FlatSerialization | Swift 5 | Swift 5 | equal |
| GalleryUI | Swift 5 | Swift 5 | equal |
| GraphCore | Swift 5 | Swift 5 | equal |
| GraphUI | Swift 5 | Swift 5 | equal |
| HLSPlayback | Swift 5 | Swift 5 | equal |
| HardenedMedia | Swift 6 | Swift 5 | differs (allow-listed) |
| InAppPurchaseManager | Swift 5 | Swift 5 | equal |
| InstantPageUI | Swift 5 | Swift 5 | equal |
| InviteLinksUI | Swift 5 | Swift 5 | equal |
| LocalAudioTranscription | Swift 5 | Swift 6 | differs (allow-listed) |
| LocationUI | Swift 5 | Swift 5 | equal |
| MTProtoRustEngine | Swift 5 | Swift 5 | equal |
| MTProtoRustEngineMapping | Swift 5 | Swift 5 | equal |
| ManagedFile | Swift 6 | Swift 5 | differs (allow-listed) |
| MediaPreuploadRegistry | Swift 6 | Swift 5 | differs (allow-listed) |
| MetalEngine | Swift 5 | Swift 5 | equal |
| MosaicLayout | Swift 5 | Swift 5 | equal |
| PasscodeCore | Swift 5 | Swift 5 | equal |
| PasscodeUI | Swift 5 | Swift 5 | equal |
| PassportUI | Swift 5 | Swift 5 | equal |
| PeerInfoUI | Swift 5 | Swift 5 | equal |
| Postbox | Swift 5 | Swift 5 | equal |
| PremiumUI | Swift 5 | Swift 5 | equal |
| RangeSet | Swift 6 | Swift 5 | differs (allow-listed) |
| Reachability | Swift 5 | Swift 5 | equal |
| RichTextEditorCore | Swift 5 | Swift 5 | equal |
| RichTextEditorUIKit | Swift 5 | Swift 5 | equal |
| RichTextEngineEditor | Swift 5 | Swift 5 | equal |
| SettingsUI | Swift 5 | Swift 5 | equal |
| StatisticsUI | Swift 5 | Swift 5 | equal |
| Svg | Swift 5 | Swift 5 | equal |
| SwiftSignalKit | Swift 5 | Swift 5 | equal |
| TelegramApi | Swift 5 | Swift 5 | equal |
| TelegramAudio | Swift 5 | Swift 5 | equal |
| TelegramCore | Swift 5 | Swift 5 | equal |
| TelegramVoip | Swift 5 | Swift 5 | equal |
| TranslateUI | Swift 5 | Swift 5 | equal |
| VP9Hardware | Swift 6 | Swift 6 | equal |
| WalletContext | Swift 5 | Swift 5 | equal |
| WebProxyTransport | Swift 5 | Swift 5 | equal |

Rule: a module's mode is raised on the side that lags, with its tests, one module at a time. A new difference fails `module_settings.py --check` until it is fixed or listed under `allowed` with a reason.
