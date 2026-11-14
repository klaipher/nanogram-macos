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

### Native library builds
- What: the CMake libraries (tde2e, libjpeg-turbo) build with Ninja; dav1d's meson cross file is generated from `xcrun` (the checked-in `dav1d-arm64.meson` with a fixed Xcode path is deleted); framework stamps carry cmake/ninja/meson versions and `ccache=on|off`; `tg frameworks` routes CMake compiles through ccache (shared dir, `CCACHE_BASEDIR`); earlier tde2e hardening flags and the libjpeg-turbo swap live in the same scripts.
- Why: faster incremental and repeat builds, rebuild on Homebrew tool upgrades, no fixed Xcode path.
- Where: `core-xprojects/dav1d/dav1d/build.sh`, `core-xprojects/Mozjpeg/Mozjpeg/build.sh`, `core-xprojects/tde2e/tde2e/build.sh`, `scripts/framework-inputs.sh`, `tools/dev/nanogram/frameworks.py`.
- Upstream: no; these are upstream-owned scripts we edited (dav1d-arm64.meson deleted).
- Sync: conflicts are likely in those four scripts; keep the generated cross file, the Ninja generator and the stamp lines; tests `test_versions` (dav1d cross file), `test_fwcache` (stamp tests), `test_frameworks` (ccache env).

### Two editions, identity, distribution
- What: `mas` (App Store/TestFlight) and `direct` (Developer ID, notarized dmg, Sparkle 2.10.1 from klaipher/nanogram-releases),
  both sandboxed; own bundle id and team; Telegram's update, crash-bot and store endpoints removed.
- Where: `nanogram/editions/`, `tools/dev/tg testflight|release-direct`, docs/local-development.md "Identity, credentials and editions", "Sparkle".
- Upstream: no.

### Shared core from the iOS repository
- What: `submodules/telegram-ios` is klaipher/nanogram `main` (history-free), not Telegram-iOS; tgcalls and webrtc come
  from our forks (one branch each, the same commits as iOS and Android); parity gate with the iOS repository.
- Where: `.gitmodules`, `docs/mac-core-paths.txt`, `tools/dev/parity/`, `tg core-bump`.
- tgcalls: `nanogram-shared` carries Telegram 13.2's engine changes (SCTP timer overrides, reflector candidate-IP default, `removeOutgoingChannel` fix); the 14.0.0 engine is not part of the Mac build, so its 13.2 changes only reach the iOS app. Records: the fork's `NANOGRAM-CHANGES.md`. Pin 73cc1f8d added the `ios/` exclude to `Package.swift` (the iOS bridge lives in the same tree); 7afc0b25 adds upstream defea4a (empty ssrc groups skipped).
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

