# Round 2 (macOS): specs from the 2026-11-03 deep review

A second read-only review of Nanogram for macOS, after round 1
(`docs/superpowers/specs/2026-11-02-macos-runtime-efficiency-specs.md` in the runtime checkout, specs M1-M32, H1-H28,
Q1-Q15). Five reviewers covered CPU/memory/battery, modern APIs and dead code, macOS optimizations and hardware,
external libraries, and the database and MediaBox. Nothing was built, run or profiled, and there is no account on this
Mac. Each spec below is one change to make later. Line numbers are as of 2026-11-03; re-check them before starting.

- **Checkouts.** Paths are relative to the runtime checkout (`nanogram-macos-runtime`, branch `nanogram/runtime`)
  unless they start with `stage1:` (`nanogram-macos`, branch `nanogram/stage1`, HEAD `8dece807`). The stage-2 checkout
  (`nanogram-macos-stage2`, HEAD `1690eb66`, behind stage 1) was not reviewed.
- **Verified.** The lead re-read the cited lines of every medium- and low-confidence finding and of every finding that
  claims a large gain, plus the API and library claims. Corrections are noted in the spec ("corrected"). Findings
  already done or already specified in round 1 were dropped (see "Dropped after checking"). Duplicates from different
  reviewers were merged into one spec.
- **Groups.** Each spec belongs to exactly one fix group: `perf` (CPU, memory, battery, macOS optimizations,
  hardware), `modern` (modern APIs, dead-code removal), `libs` (external library build flags and API use), `db`
  (database and MediaBox).
- **Size**: S = a few lines, M = one file or a few call sites, L = a design change across modules.
- **Gains** are estimates from reading the code, from the iOS fork's measurements on the same code, or from scratch
  microbenchmarks named in the spec. None was measured in the app.
- Fixes in `submodules/telegram-ios` (Postbox, TelegramCore, MediaPlayer, FFmpeg) and `submodules/tgcalls` are shared
  with iOS: port the iOS fork's commit where one exists, so the two forks stay one diff.

Status values: `todo`, `in progress`, `done (<commit>)`, `dropped (<reason>)`.

| Group | S | M | L | Total |
|---|---|---|---|---|
| perf | 8 | 5 | 0 | 13 |
| modern | 9 | 1 | 1 | 11 |
| libs | 8 | 1 | 0 | 9 |
| db | 6 | 4 | 0 | 10 |
| **all** | **31** | **11** | **1** | **43** |

## perf: CPU, memory, battery, macOS and hardware

### R2-1. Per-chat network and Postbox polls keep running while the chat window is hidden or occluded — `todo` (group: perf)

- **Evidence**: `packages/ChatUI/Sources/ChatUI/ChatController.swift:9418-9438`: every open channel with a linked
  discussion group (and every thread) subscribes `viewTracker.polledChannel(peerId:)` for the controller's lifetime.
  `submodules/telegram-ios/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift:3262-3266`
  (`keepPollingChannel` = `pollChannelOnce |> restart`, with a 30 s delay on completion, `:3154-3160`); M2 removed only
  the no-op writes, not the requests. `ChatController.swift:3898-3903,3964-3969` →
  `packages/TelegramContext/Sources/TelegramContext/PeerChannelMemberCategoriesContextsManager.swift:81-88`:
  supergroups with more than 200 members poll `chatOnlineMembers` (`messages.getOnlines`) every 30 s, and for 60 s
  more after the last unsubscribe (`:115-131`). `ChatController.swift:9463`:
  `isPremiumRequiredToContact([peerId]) |> then(suspendAwareDelay(60)) |> restart` runs for every open chat, groups
  and channels included. `ChatController.swift:2276-2284`: the sponsored message's channel gets `polledChannel` plus
  `addAdditionalPreloadHistoryPeerId` while the chat is open. M22 already provides the visibility signal
  (`packages/NanogramRuntime/Sources/NanogramRuntime/HistoryVisibility.swift`, `WindowVisibilityObserver`).
- **Today**: a chat on the Mac stays open for days in a hidden, minimized or covered window. For each open channel
  with comments, one getChannelDifference per ~30 s; for each large group a getOnlines every 30 s; for every open chat
  a Postbox transaction every 60 s. All run forever, with the display asleep too, and their results re-emit views
  nobody sees. iOS stops them when the app goes to the background; the Mac never does.
- **Fix**: gate each subscription on the M22 visibility promise:
  `historyVisibility.get() |> distinctUntilChanged |> mapToSignal { $0 ? polledChannel(peerId) : .never() }`. Do the
  same for the `onlineMemberCount` branch of `counters`, the ad-peer poll and preload, and the premium check. Also
  restrict the premium check to `peerId.namespace == Namespaces.Peer.CloudUser`, so the loop never runs for groups and
  channels. On reveal each poll starts with a fetch, so values are fresh at once. Optional: treat "app inactive for
  more than N minutes" as hidden too.
- **Gain**: roughly 2-4 background requests per minute per open channel or large group, plus one Postbox transaction
  per minute per open chat, removed for as long as the window is hidden. Fewer radio and engine wake-ups, so Wi-Fi can
  idle. Probably the largest remaining background network cost of an idle Mac with chats open (estimate).
- **Risk**: low to medium. Comment counts, the online count and the premium badge refresh on reveal instead of in the
  background. The channel itself still gets pushed updates. A chat in a visible secondary window stays polled, since
  `WindowVisibilityObserver` is per window.
- **How to verify**: a pure `shouldPoll(visible:)` gate with ChatUITests: a fake polled-channel signal counts
  subscriptions (1 while visible, 0 after hide, 1 again on reveal). A TelegramCore test with a stub network counts
  getChannelDifference/getOnlines over 5 minutes of virtual time, hidden vs visible. With the account: network log
  with the window minimized.
- **Size**: M
- **Confidence**: high

### R2-2. The 10 s passcode-lock poll runs for every user and fans out to four subscribers; the presence re-check polls every 5 s while the display sleeps — `todo` (group: perf)

- **Evidence**: `Telegram-Mac/account/SharedNotificationManager.swift:279-307`:
  `.single(()) |> delay(10, queue: concurrentDefaultQueue) |> restart`, mapped to Bool, `filter`,
  `deliverOnMainQueue`, no `distinctUntilChanged`. With no passcode, `cachedLockTimeout` holds `.some(nil)`, so it
  emits `false` every 10 s. `:206`: each emission subscribes `additionalSettings(accountManager) |> take(1)` (an
  AccountManager view registered and torn down) and hops to main. Other subscribers of the same signal (through
  `AppDelegate.passlock`, `:245-249`): the per-account free-space `combineLatest(queue: .mainQueue(), …, isLocked)`
  (`Telegram-Mac/account/AccountContext.swift:891-894`), the chat-list auto-archive suggestion
  (`packages/ChatListUI/Sources/ChatListUI/ChatListController.swift:1669-1674`) and the wallet hook. With a passcode
  every tick calls `SystemIdleTime()` (`packages/ObjcUtils/Sources/ObjcUtils/ObjcUtils.m:1275-1296`: an IORegistry
  `IOServiceGetMatchingServices("IOHIDSystem")` match plus a property copy). M23 gap:
  `packages/NanogramRuntime/Sources/NanogramRuntime/Wakeup.swift:105-114` `PresenceIdleSchedule.nextCheck` returns
  5 s whenever the app is active and idle ≥ 30 s; `Telegram-Mac/app/AppDelegate.swift:1351` passes only
  `NSApp.isActive && !NSApp.isHidden`, so sleep and screen lock are ignored.
- **Today**: every 10 s, for every user, with or without a passcode, a timer hops to main and re-runs the
  notification manager, N free-space checks, the chat-list suggestion check and the wallet. Nothing changes. When
  Telegram was frontmost as the display slept or the screen locked, the presence re-check runs every 5 s all night,
  with an IOKit read each time.
