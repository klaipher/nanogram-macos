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
- What: `submodules/telegram-ios` is klaipher/nanogram `main` (history-free), not Telegram-iOS; tgcalls and webrtc come
  from our forks (one branch each, the same commits as iOS and Android); parity gate with the iOS repository.
- Where: `.gitmodules`, `docs/mac-core-paths.txt`, `tools/dev/parity/`, `tg core-bump`.
- tgcalls: `nanogram-shared` carries Telegram 13.2's engine changes (SCTP timer overrides, reflector candidate-IP default, `removeOutgoingChannel` fix); the 14.0.0 engine is not part of the Mac build, so its 13.2 changes only reach the iOS app. Records: the fork's `NANOGRAM-CHANGES.md`. Pin 73cc1f8d adds the `ios/` exclude to `Package.swift` (the iOS bridge lives in the same tree).
- Sync: core moves only through `tg core-bump`; see docs/local-development.md "The shared Telegram core".

### One source per shared library (iOS, Mac, Android)
- Checks: the pre-push hook checks every pushed commit with `check_shared --ref` and refuses a stale core checkout; `build.sh` of webrtc preflights crc32c; the tgcalls `.gitmodules` entry is shallow.
- What: every shared native library has one source and one commit, listed in `shared/shared-libraries.json` of klaipher/nanogram-deps (the core's `shared/` submodule, reached at `submodules/telegram-ios/shared/`). The Mac builds the core's copies (via-ios-core) and has no vendored copy of them. Parity, the manifest check, the cache policy, the feature-parity and development-pipeline documents are no longer copied into this repository: `tools/dev/parity/parity.py` and `tools/dev/native/check_shared.py` are wrappers, and the pre-push hook runs `check_shared.py --side mac`.
- Where: `tools/dev/parity/`, `tools/dev/native/`, `tools/dev/cachegc/cachegc.py`, `docs/mac-core-paths.txt` (iOS file, byte for byte), `tools/dev/native/native-libs.json`.
- Highlighter: `CodeSyntax` compiles the fork's C++ core and its one `apple/Syntaxer.{h,mm}` (the Mac keeps no copy); OpenH264 is built from the core's klaipher/openh264 `nanogram` submodule (v2.7.0 plus H.264 level 6.0-6.2 and the sprite mode, off by default); rnnoise is the SwiftPM package in the core.
- Calls and WebRTC: `submodules/webrtc` = klaipher/webrtc `nanogram` (the tg_owt CMake build now lives at that tree's root; the Mac builds it from `build/src`, libyuv from the core, abseil with the fork's guarded lifetimebound workaround) and `submodules/tgcalls` is the commit iOS pins; the old klaipher/tg_owt is archived.
- Shared Swift/ObjC sources: the Mac packages HLSPlayback, SwiftMath, VP9Hardware, RingBuffer, EDSunriseSet, QrStudioUI (logic files), SceneEffects (diamond, shaders, release policy) and the card logic of Stripe are symlinks (behaviour change, as on iOS: expired Visa, MasterCard and Other cards pass client-side expiry validation, and `validationStateForCard:` marks both expiry fields valid when either is invalid; BIN ranges 8600/9860 become Other instead of Unknown; owner to approve) into `submodules/telegram-ios` (iOS-reconciled files); AppKit views, the sticker reader, `LiquidGlassShapesTypes` and Svg stay per app.
- Widgets: `third-party/twidget` and `third-party/widget-sandbox` are klaipher/twidget and klaipher/widget-sandbox (`nanogram`), the same commits iOS and Android pin; QuickJS is klaipher/quickjs through the widget-sandbox fork (no local pin any more).
- Where (libraries): `submodules/CodeSyntax/CodeSyntax/CodeSyntax.xcodeproj`, `core-xprojects/OpenH264/OpenH264/build.sh`, `scripts/configure_frameworks.sh`, `Telegram.xcodeproj` (grammars.dat path), `.gitmodules` (twidget, widget-sandbox), `tools/dev/nanogram/localfixes.py`.
- Upstream: no.
- Sync: after a core bump, `docs/mac-core-paths.txt` is re-copied from the core; `native-libs.json` stays identical to the iOS repository.

### Native sources shared with the iOS core, animated stickers on tlottie only
- What: libwebp is built from the core's `third-party/webp/libwebp` (no vendored tarball, no stale `build.sh`); libjpeg-turbo 3.2.1 is downloaded by URL and sha256 in `Mozjpeg/build.sh` (no vendored tarball); flatc 25.12.19 (the iOS pin) is built on first use by `scripts/prepare-flat-serialization.py` from the sha256-checked release archive (no committed binary); the dead OpenSSL `patch-conf.diff` and the stale `submodules/openssl` argument are gone. These files are upstream Telegram for macOS's own (`scripts/flatc` 24.12.23, `core-xprojects/libwebp/libwebp/build.sh`, `core-xprojects/openssl/OpenSSLEncryption/patch-conf.diff`, the libwebp and libjpeg-turbo tarballs), and we delete or replace them on purpose. flatc is cached per user in `~/Library/Caches/nanogram/flatc/25.12.19`; the first run needs network and cmake.
- Animated stickers render with tlottie always (as Telegram for macOS 13.2). There is no rlottie fallback, force switch or kill switch: the `macos_killswitch_disable_tlottie` server flag is ignored. Behaviour is the tlottie path of every release since 13.2.
- Where: `core-xprojects/{libwebp,Mozjpeg,openssl}`, `scripts/prepare-flat-serialization.py`, `scripts/framework-inputs.sh`, `tools/dev/native/native-libs.json`, docs/shared/w1-mac-native-sources.md.
- Upstream: yes, they are upstream's files.
- Sync: on upstream merges keep `scripts/flatc`, `libwebp/build.sh` and `patch-conf.diff` deleted (modify/delete conflicts resolve to delete), keep our `Mozjpeg/build.sh` and OpenSSL pbxproj shellScript edits, and compare any upstream flatc bump with `FLATBUFFERS_VERSION` in `prepare-flat-serialization.py`.

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
- Also (round 3): closed chats are released (the history pipeline no longer holds `ChatController`; a live-controller counter and `chatControllerCreated`/`chatControllerDeinit` signposts prove it), `coalesceOnMain` at the chat header and the main window status, the first history transition prepared off main, the disk-write ledger rate-limited, and the shared signpost names emitted from the Mac call sites. Upstream has none of these. Where: `packages/ChatUI` (`ChatController`, `ChatControllerLifetime`, `ChatHistoryPreparePolicy`), `packages/TGUIKit` (`PerformanceSignposts`, `Window`, `Modal`, `TableView`), `packages/NanogramRuntime/DiskWriteReports.swift`. Round 3b adds: VP9 hardware sessions given back 2 s after the app is hidden and resumed with a replay, the 60 Hz player update on the display link, an LRU of Lottie cache maps with the map saved off the releasing thread, presence timers suspended for chats off the stack, and live tracking-area/observer counters (off in release unless `nanogram.liveObjectCounters` is set).

### Features and switches
- What: Nanogram Debug Settings window (experiments off by default except on-device voice transcription), HTML
  message widgets, iOS-style first display, accessibility work. (check)
- Where: `packages/NanogramDebug`, `packages/NanogramRuntime`, `packages/NanogramKit`, docs/accessibility/.
- Call experiments (hardware decode, hardware crop, native decode format, screen-share hardware encoder, thermal video limits,
  10-video cap in group calls, RNNoise-only group noise suppression) default to on in the Mac app; each can still be switched
  off in the Debug Settings window. Upstream has none of these. `packages/CallVideoLayer`.

### Branding
- What: Nanogram name and Sphere app icon in both editions, Telegram-owned endpoints removed; a lint keeps Telegram's name and logo out.
- Where: `nanogram/NanogramAppIcons`, `tools/dev/lint/branding.py` (check).

### Upstream bug fixes
- What: protected images (channels with saving and copying turned off) keep their protection layer at the image view's size when the view is resized with `setFrameSize`; upstream left it 0×0, so those images showed grey.
- Where: `packages/TGUIKit/Sources/TransformImageView.swift` (`setFrameSize`).
- Upstream: no (upstream bug in 13.1.0; could be sent as is).

### Early upstream picks
- What: 15 telegram-macos master commits taken before their release (#117, #188, #205, #211, #212, #214, #216, #223,
  #225, #231, #233, #235, #237, #238, #239), and our fixes on top: code-block copy refused for protected layouts in the
  chat layer engine, IME keys never reach window key handlers, wider Quick Look warning list, the peer-to-peer call
  rule is sent to the server, DevicesContext removes its listeners on `devicesQueue`.
- Why: content protection, privacy and data-safety fixes worth having before upstream's next release.
- Where: branch `upstream-picks` (b300aee8..5907a07b); review `nanogram-macos-recon/2026-11-05-upstream-picks-review.md`.
- Upstream: the picks are upstream's; our five fixes could be sent as is.
- Sync: at the next release merge the picks resolve as already applied (`git cherry` shows them); keep our follow-ups
  (`Window.keyBelongsToInputMethod`, `TextViewLayout.copyableBlockQuoteText`, the `.voiceCallsP2P` request) and re-run
  `tools/tests/{privacy-page-save,translate-copy-restriction,file-preview-warning}` and `TGUIKitTests`.

### Guarded HLS playlist parsing, bounded HLS fetches, chat export offline fallback
- What: HLS playlist byte ranges use overflow-checked arithmetic and throw instead of trapping; every segment and init range
  must lie inside the file; bandwidth and level dimensions are clamped; playlist and range fetches stop after 5 retries;
  chat export decides copy protection from cached data when the refresh fails or times out (protected or unknown stays refused).
- Why: a hostile playlist crashed the app, also during chat-scroll preload; unsatisfiable ranges refetched forever; export needed the network.
- Where: `submodules/telegram-ios/submodules/HLSPlayback/Sources/{HLSMediaPlaylist,HLSLevel}.swift` (the Mac package symlinks it), `packages/TelegramMedia/Sources/{HLSVideoContent,HLSVideoNativeContentView}.swift`, `HLSNative/HLSNativePlaylistLoader.swift`, `packages/ChatExportUI/Sources/ChatExportUI/ChatExportManager.swift`, key `ChatExport.Unverified`.
- Upstream: the HLS files are upstream's 13.2 code with small edits; export gate is ours.
- Sync: keep the `rangesFit`, `addingReportingOverflow` and `hlsBoundedRetry` call sites when upstream's lines change; add the key to the generated `Localizable.swift` on the next `tg` localization run.

### Message widgets off by default
- What: one switch (`MessageWidgetsSwitch`, `UserDefaults.standard` key `nanogram.messageWidgets.enabled.2`, default off, Developer screen row "Message widgets") gates every path that can run a widget: chat rows (`TelegramMediaWidget`, local `htmlBubbleState`, bot HTML documents and their auto-fetch), inline-result widget previews, the mini-app share preview, the full-screen page, demo chats, `tg://voxelclash`, the multiplayer demo client, and the engine, validator and shell prewarm in `HTMLBubbleState`. Off, a widget message is an upstream "unsupported" or plain text row. The widget engine service fallback name is now `org.klaipher.Nanogram.WidgetEngine` (xcconfig `NANOGRAM_BUNDLE_ID_WidgetEngineService`).
- Why: widgets run a bot's script with no tap; a public report shows native code execution through the engine and Telegram's fixes do not close it.
- Where: `packages/HTMLBubbles/Sources/HTMLBubbles/MessageWidgetsSwitch.swift` (switch and pure decisions), `HTMLBubbleState.swift`, `HTMLBubblePage.swift`, `HTMLDemoChatContents.swift`; `packages/ChatUI/Sources/ChatUI/{ChatRowItem,ChatHTMLRowItem,ChatHTMLDocumentRows,ContextListRowItem,InputContextHelper,ChatNavigationLab,ChatController}.swift`; `packages/ChatListUI` (`ChatListController`, `PeersListController`); `packages/SettingsUI` (`DeveloperHooks`, `DeveloperViewController`); `Telegram-Mac/app/AppDelegate.swift`, `Telegram-Mac/packages-integration/hooks/{BrowserHooksInstall,ChatUIHooksInstall,DeveloperHooksInstall,WidgetEngineInstall}.swift`, `nanogram/Nanogram.xcconfig`.
- Upstream: all edits are one-line guards or small additions around upstream code; the switch file is ours. `third-party/widget-sandbox` is untouched (its `SandboxEngine.make` runs the engine in process when no remote factory is set, so our side never reaches it while the switch is off).
- Sync: after a merge grep for `MessageWidgetsSwitch` and keep each guard; a new upstream path that builds `ChatHTMLRowItem`, `HTMLBubbleState` or a `WidgetBubble` needs one too.

### Launch at login (on by default)
- What: the app registers itself as a login item once (`SMAppService.mainApp`, sandbox-safe) on the first launch after the update; Settings > General has a switch "Launch at login". Off unregisters and nothing re-registers afterwards; a login item the user removed in System Settings is not restored. The row subtitle adds the Login Items hint when macOS reports "requires approval". Keys `nanogram.launchAtLogin.enabled` and `nanogram.launchAtLogin.defaultApplied`. Debug builds skip it.
- Why: iOS and Mac share the bundle id, so iPhone Mirroring stops forwarding the iPhone's notifications once the Mac app is installed, and the Mac app (no push) shows banners only while running.
- Where: `packages/NanogramKit/Sources/NanogramKit/LaunchAtLogin.swift`, `packages/SettingsUI/Sources/SettingsUI/{LaunchAtLoginHooks,GeneralSettingsViewController}.swift`, `Telegram-Mac/packages-integration/hooks/SettingsHooksInstall.swift`, `Telegram-Mac/app/AppDelegate.swift`, keys `Nanogram.LaunchAtLogin.*`.
- Upstream: no (small guarded addition to the General screen and one call in `applicationDidFinishLaunching`).
- Sync: keep the `LaunchAtLoginHooks.installed` row and its `launchAtLoginRefresh` argument when upstream edits `GeneralSettingsViewController`; add the strings to the generated `Localizable.swift` on the next localization run.

### Incoming call card, notification and lifecycle
- What: a ringing call shows a non-activating `NSPanel` card (Accept/Decline) on every Space and over full-screen apps, posts a time-sensitive notification with Accept/Decline, bounces the Dock icon, and the ringing window is shown without the animated transition. Closing the call window while ringing declines, after a busy/disconnected end it removes the session; a new ring replaces an ended session and answers `.busy` only when a live call exists.
- Why: the Mac could ring invisibly (other Space, full screen, hidden app) and a stuck session made it decline every later call silently.
- Where: `packages/PrivateCallScreen/Sources/{IncomingCallCard,PeerCallWindowPolicy,PeerCallScreen}.swift`, `packages/NanogramRuntime/Sources/NanogramRuntime/{IncomingCallPolicy,IncomingCallNotification}.swift`, `Telegram-Mac/account/{IncomingCallPresenter,SharedWakeupManager,SharedAccountContext}.swift`, `Telegram-Mac/utils/UNUserNotifications.swift`, `packages/TelegramCallsCore/.../PCallSession.swift`, `packages/CallsUI/.../{CallScreenController,PCallLaunch}.swift`, `packages/CallVideoLayer/Sources/CallWindowTransition.swift`, `SharedAccountContextProtocol.dropCrossCall(ownedBy:)`; commits 4d62949a, 1911058b.
- Upstream: no (Nanogram-specific); the `.missed` busy drop and the `isUpdating` gate in `SharedWakeupManager` are upstream lines we changed.
- Sync: re-apply the ring pipeline in `SharedWakeupManager.updateRindingsStatuses` and the `closeInterceptor` in `PeerCallScreen.init`; tests `IncomingCallPolicyTests`, `PeerCallWindowPolicyTests`.
- libopus builds from the core's xiph/opus v1.6.1 submodule with CMake + Ninja, floating point (was fixed-point); libwebp builds with Ninja (2026-11-14). Where: `core-xprojects/libopus`, `core-xprojects/libwebp`. Upstream: no. Sync: keep ours.