### Centered chat header
- What: the glass title capsule is centered on the chat column, and the pinned and translate bars are a bounded capsule centered under it. Upstream 13.2 anchors the title at the left and puts pinned, translate, search and Reopen Topic beside it (upstream #76, cfe7acc5). (check)
- Where: `packages/ChatUI` (`ChatHeaderLayout`, `ChatHeaderBubblesView.updateLayout`, `ChatControllerView.updateFrame`, `ChatHeaderState.fitsCenteredCapsule`); `ChatHeaderInlineLayout` removed. Capsule width is continuous in the window width, and it relayouts animated when the text width changes.
- Sync note: expect conflicts in `ChatHeaderBubblesView.swift`, `ChatController.swift` (`updateFrame`, `headerHeight`, `updateHeaderInsets`) and `ChatHeaderController.swift` at the next upstream merge; keep our side.

### Features and switches
- What: Nanogram debug switches (experiments off by default except on-device voice transcription; listed inline on the Developer screen), HTML
  message widgets, iOS-style first display, accessibility work. (check)
- Where: `packages/NanogramDebug`, `packages/NanogramRuntime`, `packages/NanogramKit`, docs/accessibility/.
- Call experiments (hardware decode, hardware crop, native decode format, screen-share hardware encoder, thermal video limits,
  10-video cap in group calls, RNNoise-only group noise suppression) default to on in the Mac app; each can still be switched
  off on the Developer screen. Upstream has none of these. `packages/CallVideoLayer`.

### Nanogram Features screen, search operators, link hygiene
- What: Settings > Nanogram Features lists the user-facing Nanogram options (search operators, link hygiene, system picture-in-picture, isolated sticker decoding, on-device translation and transcription, wide-gamut photos). In-chat search understands `from:`, `before:`, `after:`, `date:`, `type:`. Links can lose tracking parameters when opened or copied, and t.me / tg:// links can ask first. Ideas from Mercurygram (GPL-2.0 Android, GPLv3+ mdesktop), reimplemented; no code copied. (check)
- Where: `packages/NanogramRuntime` (`SearchOperators`, `LinkHygiene`), `packages/NanogramDebug` (`isUserFacing`), `packages/SettingsUI` (`NanogramFeaturesViewController`, `DeveloperHooks.nanogramFeatureSections`, one row in `AccountViewController`), `packages/ChatUI` (`ChatController` search request, `ChatSearchOperators`, `WPLayout`), `Telegram-Mac/utils/InAppLinks.swift`. Docs: `docs/specs/search-operators.md`, `docs/specs/link-hygiene.md`, `docs/mercurygram-port.md`.
- Sync note: the upstream hooks are the `AccountViewController` row, the `searchRequest` closure in `ChatController`, and three lines in `InAppLinks.swift` (`execute`, `.external`, `resolveLink`).

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

### Incoming call window, notification and lifecycle
- What: a ringing call makes the call window itself join every Space and, untested and possibly not for other apps' full-screen Spaces (it is not a non-activating panel), full-screen apps (level `.statusBar` while ringing, normal again after; the separate card was removed 2026-11-14), posts a time-sensitive notification with Accept/Decline, bounces the Dock icon, and the ringing window is shown without the animated transition. Closing the call window while ringing declines, after a busy/disconnected end it removes the session; a new ring replaces an ended session and answers `.busy` only when a live call exists.
- Why: the Mac could ring invisibly (other Space, full screen, hidden app) and a stuck session made it decline every later call silently.
- Where: `packages/PrivateCallScreen/Sources/{PeerCallWindowPolicy,PeerCallScreen}.swift`, `packages/NanogramRuntime/Sources/NanogramRuntime/{IncomingCallPolicy,IncomingCallNotification}.swift`, `Telegram-Mac/account/{IncomingCallPresenter,SharedWakeupManager,SharedAccountContext}.swift`, `Telegram-Mac/utils/UNUserNotifications.swift`, `packages/TelegramCallsCore/.../PCallSession.swift`, `packages/CallsUI/.../{CallScreenController,PCallLaunch}.swift`, `packages/CallVideoLayer/Sources/CallWindowTransition.swift`, `SharedAccountContextProtocol.dropCrossCall(ownedBy:)`; commits 4d62949a, 1911058b.
- Upstream: no (Nanogram-specific); the `.missed` busy drop and the `isUpdating` gate in `SharedWakeupManager` are upstream lines we changed.
- Sync: re-apply the ring pipeline in `SharedWakeupManager.updateRindingsStatuses` and the `closeInterceptor` in `PeerCallScreen.init`; tests `IncomingCallPolicyTests`, `PeerCallWindowPolicyTests`.
- End/Decline order (2026-11-14): the call window's `endcall` holds the session strongly and hangs up before marking it removable (`peerCallEndSteps`). Upstream marks it removable first on a weak reference; the synchronous window teardown then frees the session, whose `deinit` discards the call as `disconnect` and the hang-up never runs, so the other side shows "Call failed". Upstream bug, kept fixed here; re-apply in `CallScreenController.callScreen` after a merge. The notification Decline in `IncomingCallPresenter.respond` uses the same steps.

### Media and power efficiency (MAC-POWER-1, MAC-IMAGE-1/2, MAC-VISION-1, MAC-MEDIA-1)
- What: video export holds a user-initiated activity and QoS (no App Nap throttling of a send in progress); photo send and WebP size reads stream through ImageIO instead of loading and decoding whole files; subject lift shares one CIContext; async video first-frame thumbnails behind a Debug Settings switch (off).
- Where: `packages/ImageCanvasUI` (`UserInitiatedActivity`), `packages/ChatHistoryModel` (`PhotoSourceReading`), `packages/TextRecognizing/SubjectLifting.swift`, `packages/TelegramMediaUtils` (`VideoFirstFrameGenerator`).
- Upstream: no.

### Concurrency cleanups (modernization review)
- What: `activate()` instead of `activate(ignoringOtherApps:)` (28 sites); `FilePanels` uses `allowedContentTypes`; the share extension no longer blocks main on two semaphores (`continueLaunch`); `TabAllBadgeItem` caches the account count; the four export wait helpers are one `ExportBlocking`; `DecoderQuarantine`/`ReplyBox` are checked `Sendable`; the four packages named by the spec build with `StrictConcurrency` warnings.
- Why: deprecations, latent main-thread hangs and unchecked concurrency.
- Where: `TelegramShare/ShareViewController.swift`, `packages/ChatListUI/.../TabBadgeItem.swift`, `packages/ChatExportUI/.../ExportBlocking.swift`, `packages/FilePanels`, `packages/NanogramDecoder`, leaf `Package.swift` files.
- Upstream: the activate sites, `ShareViewController`, `TabBadgeItem` and `ChatExportManager` are upstream lines we changed.
- Sync: re-apply the semaphore removals in `ShareViewController` and `TabAllBadgeItem.makeView` after a merge; any new `activate(ignoringOtherApps:)` from upstream becomes `activate()`.

### Experimental modernization flags (macOS UI)
- What: four opt-in flags, all default off (`defaults write <bundle id> nanogram.experimental.<flag> -bool YES`): `deferredResizeRelayout` (chunked table relayout after live resize), `scaledImageCaches` (photo cache limits scale with memory), `coalescedMediaProgress` (30 Hz, 1% progress updates), `mediaFilePromiseDrag` (NSFilePromiseProvider for dragging media out). Also fixes `TableView.remove(range:)` (MACOS-LIST-2), not behind a flag.
- Where: `TGUIKit` (`ModernizationFlag.swift`, `TableRelayoutPlan.swift`, `TableView.layoutItems`, `TableView.remove(range:)`), `TelegramTheme/PhotoCacheSizing.swift` (+ `TelegramThemeShare` symlink), `TelegramMediaUtils/CoalescedProgress.swift`, `ChatUI/ChatMediaFilePromise.swift`, `ChatFileContentView`, `ChatInteractiveContentView`, `ChatMediaContentView`.
- Upstream: no.
- Sync: conflicts possible in `TableView.swift` and `ChatMediaContentView.swift`.

### Round videos like iOS (480 px, 1.2 Mbps)
- What: circles are recorded at `max(server diameter, 480)` px (even, at most 640), `max(server video_bitrate, 1200)` kbps and `max(server audio_bitrate, 64)` kbps, 30 fps (fixed frame duration), on the session's existing preset chain. The size sent with the message is the real writer size. Upstream follows the server values (384 px, 1000 kbps).
- Where: `packages/MediaRecorderUI` (`RoundVideoEncodingPolicy.swift`, `VideoRecorderPipeline.swift`, `ChatRecordingState.swift`) and the renderer's even output side in `TGVideoCameraMovie`.
- Upstream: no; `VideoMessageConfig` and the server reading are untouched.
- Sync: re-apply the policy calls in `VideoRecorderPipeline` (init, `_configureFps`, `configureRecorderTracks`, `writerSide`) after a merge.

- libopus builds from the core's xiph/opus v1.6.1 submodule with CMake + Ninja and the shared option file `opus-cmake-args.sh` (NEON presumed), floating point (was fixed-point); libwebp builds with Ninja (2026-11-14). Where: `core-xprojects/libopus`, `core-xprojects/libwebp`. Upstream: no. Sync: keep ours.

## One Send Report button (macOS)
- What: Help > Send Report… bundles app logs with critical logs, call logs, crash and hang reports, MetricKit reports and debug-switch values into one zip with a README (Mac model, chip, macOS, app build). A note before sending lists what is included; no messages, contacts or phone numbers. The crash card and the Developer screen use it too; the four fine-grained exports stay on the Developer screen only.
- Where: `packages/NanogramDebug` (`NanogramReport.swift`, `NanogramReportReadme.swift`, `NanogramReportMenu.swift`, the `fullReport` kind) and the hooks in `Telegram-Mac/packages-integration/hooks`.
- Upstream: no, Nanogram-only.
- Sync: none beyond keeping the hook installs.

## Energy numbers and inline debug switches (macOS)
- What: the report zip gains `energy.txt` (CPU time, billed and task energy, instructions, cycles, wakeups of the app process since launch and per experiment switch since it last changed; battery, power source, Low Power Mode, thermal state). The Developer screen lists all Nanogram switches inline, generated from `NanogramDebugSettings`; the separate debug-switches window is removed.
- Where: `packages/NanogramDebug` (`NanogramEnergy.swift`, `NanogramExperimentEnergy.swift`, `NanogramReport.stage(extraFiles:)`), upstream hook: `DeveloperHooks.nanogramSections` and one `nanogramDeveloperEntries` call in `DeveloperViewController.swift` (rows in the new `DeveloperNanogramSections.swift`), `Telegram-Mac/packages-integration/hooks/DeveloperHooksInstall.swift`.
- Sync note: upstream `DeveloperViewController.swift` conflicts are small: the NANOGRAM block, the `nanogramChanged` argument, `nanogramRevision` state.