- **Fix**: (1) Passlock: return `.single(false)` with no timer when nothing is lockable (driven by the existing
  `accessChallengeData()`/`passcodeSettingsView` subscription). With a timeout, arm one one-shot timer at
  `timeout - idle`, and one at `resignTimestamp + timeout` after resign-key; re-arm when input made it fire early
  (the same shape as M23's `PresenceIdleSchedule`). Add `|> distinctUntilChanged` before `deliverOnMainQueue`; keep
  the screen-lock path. (2) Presence: make `nextCheck` take `isSleeping`/`screenLock` and return nil for them; the
  existing sleep, wake and unlock callbacks already call `updatePeerPresence()`. (3) Replace the IOKit match in
  `SystemIdleTime()` with `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kCGAnyInputEventType)`
  (macOS 10.4+).
- **Gain**: about 0.1 Hz of main-thread and queue fan-out (5+ hops per tick) removed for every user, always, and 0.2 Hz
  of main wake-ups plus IOKit calls overnight with the display asleep. The CPU per tick is small; the gain is idle
  residency (M21's leeway already coalesces part of it).
- **Risk**: low. The lock fires at its deadline instead of up to 10 s late. Free-space and auto-archive checks still
  re-run when their own inputs change (free space every 30 min, key window and suggestions on change).
- **How to verify**: NanogramRuntime unit tests for a pure `PasslockSchedule.nextCheck(timeout:idle:resignedAt:now:)`
  and for `nextCheck` returning nil while sleeping or locked. A SwiftSignalKit test that the no-passcode signal emits
  once in 60 s of virtual time. `IdleWakeupTests`/`sysmon.py` idle wake-ups on the Debug app before and after.
- **Size**: S
- **Confidence**: high

### R2-3. Autoplay video, GIFs, round videos and video avatars are gated on key-window only, so they decode on another Space, under other windows and with the display asleep — `todo` (group: perf)

Merged from two reviewers (CPU and macOS areas).

- **Evidence**: `packages/ChatUI/Sources/ChatUI/ChatInteractiveContentView.swift:594`
  (`accept = window != nil && window!.isKeyWindow && !NSIsEmptyRect(visibleRect) && !isDynamicContentLocked`);
  the same predicate in `packages/TelegramMediaUtils/Sources/TelegramMediaUtils/GIFContainerView.swift:93`,
  `ChatVideoMessageContentView.swift:315`, `ChatAvatarView.swift:250`, `ChatServiceItem.swift:4852,6273`,
  `AccountInfoItem.swift:239`. `packages/TGUIKit/Sources/AnimatableContentObserver.swift:69-70` re-evaluates only on
  didBecomeKey/didResignKey. App visibility (`!NSApp.isHidden && NSApp.occlusionState.contains(.visible)`) exists in
  `Telegram-Mac/app/AppDelegate.swift:1599-1616` but reaches only the display link and Lottie. Upstream power-audit
  #31b; round 1 listed it under "Not checked" only.
- **Today**: Telegram can be the key window while invisible: on another Space, fully covered by a non-activating
  window, or frontmost when the screen locked or the display slept. Every autoplay player in the visible rect keeps
  running: ChunkMediaPlayerV2 (with its 60 Hz main timer, R2-6), MediaPlayer, GIF players, round videos, video avatars.
- **Fix**: in TGUIKit add `NSView.isPlaybackVisible` = `window.isKeyWindow && window.occlusionState.contains(.visible)
  && !NSApp.isHidden`, plus the screen-sleep and screen-lock state already tracked by SharedWakeupManager and
  SharedNotificationManager (exposed as a TGUIKit `ValuePromise`). Use it in the `accept` predicates above; keep
  GIFContainerView's `ignoreWindowKey` (`(isKeyWindow || ignoreWindowKey) && visible`). In AnimatableContentObserver
  also observe `NSWindow.didChangeOcclusionStateNotification`, `NSApplication.didChangeOcclusionStateNotification`,
  `didHide`/`didUnhide` and the sleep/lock promise.
- **Gain**: all autoplay demux, decode and per-player main timers stop while nothing can be seen: several tiles ×
  (demux + VideoToolbox decode + 2-60 Hz main ticks) for as long as the window stays hidden. The largest remaining
  visibility gap after M22 and the Lottie suspension.
- **Risk**: low. Videos pause and resume from the current frame, the same path as resign-key today. PiP and the media
  viewer are separate windows with their own occlusion state.
- **How to verify**: TGUIKitTests: extend AnimatableContentObserverTests to post the occlusion notification and assert
  the selector fires; a pure predicate test with a stub window. A small AppKit probe logs `occlusionState` on Space
  switch, screen lock and `pmset displaysleepnow` (decides whether the explicit sleep/lock inputs are needed). Energy:
  a PowerLabs harness with N AVSampleBufferDisplayLayer players plus `sysmon.py` while moving the window to another
  Space.
- **Size**: M
- **Confidence**: high (Space and covered-window cases are documented AppKit behaviour; the display-sleep case needs
  the probe)

### R2-4. Calls hold a NoDisplaySleep assertion for the whole call, audio-only and hidden included — `todo` (group: perf)

- **Evidence**: `packages/PrivateCallScreen/Sources/PeerCallScreen.swift:433-436`: `show()` always calls
  `disableScreenSleep()`; released only at call end (`:423`) or in deinit (`:511-516`). The assertion is
  `kIOPMAssertionTypeNoDisplaySleep` (`:490-500`) whatever the video state. `packages/GroupCallScreenUI/Sources/
  GroupCallScreenUI/GroupCallController.swift:2326` `ScreenSleepAssertion(reason: "Group Call")` held for the whole
  voice chat. `packages/TGUIKit/Sources/ScreenSleepAssertion.swift`: NoDisplaySleep only, no deinit release.
  `docs/perflab/power-audit.md` (#13a): running CoreAudio output already holds PreventUserIdleSystemSleep.
- **Today**: during any 1:1 call or voice chat the display never dims or sleeps, even with no video, the call window
  hidden and the user away. A one-hour audio call keeps the backlight and WindowServer compositing on for an hour.
- **Fix**: hold NoDisplaySleep only while video is shown (local or remote video in a 1:1 call, a video or screen-share
  tile in a group call) and the call window is visible (occlusion); re-evaluate on state and occlusion changes.
  Audio-only calls hold nothing (the audio IO already prevents idle system sleep); if an explicit assertion is wanted,
  use `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled], reason:)`. Release in
  `ScreenSleepAssertion.deinit` too.
- **Gain**: the display can dim and sleep during audio calls and voice chats. The backlight is the largest single power
  draw on a laptop.
- **Risk**: low; FaceTime behaves the same way for audio calls. Product check: someone reading a voice chat's
  participant list sees the display dim after the system idle time.
- **How to verify**: unit test for a pure `screenSleepAssertionNeeded(hasVisibleVideo:isWindowVisible:)` and for
  `ScreenSleepAssertion` toggle sequencing (one create, one release). Open the DEBUG PeerCallLab/CallVideoLab screens
  and check `pmset -g assertions` with video off and on.
- **Size**: S
- **Confidence**: high

### R2-5. MediaPlayerView moves every frame through the main thread and polls readiness with a precise timer; feed `sampleBufferRenderer` from its queue as ChunkMediaPlayerV2 does — `todo` (group: perf)

- **Evidence**: `packages/TelegramMedia/Sources/MediaPlayerView.swift:211-243` (`startPolling` on main; when the layer
  is not ready, a repeating main-queue `SwiftSignalKit.Timer(timeout: max(1/30, …), leeway: .precise)`, `:255-257`);
  `:262-357` (per frame: `takeFrameQueue.async`, then one `Queue.mainQueue().async` to `enqueue` and one to re-enter
  `pollInner`; one main hop per skipped frame). `init(backgroundThread:)` (`:427`) ignores its parameter, so callers
  passing `true` (ChatInteractiveContentView, ChatAvatarView, PeerInfoHeadItem, MGalleryGIFItem) get nothing.
  The pattern already exists: `ChunkMediaPlayerV2.swift:1100-1110`
  (`sampleBufferRenderer.requestMediaDataWhenReady(on: dataQueue)`) and GIFPlayerView.
- **Today**: each playing MediaPlayerView costs about two main-queue blocks per frame plus timer wake-ups while the
  layer queue is full: an estimated 30-90 main wake-ups/s for one 30 fps video (corrected from "60-90": consecutive
  async blocks often run in one wake). Several autoplay videos or video avatars multiply it, and it competes with
  scrolling.
- **Fix**: `if #available(macOS 14, *)` (the package still declares 10.13): replace the main-queue poll with
  `videoLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: takeFrameQueue.queue) { while renderer.isReadyForMoreMediaData { … renderer.enqueue(…) } }`;
  `flush` through the renderer; hop to main only for the one-shot `hasSentFramesToDisplay`. Call
  `stopRequestingMediaData()` on timebase change, removal from the hierarchy and deinit (required by the API). Keep
  the old path as the fallback. This also moves this file's ~10 deprecated AVSampleBufferDisplayLayer calls (R2-24).
- **Gain**: tens of main-thread wake-ups per second per playing video removed; less main-thread work while scrolling
  chats with autoplay media.
- **Risk**: medium. The `.restoreState` path (flush, DoNotDisplay/DisplayImmediately attachments, decoder reset) must
  keep its order on the serial queue. Releasing without `stopRequestingMediaData` is undefined.
- **How to verify**: a TelegramMedia package test with a fake frame source and an AVSampleBufferDisplayLayer: count
  main-queue blocks per second over 10 s of 30 fps playback, old vs new, and assert identical enqueued PTS sequences
  including a seek/restoreState. GalleryUI VideoPlayerLab with a local mp4.
- **Size**: M
- **Confidence**: medium

### R2-6. ChunkMediaPlayerV2 runs a 60 Hz zero-tolerance main-thread Foundation.Timer for the whole time it plays — `todo` (group: perf)

- **Evidence**: `packages/TelegramMedia/Sources/ChunkMediaPlayerV2.swift:377-390`
  (`isFast = isPlaying || pendingSeek || pendingVideoFrame || !didSeekOnce` →
  `Foundation.Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true)`, no `tolerance`); `:476-520` (per tick:
  `unsortedPartsStateParts.sorted`, new `ChunkMediaPlayerPart` objects); `:458-462` (`source.updatePlaybackState` per
  tick). Steady-state feeding does not need the tick: the renderer is fed by `requestMediaDataWhenReady` on
  `dataQueue` (`:1100-1136`), and starvation re-arm has its own back-off (`:1046-1049`). Users: chat autoplay for
  AV1/unknown codecs, HLS, the gallery. Power-audit #20/#31g cover only the paused 5 Hz tick.
- **Today**: every playing chunked player wakes main 60 times a second, unaligned with vsync and with other players;
  each wake sorts and copies the parts list and allocates part objects. Three muted AV1 autoplay tiles ≈ 180 main
  wake-ups/s.
- **Fix**: fast cadence (60 Hz, or a `SharedDisplayLinkDriver` subscription so it pauses with occlusion and aligns to
  vsync) only while a seek or seek frame is pending, `!didSeekOnce`, buffering, or a starvation back-off is armed.
  Steady playing at 4-10 Hz with `tolerance = 0.1 × interval`. On the starvation hop to main (`:1128-1135`) call
  `updateInternalState()` directly. Cache the sorted parts keyed by the `partsState` identity.
- **Gain**: about 50-56 fewer main wake-ups/s per playing chunked player, plus the per-tick sort and allocations
  (estimate).
- **Risk**: medium. Part hand-over, end-of-stream and loop detection could react up to one slow tick later; HLS
  quality switching is driven from this loop. Keep the fast path on every transition state; test seek, loop and HLS
  level switches.
- **How to verify**: a TelegramMedia SwiftPM test with a local direct-fetch source on a bundled fixture: count
  `updateInternalState` calls over 10 s (≈600 today), assert the same enqueued frame count and no added
  `noteVideoStarvation` calls. IdleWakeupTests A/B. The existing ChunkMediaPlayerV2 seek, loop and end tests.
- **Size**: M
- **Confidence**: medium

### R2-7. Typing in any chat, loaded or not, re-runs the whole chat-list mapping, sort and diff — `todo` (group: perf)

- **Evidence**: `packages/ChatListUI/Sources/ChatListUI/PeersListController.swift:2591-2668` (`allPeerInputActivities()`
  for every chat feeds `PeerListState.activities`); `ChatListController.swift:627-632` (the projection drops only
  `.voiceChat` spaces); `:989` (the projection is a `combineLatest` input with `distinctUntilChanged`, so any typing
  start or stop re-runs the mapToQueue body: entry mapping, sort, `prepareEntries`); rows read activities only for
  loaded entries (`:1048`). `docs/perflab/chat-performance-2026-10-11.md` section 9: upstream left "filtering
  activities to the loaded rows" undone on purpose, because a filtered projection would keep stale activities for a
  chat paged in later.
- **Today**: on a busy account someone is typing in some group most of the time. Each activity start and expiry
  (~6 s) rebuilds and diffs the chat-list entries, even for chats outside the loaded window or in archived folders.
  M22 removed this only while the window is hidden.
- **Fix**: keep the full map in the projection (no staleness), but short-circuit inside the mapToQueue body: store the
  previous non-activity inputs (view identity, appearance, other projection fields) and the previously applied
  activities restricted to the peer ids of the current entries. When only activities changed and the restricted subset
  is equal, return `.complete()` without touching `previousChatList`/entries (the `HistoryVisibilityGate` pattern).
  When the view changes, the full map applies.
- **Gain**: most typing-driven chat-list rebuilds go away on accounts with many active groups (estimate 1-3 ms of
  prepare-queue CPU per rebuild for 100+ loaded rows, plus the main-thread merge tail). Not measured.
- **Risk**: low to medium. The input comparison must cover every field the closure reads. Pin it with a randomized
  old-vs-new parity test (as for M24).
- **How to verify**: ChatListUITests (ChatListStateProjectionTests style): 100 activity changes for peers outside the
  view → 0 `prepareEntries` calls, then 1 for a loaded peer; a chat paged in with an active activity shows it.
- **Size**: M
- **Confidence**: medium

### R2-8. The Settings tab is built at launch and keeps a 15-input pipeline live offscreen, including a 60 s notification-settings XPC poll — `todo` (group: perf)

Merged from two reviewers (CPU and modern-API areas). The dead NSUserNotification code is R2-15.

- **Evidence**: `Telegram-Mac/app/MainViewController.swift:540-542` (`settings.loadViewIfNeeded(bounds)` at launch);
  `packages/SettingsUI/Sources/SettingsUI/AccountViewController.swift:1196` (`combineLatest(queue: prepareQueue,` own
  peer view, accounts, appearance, settings incl. connection status, app update state, sessions, authorization status,
  two-step, story stats, bots, stars, TON, wallet balance`)` → entries, `prepareEntries`, `tableView.merge`, never
  paused). `Telegram-Mac/utils/UNUserNotifications.swift:49-53` `recurrentAuthorizationStatus`:
  `keyWindowUpdater |> mapToSignal { _ in getNotificationSettings |> then(suspendAwareDelay(60)) |> restart }`; it
  ignores the key flag, so `UNUserNotificationCenter.getNotificationSettings` (XPC to usernoted) runs every minute
  forever. Wired through `Telegram-Mac/packages-integration/hooks/SettingsHooksInstall.swift:393-395`. Upstream
  power-audit #9.
- **Today**: every reconnect or "Updating…" flip and every change of the own peer, presence, stars or TON state
  rebuilds the hidden Settings list and merges it on main. One notification-settings XPC call runs every minute, all
  day, per account.
- **Fix**: (1) `recurrentAuthorizationStatus`: re-query on `NSApplication.didBecomeActiveNotification` and on
  `keyWindowUpdater` becoming true (`distinctUntilChanged`, `isKey ? authorizationStatus : .complete()`), no timer.
  Permission can only change in System Settings, which makes Telegram inactive. (2) Gate the Settings `apply`
  pipeline on the tab being shown (`viewDidAppear`/`viewWillDisappear`, or M22's WindowVisibilityObserver plus "Settings
  is the selected tab"), letting the first emission make `ready` true at launch.
- **Gain**: 1,440 XPC round trips per day per account, and the offscreen rebuilds on connection, presence and balance
  changes. Small per event; always on.
- **Risk**: low. The tab shows the latest state on appear (one non-animated merge). The "notifications disabled"
  warning updates when the user returns from System Settings.
- **How to verify**: unit test with a fake key-window promise, a fake NotificationCenter and a counting provider: 0
  calls while inactive, 1 on becoming active. A SettingsUI test: no merges while the tab is not shown. Grep: no
  `suspendAwareDelay(1 * 60.0` left in UNUserNotifications.swift.
- **Size**: S
- **Confidence**: high

### R2-9. Fixed-rate UI timers: auto-night re-checks every 60 s, slow mode updates the interface 5×/s, and gift-auction previews tick 10×/s and leak — `todo` (group: perf)

- **Evidence**: `Telegram-Mac/app/AppDelegate.swift:722-731`: with an auto-night schedule or system-based theme,
  `.single(()) |> then(.single(()) |> delay(60, queue: main) |> restart)`, then (`:733-803`) `EDSunriseSet` and an
  AccountManager theme transaction every minute, hidden or not; system-based mode is already driven by
  `viewDidChangedAppearance` (Mac analogue of iOS R6). `packages/ChatUI/Sources/ChatUI/ChatController.swift:11621-11629`:
  slow mode, `delay(0.2, queue: .mainQueue()) |> restart` calls `chatInteraction.update(updateSlowMode)` (a full
  interface-state update) 5×/s for the whole period, hidden too (power-audit #19).
  `packages/ChatUI/Sources/ChatUI/WPArticleContentView.swift:192-193`: a gift-auction preview starts a 10 Hz main
  repeating timer with `completion: updateTime`. Corrected and stronger than reported: `updateTime` captures `self`
  strongly, SwiftSignalKit's `Timer` keeps `completion` (`SwiftSignalKit2/Source/Timer.swift:18,25-27`) and the view
  keeps the timer (`:96`); deinit (`:261-266`) never invalidates it. So the view and its timer form a retain cycle and
  the 10 Hz timer never stops, even after the preview is removed (power-audit #22).
- **Today**: about one main wake-up and one AccountManager transaction per minute for auto-night users; 5 Hz
  interface-state churn during slow mode; one endless 10 Hz main timer plus a leaked view per auction preview ever
  shown.
- **Fix**: auto-night: no timer for `systemBased`; for schedules, one `suspendAwareDelay(nextBoundary - now)` re-armed
  after it fires and on `NSCalendarDayChanged`/`NSSystemClockDidChange`/wake. Slow mode: 1 Hz aligned to the next
  whole second, stopped while hidden. Auction preview: `[weak self]` in the completion, 1 Hz aligned to the second,
  invalidate when `endDate <= now`, in `viewDidMoveToWindow(nil)` and in deinit.
- **Gain**: ~1,440 wake-ups and transactions per day for auto-night users, ~80% fewer slow-mode updates, and no leaked
  views or endless 10 Hz timers. Small in total but always on or long-lived.
- **Risk**: very low. A scheduled theme switch is exact instead of up to 60 s late.
- **How to verify**: unit tests for `nextAutoNightBoundary(schedule:now:)` against the existing `isDark` computation
  over 24 h of sample times; slow-mode tick count over 30 s (30, not 150); an auction view released from its window
  deallocates (weak reference nil) and its timer stops.
- **Size**: S
- **Confidence**: high

### R2-10. The small-group online counter makes two synchronous MTContext dispatches per member from the Postbox queue on every presence change — `todo` (group: perf)

- **Evidence**: `packages/TelegramContext/Sources/TelegramContext/PeerChannelMemberCategoriesContextsManager.swift:285-294`:
  inside the `combinedView(.peerPresences(≤200 ids))` map, each presence evaluates
  `account.network.globalTime > 0 ? account.network.globalTime - timestamp : 0`.
  `submodules/telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift:1226-1232` →
  `submodules/telegram-ios/submodules/MtProtoKit/Sources/MTContext.m:638-652`: `globalTime` →
  `globalTimeDifference` is `dispatchOnQueue:… synchronous:true` on `[MTContext contextQueue]` (the stall source M3
  removed from the 1 Hz loops). Used for every open supergroup with ≤200 members (`ChatController.swift:3968`).
- **Today**: up to 400 synchronous hops to the MTContext queue per emission, while the Postbox queue that every view and
  transaction uses waits behind them.
- **Fix**: read `account.network.globalTimeDifference` once per emission, outside the loop, and compute the offset
  from it.
- **Gain**: from up to 400 synchronous cross-queue dispatches per emission to 1. Microseconds each, but unbounded when
  MTContext is busy (reconnect, auth or config work).
- **Risk**: none; the same value read once.
- **How to verify**: a TelegramContext unit test with a stub network counting `globalTime` reads: one per 200-presence
  emission.
- **Size**: S
- **Confidence**: high

### R2-11. Launch creates and prepares seven AVAudioPlayers on the main thread and drops them at once — `todo` (group: perf)

- **Evidence**: `Telegram-Mac/app/AppDelegate.swift:437-451`: `AVAudioPlayer(contentsOf:)` + `prepareToPlay()` for
  opening.m4a, five voip_* sounds and sent.caf in `applicationDidFinishLaunching`; each player is a local released at
  the end of its iteration (power-audit #31c). Calls create their own players
  (`packages/TelegramCallsCore/Sources/TelegramCallsCore/CallAudioPlayer.swift:18`).
- **Today**: seven file opens, decodes and audio-queue preparations (which touch the output device) run on main during
  launch, and all of it is thrown away.
- **Fix**: delete the loop. If first-sound latency matters, prepare the one needed player lazily, off main, when a call
  starts.
- **Gain**: launch main-thread time (estimate a few to tens of ms) and one avoidable audio-device start per launch.
- **Risk**: none expected; the first call sound may start a few ms later.
- **How to verify**: an H11 `OSSignposter` interval around the block, cold launch to the login screen after
  `sudo purge`, before and after; `log stream --predicate 'subsystem == "com.apple.coreaudio"'` shows no output-device
  start at launch afterwards.
- **Size**: S
- **Confidence**: medium (the work is certain; the time is not measured)

### R2-12. Long chat exports run with no ProcessInfo activity, so App Nap and idle sleep can stall them — `todo` (group: perf)

- **Evidence**: `packages/ChatExportUI/Sources/ChatExportUI/ChatExportManager.swift:81-95` (the export runs
  `run.run()` on its own queue with no `beginActivity`); `:568-588`, `:890-907` (semaphore waits polled every 0.2 s per
  media download, with timeouts). No `beginActivity`/`performActivity` anywhere in `packages/` or `Telegram-Mac/`.
- **Today**: a big export downloads and writes media for minutes to hours. When the user switches away, App Nap can
  lower its priority and coalesce the 0.2 s waits; idle system sleep can suspend it halfway, and per-file timeouts
  then skip media. Not defeating App Nap is right for idle work (round 1); user-started bulk work is the exception.
- **Fix**: in `exportChatToHtml` wrap `run.run()` in
  `let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Exporting chat")` with
  `defer { ProcessInfo.processInfo.endActivity(activity) }`; use `.userInitiatedAllowingIdleSystemSleep` if the
  product prefers. Apply the same pattern to other multi-minute user-started jobs later.
- **Gain**: exports finish at full speed in the background and are not cut by idle sleep; App Nap stays in force
  otherwise.
- **Risk**: low. The activity must end on every path; `defer` in the queue block covers finish and cancel.
- **How to verify**: unit test with an injectable activity provider (begin and end balanced on finish, cancel and early
  return). With the account: `pmset -g assertions` during an export.
- **Size**: S
- **Confidence**: medium

### R2-13. Cold feature modules could be built `-Osize` — `todo` (group: perf)

- **Evidence**: upstream Release binary (`nanogram-macos-recon/dd-release/…`, arm64 `__text` 78.4 MB). Per-module
  `__text` from `nm`: WalletContext 2.48 MB, WalletUI 1.82, StarsUI 1.58, SettingsUI 1.23, StoriesUI 1.20,
  RichTextEditorUI 0.64, GroupCallScreenUI 0.56, InstantPageUI 0.54, WebAppUI 0.49, ImageCanvasUI 0.44, PassportUI
  0.41, QrStudioUI 0.40, ChatExportUI 0.36, CallsUI 0.35, PremiumUI 0.31 and smaller ones, ≈15 MB in total.
  `stage1:nanogram/Nanogram.xcconfig:16` (`SWIFT_OPTIMIZATION_LEVEL[config=Release] = -O` for every target) and the
  `$(…_$(TARGET_NAME))` lookup pattern already used at `:24,53`.
- **Today**: code that runs only when a wallet, stars, passport or export screen opens carries -O's inlining and
  specialization size: download, disk and resident text with no runtime benefit.
- **Fix**: `NANOGRAM_SWIFT_OPT_WalletUI = -Osize` (and the other cold modules), with
  `SWIFT_OPTIMIZATION_LEVEL[config=Release] = $(NANOGRAM_SWIFT_OPT_$(TARGET_NAME):default=-O)`. Keep hot modules at
  -O (TelegramCore, Postbox, TGUIKit, ChatUI, ChatListUI, TelegramMedia, SwiftSignalKit). Make sure release-direct and
  testflight use `xcodebuild archive`, so the ~100 MB symbol table a plain Release `build` leaves is stripped.
- **Gain**: an estimated 10-20% of the cold modules' code, ≈1.5-3 MB of `__TEXT`. No runtime gain. Low priority.
- **Risk**: low; slightly slower code in rarely opened screens.
- **How to verify**: `size -m -arch arm64` on the binary and the per-module `nm` script, before and after; `tg build
  --release` time.
- **Size**: S
- **Confidence**: low (size gain estimated; depends on cross-module optimization in Xcode's SwiftPM builds)

## modern: modern APIs and dead code

### R2-14. StoreKit 1 InAppPurchaseManager runs in builds that can never sell anything — `todo` (group: modern)

- **Evidence**: `Telegram-Mac/account/AccountContext.swift:231` (`lazy var inAppPurchaseManager … =
  InAppPurchaseManager(engine:)`, no `#if`; `:632-638` read the products only under `#if APP_STORE`).
  `packages/InAppPurchaseManager/Sources/InAppPurchaseManager/InAppPurchaseManager.swift:119-126`: init calls
  `SKPaymentQueue.default().add(self)` and `requestProducts()` (`SKProductsRequest` for `org.telegram.*` IDs). The
  lazy var is read unconditionally by StarsUI (`Star_ListScreen.swift:1303`, `PreviewStarGiftController.swift:1281`,
  `PremiumGiftingController.swift:499`) and PremiumUI (`PremiumBoardingController.swift:1328`,
  `PremiumStoreOperation.swift:53,111`). `stage1:tools/dev/tg:81-82` passes only `NANOGRAM STABLE` (+`NANOGRAM_MAS`);
  `APP_STORE` is never defined. Both editions use `org.klaipher.Nanogram`. About 20 StoreKit 1 deprecation warnings at
  macOS 15, all in this package.
- **Today**: the first Premium, Stars or gift screen registers a lifetime SKPaymentQueue observer (StoreKit agent over
  XPC) and sends an App Store product request for Telegram's IDs, which can never resolve for this bundle ID. The
  Release UI already treats the product list as empty.
- **Fix**: add a fork-owned `NoopInAppPurchaseManager: InAppPurchaseManagerProtocol`
  (`packages/TelegramContext/Sources/TelegramContext/InAppPurchase.swift:146`): `canMakePayments = true` (Release UI
  unchanged), `availableProducts = .single([])`, `buyProduct → .fail(.cantMakePayments)`, restore → failed, empty
  `finishAllTransactions`. In AccountContext: `#if APP_STORE InAppPurchaseManager(engine:) #else
  NoopInAppPurchaseManager() #endif`. A store edition would need StoreKit 2 and the fork's own products anyway.
- **Gain**: no StoreKit XPC, App Store request or transaction observer per account, and the only StoreKit 1 runtime
  path is gone. Mostly correctness and privacy; small energy gain.
- **Risk**: low. DEBUG loses `APP_STORE || DEBUG` store probing that never worked for this bundle ID.
- **How to verify**: a unit test that the factory returns the no-op type without `APP_STORE`; grep for unconditional
  `InAppPurchaseManager(`; after a Release build, no call site of `InAppPurchaseManager.init(engine:)`.
- **Size**: S
- **Confidence**: high

### R2-15. The dead NSUserNotificationCenter path kept by H24 for a 10.13 target the fork no longer has — `todo` (group: modern)

- **Evidence**: round-1 H24 keeps the < 10.14 path "while the shipped deployment target is 10.13";
  `stage1:nanogram/Nanogram.xcconfig:5` sets `MACOSX_DEPLOYMENT_TARGET = 15.0` for every target.
  `Telegram-Mac/utils/UNUserNotifications.swift:37-43` (`#available(macOS 10.14)` … else `UNUserNotificationsOld`),
  `:55-68` (else branch fakes `.authorized`), `:151-236` `UNUserNotificationsOld`, `:329` `#available(macOS 12.0)`.
  19 NSUserNotification* deprecation warnings, all in this file.
- **Today**: about 90 lines that can never run are compiled and warned about.
- **Fix**: delete `UNUserNotificationsOld` and the `#available` branches; construct `UNUserNotificationsNew` directly.
  The file is already fork-edited (H8, H24). Keep the `NSUserNotification` value type as an internal DTO for now.
  (The 60 s poll in the same file is R2-8.)
- **Gain**: dead code and 19 warnings removed. No runtime change.
- **Risk**: low.
- **How to verify**: a clean `tg warnings` build shows no NSUserNotification* warnings.
- **Size**: S
- **Confidence**: high

### R2-16. H17 kept a dead CVDisplayLink fallback behind `#available(macOS 14)` — `todo` (group: modern)

- **Evidence**: `packages/TGUIKit/Sources/SharedDisplayLinkSource.swift:82-88` (`ScreenDisplayLinkSource()` on 14+,
  else `LegacyDisplayLinkSource()`), `:158-246` (LegacyDisplayLinkSource, CVDisplayLink); `DisplayLinkAnimator.swift:31-110`
  class `DisplayLink`, only used by the legacy source; `Tests/TGUIKitTests/DisplayLinkThreadingTests.swift:76-99` test
  only the legacy source. CVDisplayLink calls warn "deprecated in macOS 15.0". The latest runtime commit `5a1bb3f0`
  even improved the legacy source's rate cache.
- **Today**: the replaced driver is still compiled, warned about, tested and maintained, but cannot run at the 15.0
  floor.
- **Fix**: `if #available(macOS 14.0, *) { return ScreenDisplayLinkSource() }; return nil` (the function already
  returns an optional, so the 10.13 manifest still compiles for `swift test`). Delete LegacyDisplayLinkSource, the
  `DisplayLink` class and their tests. All three files are already fork-modified.
- **Gain**: about 200 lines and all CVDisplayLink warnings removed from TGUIKit; one display-link implementation left.
- **Risk**: very low; the path is unreachable.
- **How to verify**: `grep -rn CVDisplayLink packages/TGUIKit/Sources` is empty; TGUIKitTests pass.
- **Size**: S
- **Confidence**: high

### R2-17. New fork-owned packages use tools 5.5, Swift 5 and a 10.13 floor, against stage 1's NanogramKit convention — `todo` (group: modern)

- **Evidence**: runtime-branch packages NanogramRuntime, ChatAppIntents, LocalAudioTranscription, NanogramDebug and
  VoiceRecorderInput: `swift-tools-version:5.5`, `.macOS(.v10_13)`; VP9Hardware: tools 6.0, `.v10_13`.
  `stage1:packages/NanogramKit/Package.swift`: tools 6.2, `.macOS(.v15)`, `.treatAllWarnings(as: .error)`;
  `stage1:nanogram/Nanogram.xcconfig:46-48` ("Our packages build in Swift 6 mode with warnings as errors"). Pre-15
  checks in fork code: ChatAppIntents (`@available(macOS 14)` on every type), NanogramRuntime (e.g.
  `LiteModePower.swift:54-58`), LocalAudioTranscription, VoiceRecorderInput; fork files inside upstream packages copy
  the pattern (`TGUIKit/PerformanceSignposts.swift`, `DecorativeLoopFrameRate.swift`, CrashReports
  `MetricReportCollector.swift`).
- **Today**: after the merge six fork packages will not follow the stage-1 rule (no Swift 6 checking, no warnings as
  errors) and carry `#available` branches for OS versions the app cannot run on.
- **Fix**: rewrite the six manifests from the NanogramKit template, then delete their pre-15 `#available`/`@available`
  lines and else branches (fork-only files, no upstream conflicts). For fork code inside upstream packages keep the
  checks, or raise only those manifests' `platforms` to `.v15`; do not bulk-edit upstream manifests. Add a stage-1
  lint that fails when a fork package declares less than `.v15` or Swift 5 mode.
- **Gain**: one floor, compile-time concurrency checking for fork code (it would catch R2-18), fewer dead branches.
  No runtime change.
- **Risk**: low to medium. Swift 6 mode surfaces Sendable and isolation errors that need real fixes; do it at merge
  time, one package per commit.
- **How to verify**: `swift build`/`swift test` per package in Swift 6 mode; `tg build` clean; no
  `#available(macOS 1[0-4]` in the six packages.
- **Size**: M
- **Confidence**: high

### R2-18. The App Intents data source blocks Swift-concurrency threads with `DispatchQueue.main.sync` — `todo` (group: modern)

- **Evidence**: `Telegram-Mac/packages-integration/hooks/ChatAppIntentsHooksInstall.swift:25-31` (`onMain` uses
  `DispatchQueue.main.sync` off main), used by `accountContexts()` and `isLocked`.
  `packages/ChatAppIntents/Sources/ChatAppIntents/ChatIntentsLogic.swift:109-115` (`unlockedSource` reads
  `source.isLocked`) runs inside `async` functions called from EntityQuery/perform on the cooperative pool; the
  `ChatIntentsDataSource` protocol has no actor isolation.
- **Today**: each Shortcuts or Spotlight entity query parks a cooperative-pool thread in a synchronous wait on main.
  That breaks Swift concurrency's forward-progress rule and can deadlock if main ever waits on intent work.
- **Fix**: make `ChatIntentsDataSource` `@MainActor` (or `isLocked`/`accountContexts()` async and main-actor), call it
  with `await`, delete `onMain`. Swift 6 mode (R2-17) enforces it.
- **Gain**: no blocked pool threads and no deadlock risk. Latency about the same.
- **Risk**: low.
- **How to verify**: ChatAppIntentsTests with a fake `@MainActor` source; run `suggested()` from a detached task while
  main is busy; it completes.
- **Size**: S
- **Confidence**: medium

### R2-19. GIF→MP4 on send runs the encoder in real-time mode and sleeps 100 ms on every back-pressure — `todo` (group: modern)

- **Evidence**: `packages/TGGifConverter/Sources/TGGifConverter/TGGifConverter.m:78`
  (`expectsMediaDataInRealTime = YES` for an offline source); `:101-170` loop with `[NSThread sleepForTimeInterval:0.1]`
  when `!readyForMoreMediaData` (`:169`). Caller: every GIF file send
  (`packages/TelegramMediaUtils/Sources/TelegramMediaUtils/FetchVideoMediaResource.swift:10-35`, via
  `LocalFileGifMediaResource` from `SenderController.swift:426`). The SDK header says non-real-time sources should
  leave the flag off and use `requestMediaDataWhenReadyOnQueue:usingBlock:`.
- **Today**: VideoToolbox runs in real-time mode (less quality per bit at 512 kbit/s), and each stall costs a fixed
  100 ms instead of resuming within milliseconds.
- **Fix**: `expectsMediaDataInRealTime = NO`; replace the loop with `requestMediaDataWhenReadyOnQueue:usingBlock:`
  (append while ready and frames remain, then `markAsFinished`/`finishWriting…`), checking `cancelHandler()` inside the
  block. Optional: 32BGRA for the pool and bitmap context (VideoToolbox's native input).
- **Gain**: shorter GIF send preparation (stalls cost ~0 instead of 100 ms each, up to seconds on long GIFs) and better
  quality per bit. Not measured.
- **Risk**: low; same output format.
- **How to verify**: an XCTest in the TGGifConverter package converting a generated 300-frame GIF: wall time, sleep
  count, output size and SSIM, before and after.
- **Size**: S
- **Confidence**: medium

### R2-20. The Lottie frame-cache map is wrapped in a deprecated, non-secure keyed archive around a plist — `todo` (group: modern)

- **Evidence**: `packages/TelegramMedia/Sources/LottieBufferCompressor.swift:178-185` (`PropertyListEncoder().encode(map)`
  then `NSKeyedArchiver.archiveRootObject(data, toFile:)`); `:305` (`NSKeyedUnarchiver.unarchiveObject(withFile:)`,
  deprecated 10.14, no secure coding) then `decodeDstData`/`PropertyListDecoder`. Runs on every cache open and save.
  `packages/TGUIKit/Sources/WindowSaver.swift:31`: `NSKeyedUnarchiver.unarchiveObject(with:)` on an NSCoding class.
- **Today**: each sticker or emoji cache open parses a keyed archive just to reach the plist inside, and each save
  builds one; both decode without class allow-lists.
- **Fix**: write the plist bytes directly (`data.write(to:options: .atomic)`), read with `Data(contentsOf:)`; if
  decoding fails and the bytes are a keyed archive, unwrap once with `NSKeyedUnarchiver.unarchivedObject(ofClass:
  NSData.self, from:)`, so existing caches stay valid without bumping the cache version. WindowSaver: adopt
  NSSecureCoding and `unarchivedObject(ofClass:from:)`/`archivedData(withRootObject:requiringSecureCoding: true)`.
  Leave the mtime touches (M29's cache lifetime) alone.
- **Gain**: one archive parse or build less per cache open and save (tens of µs, not measured); two non-secure
  deprecated calls gone.
- **Risk**: low with the legacy-read fallback.
- **How to verify**: TelegramMedia unit test: a map written by the old code reads through the new reader; new
  round-trip; a 1,000-load micro-benchmark old vs new.
- **Size**: S
- **Confidence**: medium

### R2-21. Theme switches snapshot the window through the obsoleted `CGWindowListCreateImage` via `dlsym` — `todo` (group: modern)

- **Evidence**: `packages/TGUIKit/Sources/Window.swift:1066-1077` (`windowImageShot()` via
  `dlsym(RTLD_DEFAULT, "CGWindowListCreateImage")`, integration commit `6fe2eb17`); the only caller is
  `packages/TelegramTheme/Sources/TelegramTheme/Appearance.swift:2244-2262` (image over the content, faded out over
  0.2 s after 0.05 s).
- **Today**: each animated theme or appearance change makes a synchronous WindowServer capture of the whole Retina
  window on main, through an API hidden from the compiler; when the symbol goes away the crossfade silently stops.
- **Fix**: drop the snapshot: add a `CATransition` (`.fade`, 0.2 s) to the content view's layer and apply the theme in
  the same transaction; delete `windowImageShot()`. Leave upstream's ModalMorphTransition as it is.
- **Gain**: no main-thread capture or full-window CGImage per theme switch; one obsoleted API less. Occasional, not hot.
- **Risk**: low to medium. Check that the fade covers layer-hosted children (Metal, AVSampleBufferDisplayLayer, the
  backdrop navbar) like the image did, and that a theme applied over several runloop turns does not show a half state.
- **How to verify**: toggle dark mode on the login screen with "follow system"; capture frames before and after.
- **Size**: S
- **Confidence**: medium

### R2-22. Dead code and a dead resource that go as whole-file or one-line deletions — `todo` (group: modern)

- **Evidence**: `packages/StatisticsUI/Sources/StatisticsUI/ChannelStatisticsController.swift` (the only WebKit1
  `WebView`, never instantiated; the only reference is the typealias at
  `Telegram-Mac/packages-integration/bridges/ControllerExtension.swift:20`). `packages/TelegramMedia/Sources/
  GIFPlayerView.swift:7-27` private `AlphaFrameFilter` (CIKL `CIColorKernel(source:)`, never referenced).
  `Resources/data/ocr_nn.bin` (136 KB) still in Copy Resources (`Telegram.xcodeproj/project.pbxproj:718`) after H12
  removed its only macOS reader. `packages/TelegramMedia/Sources/MediaPlayerFramePreview.swift:84` `NSLog("generated")`
  per scrub preview frame in Release. `packages/TGUIKit/Sources/TransactionHandler.swift:5-28` `OSSpinLock`
  (deprecated 10.12) with the handler run under the lock; only user `ChatController.swift:2602`.
- **Today**: deprecated WebKit1 and CIKL code compiled for nothing, a 136 KB model in every bundle, a log write per
  scrub frame, a spin lock in chat sending.
- **Fix**: delete ChannelStatisticsController.swift and the typealias; delete AlphaFrameFilter; add `ocr_nn.bin` to
  `EXCLUDED_SOURCE_FILE_NAMES` in `stage1:nanogram/Nanogram.xcconfig:34` (no pbxproj edit); delete the NSLog; in
  TransactionHandler use `os_unfair_lock` and call the handler after unlocking (or drop the lock with a main-thread
  assertion if all callers are on main). Optional: the stage-1 MainMenu.xib `SUUpdater` object, only if those xibs are
  touched anyway.
- **Gain**: 136 KB off the bundle, a few hundred lines and ~20 warnings removed, no log write per scrub frame.
- **Risk**: very low.
- **How to verify**: grep shows no references before deletion; `ocr_nn.bin` absent from the built bundle; no
  WebView/CIColorKernel(source:)/OSSpinLock warnings.
- **Size**: S
- **Confidence**: high

### R2-23. The video editor grabs a 1920 px still frame with zero tolerance on the main thread — `todo` (group: modern)

- **Evidence**: `packages/ImageCanvasUI/Sources/ImageCanvasUI/EditVideoController.swift:380-387` (`still(at:)`:
  `AVAssetImageGenerator`, zero tolerance, `maximumSize` 1920, synchronous `copyCGImage(at:actualTime:)`, deprecated
  at macOS 15), called from button actions `openCrop` `:497`, `openPaint`, `openTools` before the modal shows.
- **Today**: opening Crop, Paint or Tools decodes from the previous keyframe to the exact time on main: a visible stall
  on long-GOP HEVC or 4K clips (tens to hundreds of ms, not measured).
- **Fix**: `try await generator.image(at:)` (macOS 13) or `generateCGImageAsynchronously(for:)`, show the editor in the
  completion on the main actor (spinner after 100 ms), guard against double taps; keep zero tolerance. Leave the
  off-main `copyCGImage` sites alone.
- **Gain**: no main-thread stall when entering editor tools.
- **Risk**: low; the flow becomes asynchronous.
- **How to verify**: an XCTest with a generated 4K HEVC clip (2 s GOP) timing the mid-GOP still; a main-thread
  assertion in `still(at:)` after the change.
- **Size**: S
- **Confidence**: medium

### R2-24. Deprecation backlog at the 15.0 floor: triage instead of bulk migration — `todo` (group: modern)

- **Evidence**: `stage1:build-output/warnings-build.log` (clean Debug, 2026-11-03 01:29, before the Sparkle 2 commit
  and without the runtime branch): 637 unique deprecated/obsoleted warnings. Largest groups: synchronous AVAsset
  properties (~60), `kUTType*` (~45), AVSampleBufferDisplayLayer `enqueue`/`flush`/`status`/`isReadyForMoreMediaData`
  (~35: MediaPlayerView, GIFPlayerView, TransformImageView, SoftwareVideoLayerFrameManager), `copyCGImage(at:)` (10),
  `usingColorSpaceName` (17), OpenGL in TGVideoCameraGLRenderer (H21), StoreKit 1 (R2-14), SCNetworkReachability in
  MtProtoKit, SecKeychain in PasscodeKeychainScope, `Scanner.scanDouble`. About 290 `#available` checks below 15 remain,
  mostly in upstream files.
- **Today**: the warnings hide new real ones, and most deprecated calls sit in upstream files where edits cost merge
  conflicts every release.
- **Fix**: migrate only (1) APIs whose removal would break features: AVSampleBufferDisplayLayer calls move to
  `layer.sampleBufferRenderer` (macOS 14) in the TelegramMedia player files the fork already edits (R2-5 does
  MediaPlayerView); (2) anything in fork-owned files; (3) synchronous AVFoundation calls on main (R2-23). Leave
  `kUTType`, `usingColorSpaceName`, Scanner, off-main synchronous AVAsset loads and upstream `#available` checks until
  upstream changes them. In `tg warnings`, count deprecations per package so new ones in fork code fail the gate.
- **Gain**: a short, meaningful warning list and readiness for removals. Little runtime effect.
- **Risk**: medium for the renderer move (timebase wiring); low elsewhere.
- **How to verify**: `tg warnings` per-package deprecation counts; the player move through VideoPlayerLab/MediaPlaybackLab
  with a local file.
- **Size**: L
- **Confidence**: medium

## libs: external libraries

### R2-25. Stage 1's FFmpeg 9.0.2 bump drops M27's VideoToolbox patch, so the merge silently undoes M27's FFmpeg half — `todo` (group: libs)

- **Evidence**: runtime: `submodules/telegram-ios/submodules/ffmpeg/Sources/FFMpeg/ffmpeg-8.1.2/libavcodec/videotoolbox.c`
  carries two "Local patch (Nanogram)" hunks (core `d6c3ef8`, M27). Stage 1: `stage1:core-xprojects/ffmpeg/ffmpeg/build.sh`
  `FF_VERSION="9.0.2"`, only `ffmpeg-9.0.2` exists, and its `videotoolbox.c` has 0 patch markers (checked). The iOS
  fork's `Telegram-iOS/submodules/ffmpeg/Sources/FFMpeg/ffmpeg-9.0.2/libavcodec/videotoolbox.c` has both. The runtime's
  FFMpegBinding SharedHeaders are lavc 62, stage 1's lavc 63.
- **Today**: merging runtime into stage 1 gives a modify/delete conflict on the 8.1.2 file. Taking stage 1's tree (the
  natural resolution) builds 9.0.2 unpatched: every hardware GIF frame writes colour attachments to its IOSurface and
  waits on the VT session again, while M27 stays marked done. `FFMpegVideoToolboxAttachmentTests` will fail.
- **Fix**: copy the iOS fork's 9.0.2 `videotoolbox.c` into stage 1's tree (or re-apply `d6c3ef8`'s hunks); take stage
  1's lavc 63 headers. The framework stamp tracks the FFmpeg source dir, so libavcodec rebuilds; this also clears M27's
  "FFmpeg rebuild pending". Add it to the merge checklist.
- **Gain**: keeps M27's per-frame savings on every playing hardware GIF (iOS measured 0.74 s of IOSurface IPC per
  session for the attachments alone) and the decode latency without the synchronous wait.
- **Risk**: low; the same patch ships on iOS with 9.0.2.
- **How to verify**: `grep -c 'Local patch (Nanogram)'` = 2 in the merged tree; MediaPlayer tests
  FFMpegVideoToolboxAttachmentTests, FFMpegFileReaderPixelBufferReuseTests, FFMpegHardwareFallbackTests; DecodeBench
  `decode --mode hw` on H.264 GIF mp4s against the runtime build.
- **Size**: S
- **Confidence**: high

### R2-26. Software video decode, AV1 included, is single-threaded because no codec context sets `thread_count` — `todo` (group: libs)

- **Evidence**: `ffmpeg-8.1.2/libavcodec/options_table.h:215` ("threads" default 1, 0 = auto);
  `libavcodec/libdav1d.c:215,238` (`s.n_threads = FFMIN(c->thread_count, DAV1D_MAX_THREADS)`, so dav1d gets 1 thread);
  `submodules/telegram-ios/submodules/FFMpegBinding/Sources/FFMpegAVCodecContext.m:29-37` sets only `max_pixels`; no
  `thread_count`/`thread_type` anywhere in FFMpegBinding, MediaPlayer or packages (checked). AV1 is software wherever
  `VTIsHardwareDecodeSupported(AV1)` is false (M1/M2); scrub previews decode H.264/HEVC in software
  (`UniversalSoftwareVideoSource`).
- **Today**: on M1/M2 a directly sent AV1 video decodes on one dav1d thread (H6 keeps HLS off AV1 there); 1080p60 or
  4K AV1 can fall behind real time. Scrub previews decode keyframe-to-target on one thread.
- **Fix**: add `-[FFMpegAVCodecContext setThreadCount:]` (and `setThreadType:`), called before `avcodec_open2`. For the
  libdav1d path use 0 (auto) or `min(activeProcessorCount, 8)`; for UniversalSoftwareVideoSource 0 with frame threading.
  Keep 1 for GIFs, stickers and video emoji (many small instances) and for VideoToolbox contexts. Gate on ≥720p if
  small clips matter.
- **Gain**: AV1 on M1/M2 plays at rates one thread cannot sustain; per-frame wall time drops ~3-5× with 4-8 threads,
  total CPU about the same (+5-10%). Faster scrub previews. Estimates.
- **Risk**: higher momentary CPU; frame threading adds ~2-3 frames of start latency and holds 2-3 extra frames.
- **How to verify**: a DecodeBench `av1` mode (FFMpegFileReader, no hardware) comparing fps, wall time and CPU for
  thread_count 1 vs 0 on 1080p and 4K samples; a unit test that the AV1 software reader's context has
  `thread_count != 1`.
- **Size**: S
- **Confidence**: medium

### R2-27. FFmpeg is configured with components the Mac never uses and two component names that do not exist — `todo` (group: libs)

- **Evidence**: `stage1:core-xprojects/ffmpeg/ffmpeg/build.sh:64` `--enable-encoder=libvpx_vp9,aac_at`, `:68`
  `--enable-muxer=mp4,matroska,mpegts`; their only users (FFMpegVideoWriter, FFMpegLiveMuxer, FFMpegOpusTrimmer,
  FFMpegRemuxer) have no Mac Swift caller (the one site, `FetchVideoMediaResource.swift:21`, is commented out;
  checked). `:65-66` `--enable-demuxer=…libopus…`, `--enable-parser=…libopus`: FFmpeg has no component of that name
  (the parser is `opus`), so configure ignores them. `stage1:core-xprojects/ffmpeg/build/scratch/arm64/config.h`:
  `CONFIG_NETWORK 1`, `CONFIG_SECURETRANSPORT 1`, `CONFIG_BZLIB 1`, `CONFIG_ICONV 1`, `CONFIG_APPKIT 1` (autodetected).
- **Today**: the binary carries three muxers, a VP9 encoder wrapper, AAC encoder glue, avformat's network layer and
  SecureTransport TLS glue with no Mac caller.
- **Fix**: drop the encoder and muxer lists for the Mac build; add `--disable-network --disable-securetransport
  --disable-bzlib --disable-iconv --disable-appkit --disable-avfoundation --disable-coreimage --disable-metal
  --disable-sdl2`; replace the `libopus` parser/demuxer names with `opus` only if an Opus parser is wanted.
- **Gain**: a smaller link set (a few hundred KB, estimate), less parsing and TLS attack surface, a slightly shorter
  FFmpeg build. No runtime CPU change.
- **Risk**: a future Mac muxing feature would need them back.
- **How to verify**: `nm libavformat.a | grep -E 'ff_(mp4|matroska|mpegts)_muxer'` is empty, `CONFIG_NETWORK 0`; the
  app links; MediaPlayer SwiftPM tests pass.
- **Size**: S
- **Confidence**: medium

### R2-28. Native library builds run serial makes, OpenSSL's feature list is dead code, and two libraries clone from GitHub on every rebuild — `todo` (group: libs)

- **Evidence**: `stage1:build-output/frameworks-timing.tsv` (OpenSSL 129 s; run1 197 s) and the reviewer's run1 TSV
  (OpenH264 59 s, libopus 43 s, libvpx 40 s). Serial `make` without `-j`: `stage1:core-xprojects/openssl/OpenSSLEncryption/build.sh:153`,
  `libopus/libopus/build.sh:78`, `libvpx/libvpx/build.sh:77`, `libwebp/libwebp/build-cmake.sh`,
  `OpenH264/OpenH264/build.sh:44`. OpenSSL `MINIMAL_FLAGS` (`:49`) and `DEFAULT_FLAGS` (`:140`) are never used; `:151`
  Configure gets only `no-shared no-tests`. `:24` and OpenH264 `:19` `git clone -b <tag> --depth 1`, while opus,
  libwebp and libjpeg-turbo use SHA-256-checked tarballs. `webrtc/webrtc/build.sh:40`
  `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0` (every other library is 15.0).
- **Today**: a clean or version-bumped native build spends ~5-6 minutes in serial makes; OpenSSL builds every
  algorithm (post-quantum, SM, QUIC) and keeps them linked; OpenSSL and OpenH264 rebuilds need network.
- **Fix**: `-j"$(sysctl -n hw.logicalcpu)"` on those makes. A curated OpenSSL Configure list (start from `no-quic
  no-engine no-dso no-autoload-config no-legacy no-sm2 no-sm3 no-sm4 no-aria no-camellia no-seed no-idea no-bf no-cast
  no-rc2 no-rc4 no-rc5 no-mdc2 no-whirlpool no-srp no-gost no-ct no-cms no-ts no-ssl3 no-comp no-docs`; keep TLS/DTLS,
  EC, RSA, DH, GCM, ChaCha/Poly1305), delete the dead arrays. Vendor OpenSSL 3.5.9 and OpenH264 2.7.0 tarballs with
  SHA-256 checks. Pass `$MACOSX_DEPLOYMENT_TARGET` to tg_owt. Hand this over to stage 2's build-speed work.
- **Gain**: about 3-4 minutes off every clean native build, a smaller libcrypto (0.5-1 MB, estimate), no openssl.cnf
  lookup at init, offline builds.
- **Risk**: low for `-j`. A disabled algorithm some consumer needs fails at link or runtime: check with a link plus a
  1:1 call, a group call and the tde2e tests.
- **How to verify**: `configure_frameworks.sh` with `BUILD_TIMING_LOG`, compare TSVs; `nm libcrypto.a | grep -c
  ossl_ml_dsa` → 0; tde2e and tgcalls host tests; `otool -l … | grep minos` → 15.0 for tg_owt.
- **Size**: S
- **Confidence**: high

### R2-29. Group calls run RNNoise every 10 ms even with noise suppression off; the non-48 kHz path allocates per frame and drops its output — `todo` (group: libs)

- **Evidence**: `submodules/tgcalls/tgcalls/group/GroupInstanceCustomImpl.cpp:772-779`: `rnnoise_process_frame` runs
  whenever `sourcePeak ≥ 0.01`, only for `vadProbability`; the denoised samples are copied only if `isEnabled`.
  `:756-764`: when `num_frames != 480`, a `new webrtc::AudioBuffer(…)` per 10 ms frame, deleted at `:862-864`; NS and
  the external-sample mix write into that temporary buffer, so on this path their output is lost. iOS audit R18
  describes the same code.
- **Today**: with the mic open and audible in a group call, RNNoise runs at 100 Hz just for the speaking indicator, even
  with noise suppression off. On the Mac the ADM likely delivers 48 kHz, so the allocation/lost-output path is probably
  latent.
- **Fix**: with NS off, skip rnnoise and drive VAD from the existing peak/history hysteresis (or AGC2's RNN VAD if
  linked). Keep one member AudioBuffer per input rate and copy the 48 kHz result back (`CopyTo`). Land it once in the
  shared tgcalls with iOS R18.
- **Gain**: about 1% of a P-core during unmuted group calls with NS off (estimate); ~100 allocations/s and a correctness
  fix if the non-48 kHz path ever triggers.
- **Risk**: the speaking indicator may react differently with NS off; tune thresholds against today's VAD output.
- **How to verify**: a host C++ test feeding 1,000 frames at 16 and 48 kHz through the post-processor: zero `new` per
  frame, NS output reaches the original buffer; `Process()` time with NS off.
- **Size**: S
- **Confidence**: medium

### R2-30. WebRTC's debug-log threshold is `LS_INFO` in release for 1:1 calls, so every INFO line is formatted and does a CFPreferences lookup — `todo` (group: libs)

- **Evidence**: `submodules/tgcalls/tgcalls/v2/InstanceV2Impl.cpp:2261-2266` (`LogToDebug(LS_INFO)` outside DEBUG),
  `InstanceImpl.cpp:30`, `v2/InstanceV2ReferenceImpl.cpp:1647`; the group path already uses `LS_NONE` in release
  (`group/GroupInstanceCustomImpl.cpp:4529-4532`). `submodules/tg_owt/src/rtc_base/logging.cc:211-212` (`severity >=
  g_dbg_sev` → `OutputToDebug`), `:359-374` (on Mac + NDEBUG each call builds `DefaultLogLine()` and runs
  `CFBundleGetIdentifier` + `CFPreferencesGetAppBooleanValue("logToStdErr")`, normally false), `:440-444` (`IsNoop` is
  false for INFO, so lines are formatted even with no sink). Round-1 M18 fixed only the screencast instance.
- **Today**: during 1:1 calls every `RTC_LOG(LS_INFO)` on any WebRTC thread pays a string build and a preferences
  lookup and outputs nothing; with an empty log path all INFO lines are still formatted.
- **Fix**: release builds call `LogToDebug(LS_NONE)`; keep `AddLogToStream(sink, LS_INFO)` when a log path exists;
  keep VERBOSE/INFO under DEBUG.
- **Gain**: microseconds per INFO line on WebRTC threads (mostly at set-up and network changes); with no log path INFO
  formatting stops entirely. Small.
- **Risk**: none; debug output is already suppressed in release.
- **How to verify**: a host benchmark under NDEBUG: 100k `RTC_LOG(LS_INFO)` with LS_INFO vs LS_NONE, with and without a
  sink; call log files keep their content.
- **Size**: S
- **Confidence**: high

### R2-31. Rust profiles: tlottie alone unwinds, and wallet-engine builds crate types nobody links — `todo` (group: libs)

- **Evidence**: `stage1:core-xprojects/tlottie/build.sh:57-66` (`cargo rustc --release --crate-type staticlib --config
  'profile.release.lto=false'`, no panic setting); `stage1:submodules/tlottie/Cargo.toml` `[profile.release]` has no
  `panic = "abort"`; mtproto-engine and wallet-engine set `panic = "abort"`. tlottie has no `catch_unwind` and an
  `extern "C"` API, so a panic aborts anyway. `rust_start_panic` is defined in both `libtlottie.a` and
  `libmtproto_engine_ffi.a` (checked with `nm`), so the linker keeps whichever loads first. wallet-engine
  `crate-type = [rlib, staticlib, cdylib]` built with plain `cargo build`. The default aarch64-apple-darwin target
  features are already the Apple M1 set.
- **Today**: tlottie's per-frame renderer carries landing pads and unwind tables it can never use; the panic runtime
  depends on archive link order; every wallet build links an unused cdylib and rlib.
- **Fix**: add `--config 'profile.release.panic="abort"'` to tlottie's call; build wallet-engine with `cargo rustc --lib
  --crate-type staticlib`. Leave `target-cpu` unset (apple-m2+ would crash on M1), tlottie LTO off, wallet at
  opt-level "z". Longer term, one umbrella staticlib for all three crates gives one std.
- **Gain**: smaller tlottie text (a few percent, estimate), slightly better hot-loop codegen, a deterministic panic
  runtime, a shorter wallet build.
- **Risk**: low.
- **How to verify**: `size -m` / `__eh_frame` size of libtlottie.a before and after; RenderBench or LottieCacheLab frame
  time A/B; the app links with no duplicate-symbol warnings.
- **Size**: S
- **Confidence**: medium

### R2-32. Sparkle checks hourly and again on every emission of the network-settings preference — `todo` (group: libs)

- **Evidence**: `stage1:Telegram-Mac/updater/NanogramUpdater.swift:241-244` (`updater.start()`, then
  `updateCheckInterval = 60 * 60`, persisted), `:253-263` (`check()` → `checkForUpdatesInBackground()`);
  `stage1:Telegram-Mac/app/AppDelegate.swift:1174-1192`: `preferencesView(keys: [networkSettings]) |> delay(5.0)`
  with no `distinctUntilChanged`; each emission calls `setAppUpdaterBaseDomain` (an empty function under Nanogram,
  `NanogramUpdater.swift:288`) and `updater_resetWithUpdaterSource(.external…)` → `check()`. Sparkle 2's own default
  interval is one day. Round 1 dropped "3 small HTTPS requests per hour" for the old internal updater; this is the new
  Sparkle 2 driver's own setting plus the extra trigger.
- **Today**: the direct edition fetches the appcast every hour, at every launch and every time the network-settings
  entry is rewritten (proxy toggles, settings sync), even minutes after the last check.
- **Fix**: set `SUScheduledCheckInterval` in the direct edition's Info.plist (86400, or 21600 at most) instead of
  assigning it after `start()`; in `check()`, skip background checks when `lastUpdateCheckDate` is younger than the
  interval; drop the networkSettings subscription for NANOGRAM (or `distinctUntilChanged` on the URL prefix).
- **Gain**: about 20 fewer HTTPS round trips and network wake-ups per day per direct install. Small.
- **Risk**: updates are seen up to the interval later; "Check for Updates…" stays immediate.
- **How to verify**: a NanogramKit UpdateFlow test with a fake clock and stub updater: five networkSettings emissions →
  one background check.
- **Size**: S
- **Confidence**: high

### R2-33. Profile-guided optimization for tlottie, the one hot native library where a profile needs no account — `todo` (group: libs)

- **Evidence**: `stage1:core-xprojects/tlottie/build.sh:57-66` (no `-Cprofile-use`); `CLANG_USE_OPTIMIZATION_PROFILE = NO`
  in the project. `stage1:submodules/tlottie/Cargo.toml` has a `tlottie-cli` bin (feature `cli`); ~377 bundled `.tgs`
  under `Resources/tgs` (corrected from 383) form a training corpus. rustc's PGO flow: `-Cprofile-generate`,
  `llvm-profdata merge`, `-Cprofile-use`.
- **Today**: every frame not served from the LZ4 frame cache is rasterized by tlottie built without a profile: first
  loops, cache rebuilds, panels. FFmpeg, dav1d and libvpx are hand-written NEON (poor PGO targets); app Swift PGO would
  need an account.
- **Fix**: an opt-in `TLOTTIE_PGO=1` path in build.sh: build tlottie-cli with `-Cprofile-generate`, render every
  bundled `.tgs` for one loop at 40, 100 and 416 px, merge with the toolchain's `llvm-profdata`, build the staticlib
  with `-Cprofile-use`. Commit the `.profdata` next to the toolchain pin; regenerate on tlottie or Rust bumps.
- **Gain**: typical Rust PGO gains on branchy rendering code are 5-15% (estimate), on uncached Lottie frames only.
- **Risk**: none for output; build-time cost and profile drift on bumps.
- **How to verify**: DecodeBench/RenderBench ns/frame over the corpus with and without the profile; bit-identical
  frames (`compare_rgba.py`).
- **Size**: M
- **Confidence**: low (measure before adopting)

## db: database and MediaBox

### R2-34. StorageBox runs one SQLite write transaction each time a fetch starts and for every downloaded chunk — `todo` (group: db)

- **Evidence**: `submodules/telegram-ios/submodules/Postbox/Sources/MediaBox.swift:663-665` and `:879-881`
  (`fetchedResourceData`/`fetchedResource` call `storageBox.add(...)` on every fetch start, the latter before checking
  for a complete file); `StorageBox/StorageBox.swift:457-465` (`add` = begin, `internalAdd`, commit; `internalAdd`
  always rewrites `hashIdToInfoTable`); `MediaBoxFileContextV2Impl.swift:584` (`storageBox.update` after every chunk
  write; M28 batched only the `.meta` map). Each lookahead `fetchInRange` goes through this path
  (`packages/TelegramMedia/Sources/ChunkMediaPlayerDirectFetchSourceImpl.swift:636-646`). iOS `80947bac` and
  `a566a470` (verified to exist) are not in the Mac core; round 1 listed them under "Not checked".
- **Today**: visible media, stickers, avatars and every video lookahead range start a fetch, each a BEGIN
  IMMEDIATE/COMMIT on StorageBox that rewrites at least one page even when nothing changed; every 16-512 KB chunk adds
  another. Scrolling media or streaming video gives hundreds of small WAL commits per minute.
- **Fix**: port the StorageBox parts of iOS `80947bac` and `a566a470`: a two-generation `StorageBoxRegistrationCache`
  (`add()` without a size returns early when known; reset/remove/clear forget their ids), and `update(id:size:)`
  batched into one transaction after 1 s, at 64 pending, or before any other StorageBox transaction.
- **Gain**: iOS measured −75% StorageBox transactions in its registration benchmark and 500 size updates 71 → 9 ms.
  Fewer WAL bytes and checkpoint fsyncs while scrolling media and downloading.
- **Risk**: low. A crash loses at most ~1 s of size bookkeeping (the MediaBox scan re-adds it); the storage-usage UI
  can lag by up to 1 s.
- **How to verify**: port iOS `StorageBoxRegistrationTests.swift` and `StorageBoxBatchedUpdateTests.swift` into the Mac
  Postbox test target (next to StorageBoxPeerStatsTests); per-peer and per-type stats identical with and without
  batching; the 500-update benchmark.
- **Size**: M
- **Confidence**: high

### R2-35. Video readers reopen and stat the media file for every 64-256 KB read, and the lookahead re-checks the cache per read — `todo` (group: db)

- **Evidence**: `submodules/telegram-ios/submodules/MediaPlayer/Sources/FFMpegFileReader.swift:27-38` (`.resource`
  source: every ≤256 KB read calls `mediaBox.internal_resourceData`); `Postbox/Sources/MediaBox.swift:705-731`
  (`internal_resourceData`: `timeBasedCleanup.touch` queue hop, new `ManagedFile` open, `getSize` fstat, seek, close on
  release), `:733-744` (`internal_resourceDataIsCached`: lstat of the complete path, or a map check);
  `packages/TelegramMedia/Sources/ChunkMediaPlayerDirectFetchSourceImpl.swift:10-56,195-198,649-659` (the Mac copy of
  the lookahead: a MediaBox signal, queue hop, Data copy and semaphore wait per 256 KB read, plus `isDataCachedInRange`
  per read). iOS `c6a802aa` and `b3627d53` are not ported.
- **Today**: while a video or GIF plays or loops, each demuxer read on the playback reader and the lookahead runs
  open/fstat/lseek/read/close plus a touch hop; the lookahead adds an lstat per read. iOS sampled 369 of 975 lookahead
  samples in lstat.
- **Fix**: (a) port `c6a802aa` into the core FFMpegFileReader: once complete, keep one `ManagedFile` and seek/read on
  it. (b) port `b3627d53` into the Mac `ChunkMediaPlayerDirectFetchSourceImpl.swift`: subscribe once to MediaBox's live
  range status (M28's `liveFileMaps`), answer `isDataCachedInRange` from memory, and once complete read with `pread`
  through `ManagedFile.read(_:_:at:)`.
- **Gain**: several syscalls and a queue hop per 256 KB read removed during every playback (iOS: MediaBox calls per
  lookahead run 1-14 → 0), and with them the per-range StorageBox transactions of R2-34.
- **Risk**: low to medium. A file deleted by cache clear while open stays alive until the reader closes it. The
  lookahead's reported state must stay identical (the iOS test pins it).
- **How to verify**: port iOS `FFMpegLookaheadFileAccessTests.swift` with its fixtures into the Mac MediaPlayer test
  target and adapt it to the TelegramMedia copy: 0 MediaBox getData/isCached per run, identical state; `fs_usage`
  open/lstat counts while DecodeBench plays a local fixture.
- **Size**: M
- **Confidence**: high

### R2-36. MediaBox re-touches (`utime`) every used file every 10 s — `todo` (group: db)

- **Evidence**: `submodules/telegram-ios/submodules/Postbox/Sources/TimeBasedCleanup.swift:582-611` (each path touched
  in a 10 s window gets `utime(path, nil)`, every window, with no memory of recent touches); `MediaBox.swift:707-709`
  (per `internal_resourceData` read) and touches at file-context creation and fetch sites. iOS `2398d68d`
  (RecentFileTouches) is not ported.
- **Today**: every avatar, sticker, emoji or video file in use gets a `utime` and an APFS metadata write every 10 s for
  as long as it is used. iOS measured 0.49 s of utime per device session.
- **Fix**: port RecentFileTouches: path → last-touch time (300 s interval, ≤20,000 entries, pruned by age);
  `processScheduledTouches` touches only paths not touched within the interval and returns early when none are left.
- **Gain**: almost all repeated utime syscalls and metadata writes on long-lived screens removed; fewer utility-queue
  wake-ups.
- **Risk**: low. mtime can be up to 5 min stale; cleanup works in hours and days.
- **How to verify**: port the RecentFileTouches part of iOS `MediaBoxFileSystemEfficiencyTests.swift` next to
  TimeBasedCleanupTests; `fs_usage -f filesys` utime counts on the Debug app.
- **Size**: S
- **Confidence**: high

### R2-37. Cache eviction runs once per launch and never again; schedule it with NSBackgroundActivityScheduler — `todo` (group: db)

- **Evidence**: `Postbox/Sources/TimeBasedCleanup.swift:366-372` (`setMaxStoreTimes` rescans only when a value
  changes), `:575-579` (`scanOnce |> delay(scanDelay)`: one scan after setup, no repeat); `TelegramCore/Sources/Account/
  Account.swift:1615-1623` (`sharedData |> take(1)` → `setMaxStoreTimes` once); `TelegramCore/Sources/Utils/
  AutomaticCacheEviction.swift:63-77` (re-runs only on settings change). `MediaBox.swift:214-217` is a one-shot sweep of
  stale empty partial files 30 s after launch (corrected: not a size sweep). No `NSBackgroundActivityScheduler` or
  `xpc_activity` anywhere in the app.
- **Today**: size and age limits, per-chat timeouts and the 1 h short-lived limit are enforced only right after launch
  and when the user changes a storage setting. A Mac client runs for days or weeks, so `/short-cache`, `/cache` and
  `/animation-cache` grow past the user's limits meanwhile, and the single scan adds a full directory walk to the
  launch window.
- **Fix**: add `MediaBox.rescanCache()` (calls the cleanup's `resetScan` with the stored values, plus the stale-partial
  sweep) and `AutomaticCacheEvictionContext.rerun()`, Mac-only (`#if os(macOS)` or a hook). In the app own one
  `NSBackgroundActivityScheduler(identifier: "<bundle id>.cache-eviction")`, `repeats = true`, `interval = 6 h`,
  `tolerance = 2 h`, `qualityOfService = .background`; in `schedule`, rescan each active account, check
  `shouldDefer` between accounts (`completion(.deferred)`), else `.finished`. Optionally drop the fixed first scan in
  favour of the scheduler. Never for the logged-out auth MediaBox. Shares its scheduler with R2-38.
- **Gain**: disk use stays within the configured limits over long uptimes; launch can be free of the walk; the system
  picks idle or AC-power moments.
- **Risk**: low. The scan already runs at background QoS with cancellation; an evicted file still on screen is
  refetched, as after a launch.
- **How to verify**: a Postbox SwiftPM lab: MediaBox in a temp dir, files older than the limit added after the first
  scan, `rescanCache()` removes them (today they survive until relaunch); scheduler wiring through a protocol wrapper
  (fake fire; `shouldDefer = true` → `.deferred`).
- **Size**: M
- **Confidence**: high

### R2-38. The account database never shrinks: no VACUUM is scheduled, and `vacuum()` crashes on any failure — `todo` (group: db)

- **Evidence**: `Postbox/Sources/Postbox.swift:4589-4595` (`optimizeStorage` → `valueBox.vacuum()`; no caller in
  Telegram-Mac, packages or TelegramCore); `SqliteValueBox.swift:2529-2534` (VACUUM + `wal_checkpoint(TRUNCATE)` behind
  `precondition`: SQLITE_BUSY from TelegramShare, a full disk or an I/O error crashes); `TelegramCore/Sources/
  AccountManager/AccountManagerImpl.swift:415` (the only caller, a launch VACUUM of accounts-metadata, inherits the
  crash). `auto_vacuum` is never set. iOS `6b815d18` is not ported.
- **Today**: deleted chats, cleared history, churning cache tables and StorageBox removals leave free pages that are
  never returned; `db_sqlite` keeps its high-water size forever and live pages scatter, hurting cache locality for
  every SQLCipher page decrypt.
- **Fix**: port iOS `6b815d18`: `vacuum()` logs busy/full/I/O/read-only/OOM and returns false;
  `Postbox.optimizeStorageIfNeeded()` vacuums only when `freelist_count / page_count ≥ 25%`, at most once per 7 days,
  and only with free disk ≥ 2× the live data. Trigger it from R2-37's NSBackgroundActivityScheduler, only while no
  window is key (VACUUM holds the Postbox queue).
- **Gain**: returns ≥25% of the file when fragmented (often hundreds of MB on long-lived accounts), denser hot pages,
  and a launch-time crash path turned into a logged no-op.
- **Risk**: medium if mis-scheduled: VACUUM rewrites and re-encrypts the whole file (seconds to tens of seconds) and
  blocks Postbox transactions; the WAL grows to about the database size until the TRUNCATE checkpoint.
- **How to verify**: port iOS `SqliteValueBoxVacuumTests.swift` (fragmented → compacted with identical data; compact
  left alone; no room skips; another connection holding BEGIN IMMEDIATE fails without crashing; 7-day schedule) on an
  encrypted temp value box.
- **Size**: M
- **Confidence**: high

### R2-39. M9 port gap: a corrupt FTS5 search index deletes the whole account database — `todo` (group: db)

- **Evidence**: `Postbox/Sources/SqliteValueBox.swift:80-99` (`step()`: `SQLITE_CORRUPT` with `pathToRemoveOnError` →
  `removeDatabaseFiles` + `preconditionFailure`); FTS statements step through it (`fullTextMatch`, `fullTextSet`,
  `fullTextRemove`). No extended result codes are enabled, so FTS5's `SQLITE_CORRUPT_VTAB` arrives as `SQLITE_CORRUPT`.
  Core commit `0319e83caf` says it ports iOS `9dbf0f93` "without … the FTS self-heal" (checked).
- **Today**: damage to the `ft*` shadow tables (the index only) makes a search or message insert delete `db_sqlite`,
  `-wal` and `-shm` and crash; the whole local history is re-downloaded.
- **Fix**: port the rest of iOS `9dbf0f93`: `stepFullText`/`isRebuildableFullTextCorruption` (primary SQLITE_CORRUPT and
  `sqlite3_extended_errcode == SQLITE_CORRUPT_VTAB`), `runFullTextStatement`, `rebuildFullTextIndex` (`INSERT INTO
  ftN(ftN) VALUES('rebuild')`, once per table and connection, owner only). Plain SQLITE_CORRUPT keeps today's behaviour.
- **Gain**: a rare total local data loss becomes an index rebuild. Robustness, no efficiency gain.
- **Risk**: low; confined to FTS statements.
- **How to verify**: port iOS SqliteValueBoxConnectionTests `testOnlyCorruptVirtualTableIsRebuildable`,
  `testOwnerRebuildsACorruptFullTextIndexInsteadOfDeletingTheDatabase`, `testNonOwnerLeavesACorruptFullTextIndexAlone`.
- **Size**: S
- **Confidence**: high

### R2-40. Single-queue SQLite connections are opened `SQLITE_OPEN_FULLMUTEX`, and recommended compile options are missing — `todo` (group: db)

Merged from two reviewers (libraries and database).

- **Evidence**: `Postbox/Sources/Database.swift:78-83` (read-write: `SQLITE_OPEN_FULLMUTEX`; read-only: no flag, which is
  serialized under `SQLITE_THREADSAFE=1`); `submodules/telegram-ios/submodules/sqlcipher/Package.swift:35`
  (`THREADSAFE=1`). SqliteValueBox asserts single-queue use in 57 places (`precondition(self.queue.isCurrent())`);
  each connection (Postbox, two StorageBoxes, AccountManager) belongs to one Queue. In serialized mode
  `sqlite3_step`, binds and every `sqlite3_column_*` enter and leave the connection mutex. `SQLITE_OMIT_SHARED_CACHE`,
  `SQLITE_MAX_EXPR_DEPTH=0`, `SQLITE_LIKE_DOESNT_MATCH_BLOBS`, `SQLITE_USE_ALLOCA` are not set; Postbox uses no shared
  cache and no LIKE/GLOB. SQLite docs: NOMUTEX (multi-thread mode) is safe when one thread uses a connection at a time;
  `THREADSAFE=0` is "about 2% faster". Merge note: `SQLITE_ENABLE_QPSG` (M9) is only in the runtime's Package.swift.
- **Today**: every range row costs about five uncontended recursive mutex lock/unlock pairs on a connection only ever
  used from its own queue.
- **Fix**: first add `precondition(queue.isCurrent())` to the public SqliteValueBox entry points that lack it
  (`readWrite`, `filteredRange`, `renameTable`, `fullText*`, `count`, `removeAllFromTable`, `removeTable`, `vacuum`).
  Then open with `SQLITE_OPEN_NOMUTEX` (and `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`), with a DEBUG switch back to
  FULLMUTEX for A/B. Add the four defines; keep `THREADSAFE=1`; keep QPSG when merging.
- **Gain**: low single-digit percent of Postbox SQLite CPU, up to an estimated 5-15% of SqliteValueBox read time.
  Measure before claiming it.
- **Risk**: medium. Under NOMUTEX any cross-thread use of a connection becomes a data race that can corrupt memory
  instead of serializing; the precondition audit and a TSan run reduce this. No file format change.
- **How to verify**: the existing `testBenchmarkRangeWithLimit`/`testBenchmarkBeginCommit` with each flag; the whole
  Postbox suite under `swift test --sanitize=thread` with NOMUTEX; `sqlite3_compileoption_used("OMIT_SHARED_CACHE")`.
- **Size**: S
- **Confidence**: medium

### R2-41. PostboxEncoder/Decoder convert every field key to Data and decode strings through an extra copy — `todo` (group: db)

- **Evidence**: `Postbox/Sources/Coding.swift:359-366` (`encodeKey`: `key.data(using: .utf8)!` per field), `:945-951`
  (`positionOnKey`: the same per lookup), `:1194-1212` (`decodeStringForKey`/`decodeOptionalStringForKey`:
  `Data(bytes:count:)` copy, then `String(data:encoding:)`). Scratch microbenchmark (30-field buffer, `-O`): key lookup
  457 → 245 ns with `withUTF8`; a 64-byte string 847 → 500 ns with `String(validating:as: UTF8.self)`.
- **Today**: every field read or written for peers, media, attributes, cached data and preferences pays a String→Data
  conversion (~200 ns), and every decoded string allocates and copies twice. M1/M2's compare-by-encoding puts the
  encoder on the per-update path too.
- **Fix**: `var k = key; k.withUTF8 { … }` for length and memcmp in `positionOnKey` and `encodeKey`;
  `String(validating:as: UTF8.self)` in the string decoders (macOS 15; Postbox's manifest says `.macOS(.v10_13)`, so
  use `if #available(macOS 15, *)` with the old path as fallback). Encoded bytes unchanged.
- **Gain**: ~0.2 µs per field lookup and one allocation per decoded string; roughly 3-8 µs per decoded 15-40-field
  object on the Postbox queue. Measure before claiming a total.
- **Risk**: low. Encoded bytes must stay identical (M1's comparisons, existing databases); invalid UTF-8 must still give
  nil/orElse; pin BOM handling.
- **How to verify**: golden-byte round trips in PostboxCodingArrayTests/AdaptedPostboxDecoder tests, invalid-UTF-8 and
  BOM cases; an XCTest measure decoding and encoding a 30-field object 100k times.
- **Size**: S
- **Confidence**: medium

### R2-42. `exists()` reads and copies the whole value; the cheaper statement is dead code and invalid on WITHOUT ROWID tables — `todo` (group: db)

- **Evidence**: `Postbox/Sources/SqliteValueBox.swift:1835-1841` (`exists` → `get` → `SELECT value`, malloc + memcpy);
  `:1350-1360` (`existsStatement`, `SELECT rowid FROM t WHERE key=?`, never called; WITHOUT ROWID tables have no rowid).
  Callers on large-value rowid tables: `MessageMediaTable.exists` via `filterStoredMediaIds` (per history page with
  custom emoji), `MessageHistoryTable.exists`. EXPLAIN QUERY PLAN: `SELECT value` = index + table lookup; `SELECT 1` =
  covering index. Scratch benchmark (plaintext SQLite, 200k rows): 44.1 → 15.9 µs per check.
- **Today**: each existence check on media or message tables descends both B-trees, reads (and under SQLCipher
  decrypts and verifies) the value's pages, then mallocs and copies the value to throw it away.
- **Fix**: `existsStatement` SQL → `SELECT 1 FROM t\(id) WHERE key=?` (valid for rowid and WITHOUT ROWID tables);
  `exists()` steps it without reading a column.
- **Gain**: ~2.8× per check in plaintext, more under SQLCipher. Small in total; near-zero risk.
- **Risk**: very low.
- **How to verify**: SqliteValueBoxConnectionTests: `exists()` correct on int64, binary rowid and WITHOUT ROWID tables;
  the cached SQL's plan contains "COVERING INDEX" or "PRIMARY KEY"; 10k lookups in a 50 MB encrypted temp box.
- **Size**: S
- **Confidence**: medium

### R2-43. SQLCipher page cache sizes: 32 pages in the share extension, SQLite's 2 MB default in the main app — `todo` (group: db)

- **Evidence**: `Postbox/Sources/SqliteValueBox.swift:591-594` (`!useCaches` → `PRAGMA cache_size=32`; otherwise the
  compile-time default, ~2,000 KiB); `Telegram-Mac/account/SharedAccountContext.swift:272-274` and
  `TelegramCore/Sources/Account/Account.swift:306-317` (TelegramShare opens the account Postbox read-write with
  `useCaches: false`). iOS `9dbf0f93` measured its notification service at 32 → 256 pages: 20.3 → 12 MB written; the
  M9 port left the `cacheSizePages` parameter out. M5's pressure hook already releases the page cache.
- **Today**: in TelegramShare any transaction dirtying more than 32 pages spills them into the WAL before commit. In the
  main app every miss beyond ~500 pages is a pread plus AES-CBC decrypt and HMAC verify of 4 KB.
- **Fix**: port the `cacheSizePages` parameter and pass 256 from the share extension. For the main app, measure 2 MB vs
  8 and 16 MB with `SQLITE_DBSTATUS_CACHE_MISS`/`CACHE_SPILL` before changing it.
- **Gain**: share extension ~40% fewer WAL bytes per sync (by analogy with iOS); main app unknown.
- **Risk**: low; memory rises by the configured size, released on pressure.
- **How to verify**: port iOS `testCacheSizeIsOnlyChangedWhenAsked`; PostboxCacheLab with a 200-500 MB encrypted
  synthetic database replaying range fills and large transactions at each size.
- **Size**: S
- **Confidence**: low (main-app part: measure first)

## Already good

- **Timers and visibility**: device and route changes are event-driven (CoreAudio property listeners,
  AVCaptureDevice notifications; `DevicesContext.swift:232-259`). M22's gate sits before the view swap and catches up
  with one non-animated diff. M23 presence uses a `ValuePromise(ignoreRepeated:)` with per-flag change detection, and
  the system sleep observers are un-swapped. M11 Low Power, thermal and battery observation is event-driven. CADisplayLink
  (macOS 14+) with frame-rate ranges, paused when the app is not visible; Lottie suspended on app occlusion; GraphCore's
  DisplayLinkService prefers `NSScreen.displayLink` and stops with no listeners.
- **App Nap** is not defeated: no `beginActivity`/`NSAppSleepDisabled`; IOPM assertions only for calls, gallery video
  and the wallet seed (R2-4 narrows the call one).
- **Memory**: M5 is wired correctly (pressure and 10-minute inactive release of Postbox caches, SQLite page cache and
  AccountViewTracker throttle maps, off main); the DispatchSource pressure handler purges image, Lottie and gift
  caches, URLCache and Postbox and trims malloc. Bubble image cache bounded at 128 with a lock; cache sweeps use 10%
  leeway and stop when empty. HLS shares one WKWebView/JS context and tears it down after 10 s empty. Chat-list video
  avatars are off.
- **Logging and updates**: `Logger.log` takes an autoclosure and returns early with file logging off; the MTProto
  20-minute updater poll is compiled out under NANOGRAM; Sparkle 2.10.1 is EdDSA-only, legacy SUUpdater/DSA compiled
  out, no Sparkle in the MAS edition.
- **Media**: ChunkMediaPlayerV2 and GIFPlayerView already enqueue off main through
  `sampleBufferRenderer.requestMediaDataWhenReady`; decode and render pixel buffers are IOSurface-backed; Accelerate
  and vImage for conversion and scaling; Vision, Speech and Translation on device; static CIContexts reused.
- **Release code hygiene**: every `*Lab.swift` and PerfLab source is `#if DEBUG` from line 1; x86_64, APP_STORE,
  BETA/ALPHA and GITHUB branches compile out under `NANOGRAM STABLE`. No NSAppleScript, Carbon, NSURLConnection,
  legacy login-item APIs or `beginActivity`. Modern frameworks already adopted where they pay off (UNUserNotificationCenter
  with delivered-notification clearing, OSSignposter, Vision MRZ, App Intents, Translation and SpeechAnalyzer behind
  `#available(macOS 26)`, ScreenCaptureKit for screen share). Device model from IORegistry first, system_profiler only as
  a fallback.
- **Build and launch**: one static executable; only Sparkle as a non-system dylib (weak), chained fixups, 16
  initializers, no `+load`. `ENABLE_DEBUG_DYLIB=YES` is ignored for optimized builds (resolves round 1's open item).
  Stage 1's xcconfig gives every target 15.0, arm64-only, dead stripping, thin LTO and `-O`/WMO; upstream's 10.13
  manifests do not lower the shipped floor. The release plan uses `xcodebuild archive`, which strips.
- **Thread QoS**: pthread/std::thread children start at default QoS whatever the creator's QoS, so the Rust mtproto
  workers run at default (acceptable for network; resolves round 1's open item). H13's ThreadPool QoS fix is in.
- **Libraries**: stage 1 closed M15 (dav1d DotProd/I8MM, 61/58 symbols), M19 (opus 1.6.1 `-O2`), H10 (FFmpeg arm64
  assembled by clang, 240 i8mm symbols) and H15 (libvpx 1.17.0 with runtime CPU detection). FFmpeg 9.0.2 is lean
  (`--disable-everything` allowlist, runtime cpudetect, safe bitstream reader, `-O3`, VideoToolbox hwaccel with a
  working fallback, `AV_LOG_QUIET` in release). OpenSSL 3.5.9 with ARMv8 asm; libsrtp on OpenSSL with cached EVP
  contexts. tg_owt Release `-O3` with NEON. mtproto-engine opt-level 3, codegen-units 1, thin LTO, panic=abort,
  `aes_armv8`. libjpeg-turbo 3.2.1 and libwebp 1.6.0 Release builds; every native library has a source-tracking stamp.
- **Database**: raw-key SQLCipher (no PBKDF2 at open), `cipher_memory_security=OFF`, CommonCrypto backend; WAL +
  `synchronous=NORMAL` + `temp_store=MEMORY`, 8 MiB journal limit, QPSG, cached BEGIN/COMMIT (M9); persistent prepared
  statements for every hot shape; INTEGER PRIMARY KEY for int64 tables, WITHOUT ROWID for 76 small-value tables
  (including StorageBox), rowid tables for large values as SQLite advises; every query is a primary-key point or range
  lookup (ANALYZE would change nothing); FTS5 for search; mmap off (right for SQLCipher). TelegramShare opens the same
  SqliteValueBox with `removeDatabaseOnError=false` (resolves round 1's open item). MediaBox uses APFS clones, sparse
  partial files, M28's map batching with `F_BARRIERFSYNC` before link(), and `liveFileMaps`. M1, M2, M10, M24 and M26
  are in core with their tests.

## Dropped after checking

- **M31's ORDER_FILE and M17 are not in stage 1** (macOS/hardware reviewer). Both are already specified in round 1
  (M31: "Release ORDER_FILE for stage 1"; M17), so no new spec. The check itself holds and should reach the owner:
  `stage1:nanogram/Nanogram.xcconfig` has no `ORDER_FILE` and no `SWIFT_ENFORCE_EXCLUSIVE_ACCESS`; the stage-1 plan
  (`docs/superpowers/plans/2026-11-02-nanogram-macos-stage1-plan.md:101`) leaves package exclusivity at its default,
  and `tools/dev/lint/tglint.py:291` forbids `-enforce-exclusivity=unchecked`. The round-1 status table marks M17 and
  M31 as "stage 1", which neither stage 1 nor its plan carries out. M17 needs an owner ruling (drop it, or allow the one
  setting in tglint); M31 needs the xcconfig line and a committed order file.
- **Merged, not dropped**: the autoplay key-window gate (two reviewers) is R2-3; the Settings notification poll (two
  reviewers) is R2-8, with the dead NSUserNotification code split out as R2-15; SQLite NOMUTEX and compile options (two
  reviewers) are R2-40. The AVSampleBufferDisplayLayer → `sampleBufferRenderer` move appears once, in R2-5 for
  MediaPlayerView, and R2-24 covers the other player files.
- **Corrections kept in specs**: MediaPlayerView's wake-up count lowered to 30-90/s (R2-5); the gift-auction timer is
  also a retain cycle (R2-9); MediaBox's 30 s launch sweep removes stale empty partial files, not over-limit ones
  (R2-37); the `.tgs` corpus is ~377 files (R2-33).

## Not checked

- No runtime measurement: nothing was built or run, there is no account, and every magnitude is an estimate, an
  iOS-fork measurement or a scratch microbenchmark.
- Whether NSApp/NSWindow occlusion turns non-visible on screen lock and display sleep (decides how much of R2-3 the
  key-window loss already covers); whether sponsored messages appear in Nanogram builds (the ad-peer part of R2-1).
- The stage-2 checkout (build-speed work in progress, behind stage 1); whether the runtime's tgcalls commits (Q6, H28,
  M18) compile against stage 1's tg_owt `020feec5` (needs a merged build).
- Rust MTProto engine internals (online keepalive, worker sessions), tgcalls/WebRTC thread priorities and
  `os_workgroup`, the QoS of media decode NSThreads, Mini App WKWebView memory.
- Per-row and per-message allocation profiling in ChatRowItem/ChatListRowItem/TextViewLayout; an exhaustive
  retain-cycle audit (R2-9 found one by reading); the real-display behaviour of M30/H17's RenderFpsLoop.
- Story polling, promo and channel-difference cadences in TelegramCore (shared with iOS, product decisions); large
  uploads and video compression under App Nap; Sparkle 2's own scheduled-check mechanism in detail.
- The thread context of other synchronous AVAsset and `copyCGImage` sites and of `Data(contentsOf:)` in ChatUI
  (AddReactionManager, EmojiScreenEffect, ModalPreviewViews).
- Whether Swift folds `#available(macOS <15)` to constant true at a 15.0 target (`otool -tV` for
  `__isPlatformVersionAtLeast`); a whole-repo unused-declaration scan (Periphery); Assets.car (4.8 MB).
- Library versions against upstream releases and open advisories as of 2026-11; OpenSSL 3 per-call overhead (implicit
  EVP fetches) in tgcalls, MtProtoKit and tde2e; rlottie flags and tlottie internals; OpenH264's exact flags; whether
  WebRTC's APM ever hands the capture post-processor a non-480-sample frame on the Mac (R2-29 part b); FFmpeg
  `-fomit-frame-pointer` and unwinding; the `-ObjC` linker flag's `__TEXT` cost; default cross-module optimization in
  Xcode's SwiftPM release builds (R2-13).
- Database: real account database size, freelist ratio, cache hit rate and StorageBox transaction rate;
  `checkpoint_fullfsync` policy (power-audit #31f, user decision); `cipher_page_size` 16 KB (needs a migration);
  `SQLITE_TRANSIENT` vs `SQLITE_STATIC` binds; `SQLITE_DQS=0`; busy-timeout contention between the app and
  TelegramShare; the stale-partial sweep and keeping MediaBoxFileMap's meta file open (iOS `2398d68d`, lower value
  after M28); the AccountManager database in detail.
