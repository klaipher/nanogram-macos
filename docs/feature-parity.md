# Feature parity: Nanogram iOS and macOS, and official Telegram

Identical in both repos (`nanogram-ios/docs/feature-parity.md`, `nanogram-macos/docs/feature-parity.md`). Start here
before adding a feature to one app, and update the matching row when a feature lands, so the next agent does not have
to re-derive it. Written 2026-11-05 from code reading only (nothing was built or run) at iOS `origin/main` 6e6664c6 and
Mac `sec/integration` 5d01908d. The Mac integration branch `nanogram/integration` (31030f3c) was behind it and did not
yet have Lockdown Mode or the key vault.

Paths start with `ios:` (the iOS repo) or `mac:` (the Mac repo). Marks: `yes`, `partial`, `no`, and `gap` for an
upstream gap (official Telegram has the same gap on that platform).

## Headline

- Telegram features are mostly at parity. Both apps share the same core (TelegramCore, Postbox, MtProtoKit, pinned to
  the same iOS commit), so every server feature has UI on both: folders, forums, stars, gifts and gift crafting,
  business, passkeys, paid reactions, suggested posts, live-story viewing, conference calls, RTMP.
- The real gaps are gaps upstream itself has between its iOS and Mac apps: the story composer and media editor, sending
  live location, chat import, the sticker maker, and widgets on the Mac. Filling them would conflict with every upstream
  sync. Recommendation: do not.
- Our own (Nanogram-only) features are where the cheap parity work is: the Mac is ahead on on-device transcription,
  App Intents and the Focus filter; iOS is ahead on the CPU profiler and diagnostics export.
- Identical copies that can drift are listed under `mirror` in `docs/mac-core-paths.txt`; the parity check compares them.

## 1. Telegram features per client

| Feature | iOS | Mac | Evidence / note |
|---|---|---|---|
| Chats, folders, archive | yes | yes | ios:submodules/ChatListUI/Sources/ChatListFilterPresetController.swift; mac:packages/ChatListUI, TelegramShare/SEFoldersRowItem.swift |
| Forums / topics | yes | yes | ios:TelegramUI/Components/ForumCreateTopicScreen; mac:packages/ForumSettingsUI, ChatUI/ChatController.swift (createForumChannelTopic) |
| Saved messages, tags, saved dialogs / monoforums | yes | yes | mac:packages/ChatUI/Sources/ChatUI/ChatReactionsView.swift (tags) |
| Secret chats, auto-delete | yes | yes | |
| Polls, to-do lists, suggested posts, paid messages | yes | yes | mac:ChatUI/ChatTodoItem.swift, ChatPollItem.swift |
| Stories: viewing, stealth, live stories | yes | yes | mac:packages/StoriesUI/Sources/StoriesUI/StoryLiveStreamInputView.swift |
| Stories: posting | yes | gap (partial) | The Mac can only repost an existing story or share one from a mini app (mac:StoriesUI/StoryPrivacyModalController.swift:1072,1107; Telegram-Mac/packages-integration/hooks/BrowserHooksInstall.swift:162). No camera or composer. |
| Media editor (photo/video) | yes, full (ios:TelegramUI/Components/MediaEditorScreen, DrawingUI) | partial | mac:packages/ImageCanvasUI (draw, cutout, video crop/trim). No stickers-on-media, weather or story layers. |
| Round videos and voice notes (record) | yes | yes | mac:packages/MediaRecorderUI/Sources/VideoRecorderModalController.swift |
| Stickers, emoji, effects, reactions, paid reactions | yes | yes | mac:packages/Reactions, ChatUI (effectId), StarsUI/Star_Transaction.swift |
| Sticker maker (cut out from a photo) | yes | gap | The Mac only manages packs (mac:EntertainmentUI/StickerPackEditing.swift). |
| Translation (server) | yes | yes | ios:TranslateUI/ChatTranslation.swift; mac:ChatHistoryModel/ChatLiveTranslateContext.swift |
| On-device translation | yes (upstream, ios:TranslateUI/Sources/Translate.swift) | yes, plus ours (macOS 15-25 fallback behind a switch, mac:packages/Translate/Sources/Translate/OnDeviceTranslation.swift) | |
| Voice transcription (server) | yes | yes | |
| On-device transcription | partial: off by default; now on-device only (see section 4) | yes, ours: SpeechAnalyzer first, then the old on-device recognizer, on-device only, labelled, on by default | Parity gap. iOS should get the Mac chain (ios:submodules/Media/LocalAudioTranscription; mac:packages/LocalAudioTranscription). |
| Calls 1:1, group, conference E2E, RTMP livestream, screen share | yes | yes | Conference: ios:CallListUI/CallListController.swift, mac:CallsUI/RecentCallsViewController.swift:260. RTMP: mac:GroupCallScreenUI/RTMPStartController.swift. Switch-level parity: nanogram-macos-recon/2026-11-04-calls-ios-vs-mac-comparison.md. |
| Payments, Stars, gifts, gift crafting, boosts, statistics, monetisation | yes | yes | mac:packages/PaymentsUI, StarsUI, GiftCraftingUI; ios:Components/Gifts/GiftViewScreen |
| Wallet (TON) | yes | yes | Shared core: submodules/WalletContext, third-party/wallet-engine |
| Passport | yes | yes | |
| Bots, mini apps, in-app browser | yes | yes | mac:packages/WebAppUI (WebappBrowser.swift) |
| Business (hours, location, quick replies, greeting/away, chatbots, links, intro) | yes | yes | mac:packages/BusinessUI |
| Privacy settings, passkeys, sessions | yes | yes | mac:packages/PasskeysUI |
| Age verification | yes, face scan (ios:Components/FaceScanScreen) | partial: alert flow only (mac:packages/VerifyAgeUI) | Upstream difference |
| Live location | yes, send and view | gap: view only | mac:LocationUI/LocationModalController.swift:598 sends `liveBroadcastingTimeout: nil` |
| Chat import | yes (ios:ChatImportUI, share extension) | gap | |
| Chat export | gap | yes (mac:packages/ChatExportUI) | |
| Lockdown Mode (ours) | yes (ios:submodules/HardenedMedia) | yes, through the shared core (mac:InAppSettings/HardenedMediaExport.swift; ChatMessageItem.swift:450) | |
| Passcode | yes, PasscodeCore (ios:docs/passcode.md) | yes, the upstream Mac scheme for the app lock; PasscodeCore only for the wallet and web-app keychain | A design difference, not a missing feature |
| Notifications, exceptions | yes | yes | |
| Communication notifications (avatars) | yes | partial: MAS edition only | Entitlement is in mac:nanogram/entitlements/Nanogram-MAS*.entitlements, not in Direct |
| Widgets | yes (ios:Telegram/WidgetKitWidget) | gap | mac:packages/WidgetUI is in-app cards, not WidgetKit |
| Share extension | yes | yes | ios:Telegram/Share; mac:TelegramShare |
| Siri / App Intents | partial: legacy SiriKit intents only; App Intents not started (I-31) | yes, ours: Open Chat, Send Message, Focus filter (mac:packages/ChatAppIntents) | Parity gap; iOS is behind |
| Spotlight | yes (I-32) | yes, ours (mac:NanogramRuntime/SpotlightPeerIndex.swift) | |
| Picture-in-picture | yes, system | yes, Telegram's own; system PiP behind a switch (mac:NanogramRuntime/SystemPictureInPicture.swift) | |
| Accessibility | yes, upstream | partial: upstream's VoiceOver plan (mac:docs/accessibility/PLAN.md, ios-parity.md) | Upstream work in progress; not ours to fill |
| Localisation | 19 lproj, server language packs | 8 lproj, server language packs | Nanogram user-facing strings are localised. The Mac has 61 `//TODOLANG` strings, 33 of them ours, all in debug or log-export UI. |
| News, Debug companion, weather sticker, Cocoon text processing | yes (upstream iOS) | Cocoon yes, rest gap | Upstream only |

## 2. Nanogram-only features

| Feature | iOS | Mac | Evidence |
|---|---|---|---|
| Debug settings UI | yes (ios:DebugSettingsUI/Sources/DebugController.swift) | yes: Nanogram > Debug Settings (mac:packages/NanogramDebug) plus upstream DeveloperViewController | |
| Rust MTProto engine, Network.framework transport, download experiments | yes | yes | mac:SettingsUI/DeveloperNetworkSwitches.swift |
| Power / thermal policy for UI | yes (ios:Display/Source/EnergyRules.swift, 1907a285) | yes (mac:NanogramRuntime/LiteModePower.swift, M11) | |
| Calls thermal ladder, power governor | yes (CallThermalGovernor.swift) | yes (CallVideoLayer/CallPowerGovernor.swift) | |
| MetricKit collection and export | yes (DebugLogExport) | yes (CrashReports/MetricReportStore.swift, NanogramLogExport) | |
| Disk-write accounting | yes: counters, hourly line, `logs/disk-writes.json` ledger (ios:TelegramUI/Sources/AppDelegate.swift) | yes since 2026-11-05: mac:NanogramRuntime/DiskWriteReports.swift, started in Telegram-Mac/app/AppDelegate.swift, ledger in the MetricKit export | |
| Background diagnostics | yes (ios:submodules/BackgroundDiagnostics) | n/a (iOS lifecycle) | |
| CPU profiler | yes (ios:submodules/CpuProfiler) | no (signposts H11 and the DEBUG-only PerfLab/NetworkLab instead) | Low value on Mac (Instruments) |
| Log export | app, share, group-call, notification, critical, all, storage stats, profile, MetricKit | app, call, crash (Direct only), MetricKit | Mac lacks storage stats and share-extension logs |
| VP9 hardware sticker decode | yes (ios:AnimatedStickerNode/VP9Hardware) | yes (mac:packages/VP9Hardware) | Decoder and demuxer are byte-identical copies, listed as `mirror` lines in docs/mac-core-paths.txt |
| Wide-gamut JPEG send | no | yes, switch, off (mac:Telegram-Mac/app/AppDelegate.swift) | |
| Frame-rate cap | yes (tablet display-link cap) | yes (display.maxFrameRate) | |
| Database key vault | yes (ios:BuildConfig/Sources/NanogramKeyVault.m) | yes (3366e52d on sec/integration) | Two identical copies today; one core module is the plan |
| Isolated sticker decoding (XPC) | n/a | yes, switch, off | |
| Show calls in Phone Recents | yes | n/a | |
| App icons (Sphere default) | yes | yes (mac:packages/NanogramAppIcons) | |

## 3. Compared with official Telegram

- iOS: no full-screen incoming CallKit calls and no silent push filtering until Apple grants notification filtering
  (ios:docs/release/apple-capabilities.md #2, pending). Siri capability is still off (#3, an owner step). No CarPlay.
  No t.me universal links and no Apple Pay merchant IDs (impossible for a fork).
- Both: InAppPurchaseManager still lists Telegram's StoreKit products (`org.telegram.telegramPremium.*`,
  ios:submodules/InAppPurchaseManager/Sources/InAppPurchaseManager.swift:12; same on Mac). Buying Premium or Stars
  through the App Store cannot work for `org.klaipher.Nanogram`, and the Mac Direct edition has no StoreKit at all. Not
  verified what the UI does when the purchase fails.
- Mac: Telegram's update, crash-bot and store endpoints are removed. Direct updates go through Sparkle; the MAS
  edition has no Sparkle. Communication notifications work in the MAS edition only.

## 4. Unfinished work in our fork

- iOS integrations still partial (ios:docs/superpowers/specs/2026-11-03-ios-integrations-specs.md): I-15 notification
  downloads use 128 KB parts; I-26 extensions can still trap without the account DB; I-27 widget refresh coalescing;
  I-31 App Intents (not started, L); I-36 Files/iCloud metadata on the main thread; I-40 live location sensor rate;
  I-42 the proxy paste prompt.
- iOS runtime specs still `todo`: R11, R13, R17, R19, R20, R21, R23 (R7 is done, 1907a285).
- Mac specs: partial R2-17 (package conventions), R2-19 (GIF to MP4), R2-24 (deprecations), R2-26 (decoder threads),
  R2-28 (library builds), R2-43 (SQLCipher cache), H20 (audio renderer), H25 (GIF IOSurface); R2-5 was dropped. M15,
  M19, H10 and H15 are done (69381d0a, bfeb43f0, e0198d5a, eb33a0a5). H24: MAS has the entitlement, Direct does not.
- Off-by-default experiments. iOS: localTranscription, enableVoipTcp, groupCallReferenceEngine, liveStreamV2, all the
  calls* switches, Enhanced Security build flags. Mac: system PiP, wide-gamut JPEG, the macOS 15-25 translation
  fallback, isolated decoding, Q9 built-in mic, the calls switches. On Mac only on-device transcription is on.
- iOS local transcription (switch off by default, ios:submodules/Media/LocalAudioTranscription): since 2026-11-05 it
  requires on-device recognition and returns no transcript when the locale has no on-device model, as the Mac does.
- Copies that can drift: the VP9 decoder (identical, now compared by the parity check). LocalAudioTranscription is a
  different module on each side (137 vs 301 lines). The Mac ChatAppIntents logic (`ChatIntentsLogic.swift`,
  `ChatFocusFolders.swift`) uses only Foundation and could seed iOS phase 1.
- Hard-coded English on Mac: 33 `//TODOLANG` strings, debug UI only. Acceptable; iOS debug UI is English too.

## 5. Later, with effort estimates

- iOS on-device transcription: port the Mac SpeechAnalyzer chain and the "on-device" label (M, 1-2 days).
- iOS App Intents phase 1: reuse the Mac ChatAppIntents logic for Open Chat, Send Message, Focus filter and App Shortcuts
  (L, 3-5 days; needs the App Intents metadata step in Bazel).
- Move VP9Hardware into the shared core and build the Mac from the submodule (S-M, needs a build).
- Mac log export: add storage stats and share-extension logs (S).
- iOS wide-gamut send option (S-M).
- Premium and Stars purchase audit on both apps: what the user sees, and a route to @PremiumBot or Fragment (S to
  investigate, M to fix).
- Mac widgets (L, owner's call).
- Upstream platform gaps on Mac (story composer, live location sending, chat import, sticker maker): XL each. Do not.
