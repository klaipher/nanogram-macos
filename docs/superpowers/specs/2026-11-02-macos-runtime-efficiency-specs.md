# Runtime efficiency (macOS): specs from the 2026-11-02 code audit

A read-only review of the Telegram for macOS source (`nanogram-macos-recon/src`, upstream `telegram-macos` master
with `submodules/telegram-ios` at release 13.1.1) for code that wastes battery, CPU, memory, disk or data at runtime.
Six auditors covered CPU/energy, memory, rendering, media, the shared core (Postbox, TelegramCore, SwiftSignalKit)
and build/optimization settings. Nothing was built, run or profiled, and there is no Telegram account on this Mac.
Each spec below is one change to make later. Line numbers are as of 2026-11-02; re-check them before starting.

- **Verified**: every medium/low-confidence finding and every small finding claimed as high impact was re-read at the
  cited lines by the lead and either kept (sometimes with a correction, noted in the spec) or dropped (see
  "Dropped after checking"). The shared-core files the specs touch (`Timer.swift`, `ChatListViewState.swift`,
  `SqliteValueBox.swift`, `AccountViewTracker.swift`, and per the core auditor also `PeerTable`, `Postbox`,
  `MessageHistoryView`, `AccountStateManagementUtils`, `HistoryViewStateValidation`) are byte-identical to the iOS
  fork's base `b46f1ec6`, so the iOS fork's commits cherry-pick onto them without conflicts.
- **Size**: S = a few lines, M = one file or a few call sites, L = a design change across modules.
- **Impact numbers** are estimates from code reading, the iOS fork's measurements on the same code, or upstream
  perflab measurements. None was measured on this Mac.
- **How to verify without an account.** Most specs name a check that needs no login:
  - SwiftPM test packages that link the pinned Postbox against a real on-disk SQLite, as
    `tools/perflab/MemoryLabs/PostboxCacheLab` already does (port the iOS fork's `Postbox/Tests` there);
  - `SwiftSignalKitTesting/Stress/IdleWakeupTests` (process idle wake-ups via `TASK_POWER_INFO`);
  - `tools/perflab/DecodeBench` (video and Lottie cache codecs), `RenderBench` (offscreen CARenderer),
    `TableLayoutLab`/`TextLayoutLab` (release copies of TGUIKit), `PowerLabs/*` (onscreen layers + `sysmon.py`);
  - the Debug app on the login screen (`sysmon.py`/`syssample.py` for idle wake-ups, `sudo memory_pressure -S -l warn`
    for the pressure handler, `fs_usage` for disk writes);
  - TGUIKitTests and ChatUITests/ChatListUITests for pure gate helpers.

  The in-app perflab scenarios (`run.sh chat-navigation`, `video-player`, `gif-panel`, emoji-panel) need the Debug
  account and are listed as the follow-up measurement.
- Fixes in `submodules/telegram-ios` (TelegramCore, Postbox, SwiftSignalKit, MediaPlayer, FFmpeg, tgcalls) are shared
  with iOS: prefer cherry-picking the iOS fork's commit over writing a Mac variant, so the two forks stay one diff.

Status values: `todo`, `in progress`, `done (<commit>)`, `dropped (<reason>)`.

## Quick fixes (S)

### M1. Unchanged peers and cached peer data are rewritten on every update, rebuilding every live history view — `done (dd412d9)`, verified

- **Evidence**: `submodules/telegram-ios/submodules/Postbox/Sources/Postbox.swift:2867-2872` (`updatePeers` always
  calls `peerTable.set` and marks the peer updated, even when identical); `:2999-3005` (`updatePeerCachedData`, the
  same with no equality check); `PeerTable.swift:29-35`; `MessageHistoryViewState.swift:1663-1705` (a history view
  rebuilds every message whose `peers` contain an updated peer); `TelegramCore/Sources/UpdatePeers.swift:142-145`
  (every `users`/`chats` vector of every update batch, views poll and channel poll is merged). The chat list already
  compares with `arePeersEqual` (`ChatListViewState.swift:112-141`); history views do not.
- **Mechanism**: the same sender and channel come back in almost every update. Each makes the transaction non-empty
  (`Postbox.swift:2777-2778`), queues a peer-table write, and makes every live `MessageHistoryView` (the open chat,
  up to 30 preload views of 50 messages, peer views) allocate a new `Message` for each entry that references the
  peer. For a channel that is every entry. The Mac ChatController then re-runs entry preparation and the diff.
- **Impact**: per incoming update batch in an active group or channel that is open or among the 30 preloaded chats:
  one or more full-window message rebuilds and emissions, plus a WAL write per repeated peer. Postbox queue and ChatUI
  prepare queue CPU; runs with the window hidden. iOS found this the largest source of redundant history emissions.
- **Fix**: port iOS `f997e5c0` (PeerTable/`Postbox.updatePeers`) and the CachedPeerData part of `718f4692`:
  `PeerTable.encodesIdentically(current, updated)` and `CachedPeerDataTable.encodesIdentically` (encode both, compare
  bytes, `===` shortcut); `continue` before `set` when identical. Do not use `arePeersEqual` alone: some `isEqual`
  implementations ignore fields such as emoji status or photo.
- **UX risk**: low. Byte-identical encoding means nothing stored changed. A type with non-deterministic encoding just
  compares unequal and is written as today.
- **How to verify**: port `Postbox/Tests/PostboxRedundantWriteTests.swift` and `PostboxFixture` into a SwiftPM test
  package on the pinned Postbox (PostboxCacheLab pattern): store the same peer twice and assert the second
  transaction is empty; count `MessageHistoryView` emissions with 100 loaded channel messages while re-merging the
  unchanged channel peer (N before, 0 after).
- **iOS cross-ref**: `f997e5c0`, `718f4692` (iOS spec "Found and fixed while measuring"); ports as is.
- **Perflab**: extend PostboxCacheLab with a "replay unchanged peers into N live views" benchmark.

### M2. Channel polls, views polls and history validation write values that did not change — `done (7136832)`, verified

- **Evidence** (TelegramCore `Sources/State/`): `AccountStateManagementUtils.swift:4943-4947` (`.UpdateChannelState`
  always calls `setPeerChatState`); `:3652-3667` (`channelDifferenceEmpty` still stores the same pts); `:3262-3266`
  (`keepPollingChannel` repeats every server timeout, ~30 s, started for open channels from
  `ChatController.swift:9376`); `Account/AccountIntermediateState.swift:551-560` (every merged channel with a
  `participantsCount` emits `.UpdateCachedPeerData`); `AccountStateManagementUtils.swift:5256,5271` (view/forward
  counts rewritten with `max(old,new)` even when equal); `AccountViewTracker.swift:786-800` (the views poll for
  visible channel posts, `ChatController.swift:11404`, rewrites each message even when nothing changed);
  `HistoryViewStateValidation.swift:914,1158` (validation re-stores every confirmed message).
- **Mechanism**: a "nothing changed" answer from the server becomes a Postbox write. Each write makes ViewTracker
  replay every live view, and an `updateMessage` also bumps the message's stable version, so the open chat re-lays
  out that bubble.
- **Impact**: while a channel is open (also in a hidden window) and for polled non-member channels: a DB write, a
  full ViewTracker pass and a bubble relayout per poll per visible post, every 30 s. iOS measured history validation
  at 49 KB of WAL per batch going to 0.
- **Fix**: cherry-pick the TelegramCore hunks: from `3d30de4c` skip `.UpdateChannelState` for an unchanged pts and
  return nil from the participants-count closure for an unchanged count; from `f997e5c0` view/forward count updates
  return `.skip` unless the count grew; from `9bc6231a` the views poll tracks `changed` and returns `.skip`; from
  `718f4692` `historyValidationRestoredMessage` returns nil when the version attribute is current and the message has
  no `unseenReaction`/`unseenPollVote` tag.
- **UX risk**: low. Keep the iOS exception: validation must still re-store messages with unseen reactions or poll
  votes, because that store is what marks them seen.
- **How to verify**: port iOS `HistoryValidationRestoreTests`; TelegramCore unit tests that feed a synthetic
  `AccountFinalState` with `UpdateChannelState(samePts)` and assert an empty transaction; apply the same view-count
  update twice and count history-view emissions (1, not 2).
- **iOS cross-ref**: `3d30de4c`, `f997e5c0`, `9bc6231a`, `718f4692`; ports as is.
- **Perflab**: same Postbox harness as M1. With an account, the power-audit idle sampler with a channel open.

### M3. Four 1 Hz main-queue clock-offset loops per account, plus a 5 s one in AccountContext and a 10 s folder poll — `done (795c4f8, e605e56; core 3ec2f14, 3a11ddd)`, verified

- **Evidence**: TelegramCore `State/ManagedAutoremoveMessageOperations.swift:44-62` (used twice, `isRemove`
  true/false) and `:140-158` (stories), `State/ManagedPeerTimestampAttributeOperations.swift:49-61`: each is
  `timeOffsetOnce |> then(.complete() |> delay(1.0, queue: .mainQueue())) |> restart |> map(round) |>
  distinctUntilChanged`; all four start for every account (`Account/Account.swift:1506-1509`). Each read is
  `Network.globalTimeDifference` (`Network.swift:1230-1231`) → `MTContext.globalTimeDifference`, a **synchronous**
  dispatch onto `[MTContext contextQueue]` (`MtProtoKit/Sources/MTContext.m:643-652`).
  `Telegram-Mac/account/AccountContext.swift:820-829` re-reads `globalTime` every 5 s per account on main
  (power-audit #11). `TelegramEngine/Peers/TelegramEnginePeers.swift:1565-1574` (`pollChatFolderUpdates`, a Postbox
  transaction every 10 s while a folder tab is selected, `ChatListController.swift:734`; the server period is 1 h).
- **Mechanism**: polling for a value that changes only when MTProto corrects the server time. Almost every tick is
  dropped by `distinctUntilChanged`, but each one schedules a zero-leeway timer on main and blocks main on MTContext's
  queue, which is busy during reconnects and key work. The Mac keeps every account active, so it multiplies by the
  account count.
- **Impact**: ~4.2 main-thread wake-ups/s per account, always on (idle, hidden, display asleep); 3 accounts ≈ 13/s
  doing nothing. Each tick can also stall main behind the network context. CPU per tick is microseconds; the cost is
  wake-ups and stall risk.
- **Fix**: port `9bc6231a` (1.0 → 10 s in the three core loops; folder poll 60 s, DEBUG keeps 10 s) and also move the
  three loops off main (`Queue.concurrentDefaultQueue()`; nothing downstream needs main). In `AccountContext.swift:825`
  use 30 s, or compute `timeDifference` at its read sites. Later, publish the offset once from Network (a Promise fed
  by MTProto/Rust time-difference events) and drop the polls.
- **UX risk**: very low. Self-destruct, story expiry and peer-timestamp actions use their own next-expiry timers; only
  a server-time correction is picked up up to 10 s later (corrections are usually under 1 s). Relative times shown
  from `context.timeDifference` lag a correction by the new interval.
- **How to verify**: a SwiftSignalKit stress test running the exact `then(delay) |> restart |> distinctUntilChanged`
  shape ×4 at 1 s vs 10 s, counting main-queue deliveries (IdleWakeupTests pattern); a TelegramCore test with a stub
  network whose offset changes once (the manager reschedules within 10 s).
- **iOS cross-ref**: R8, part done in `9bc6231a` (on main there too; moving off main is new).
- **Perflab**: the core loops are not in upstream's power audit; #11 is listed, not fixed. The loops start only for a
  logged-in account, so without one use the stress test; with the account, `syssample.py` idle wake-ups/min.

### M4. Deadline polls are re-fetched every 0.5 s once the time since posting has passed again — `done (1ac6562)`, verified (corrected)

- **Evidence**: TelegramCore `State/AccountViewTracker.swift:548` (only `deadlineTimeout` is checked; `deadlineDate`
  is ignored); `:556` `remainingTime = timestamp - startDate - 1` (time since posting, not time left); `:573-583`
  (after that delay: `fetchPoll |> then(delay 0.5) |> restart`); `:49-62` (`pollMessages` takes every non-closed cloud
  poll in the loaded history view, not only visible ones; the Mac chat uses `wrappedMessageHistorySignal`).
- **Correction**: the auditors disagreed on when the loop starts. It starts after waiting as long as the poll already
  existed when the chat opened (opened at age T → loop from age 2T), and it stops when the server reports the poll
  closed, because `pollMessages` filters `!poll.isClosed`. Close periods and dates are 5-600 s, so the loop is bounded.
- **Mechanism**: in the 0.5 s branch each fetch is `messages.getPollResults` plus a Postbox write plus a history-view
  emission that re-lays out the poll bubble.
- **Impact**: per open quiz/deadline poll in a loaded chat: about 2 requests/s, 2 transactions/s and 2 bubble
  relayouts/s, up to ~1,200 requests for a 10-minute poll opened right after posting. Continues while the window is
  hidden. Matters in channels and groups that post quizzes.
- **Fix**: port the `9bc6231a` hunk: require `!isClosed` and a `deadlineDate` or `deadlineTimeout`;
  `deadline = deadlineDate ?? startDate + deadlineTimeout`; `remaining = deadline - now` (add the account's time
  difference); wait `remaining`, then ~10 fetches at 0.5 s, then the regular 30 s refresh.
- **UX risk**: low. Results refresh every 30 s before the deadline (as non-deadline polls do) and quickly right after.
- **How to verify**: extract `pollRefreshDeadline(startDate:deadlineTimeout:deadlineDate:now:)` and unit-test it;
  count `fetchPoll` calls from a fake history view with a stub network.
- **iOS cross-ref**: R1, done in `9bc6231a`; ports as is.
- **Perflab**: upstream #31, "suspected", not fixed.

### M5. Memory pressure never reaches Postbox: table caches, the SQLite page cache and AccountViewTracker throttle maps grow for the whole uptime — `done (934ac65, core d985e78)`, verified

- **Evidence**: `Telegram-Mac/utils/MemoryPressureMonitor.swift:42-53` (the handler purges image, Lottie, gift and URL
  caches and calls `malloc_zone_pressure_relief`, nothing else; the 20 s inactive trim at `:55-66` only trims malloc);
  `Telegram-Mac/account/SharedAccountContext.swift:499,504` (the only `postbox.clearCaches()` calls, on account
  switch); Postbox `PeerTable.swift:14`, `CachedPeerDataTable.swift:11`, `PeerPresenceTable.swift:11`,
  `MessageHistoryReadStateTable.swift:25` (unbounded dictionaries, freed only by `clearMemoryCache`);
  `SqliteValueBox.swift:590-594` (default page cache for the main database; no `sqlite3_db_release_memory`);
  TelegramCore `AccountViewTracker.swift:310-334` (nine `[MessageId: …]`/`[PeerId: …]` throttle maps, one entry per
  message or peer ever shown, never removed; longest throttle window 1 h). No `pruneThrottleState`/`releaseMemory` in
  the Mac pin.
- **Mechanism**: iOS frees these on every backgrounding. The Mac app is never backgrounded and stays up for days, so
  every decoded peer, cached data, presence and read state stays resident, per account. The pressure handler fires
  exactly when macOS wants memory back but frees only already-bounded UI caches.
- **Impact**: memory that only grows. PostboxCacheLab measured 9.0 MB for 22k light rows (421 B/row); real peers with
  cached channel data are heavier, so tens of MB per heavy account is plausible after long uptime. Throttle maps grow
  ~50-150 B per message seen.
- **Fix**: (1) give MemoryPressureMonitor a hook set by AppDelegate; on pressure, for every active account plus
  `currentAuth`, call `postbox.clearCaches()` and `viewTracker.pruneThrottleState()`. (2) Port `pruneThrottleState()`
  from `9bc6231a` (drop records older than 11 h on the tracker's queue). (3) Port `SqliteValueBox.releaseMemory()`
  from `2398d68d` (`sqlite3_db_release_memory`, never a checkpoint) into `PostboxImpl.clearCaches`. (4) Optional,
  Mac-specific: run the same after ≥10 min inactive (not at 20 s), as the analogue of iOS's background clear, and
  prune hourly with leeway.
- **UX risk**: low. Live views keep their own copies. The first reads after a clear decode again (~3 µs/peer, 68 ms
  for 22k rows spread over later reads), so the first chat-list or chat transaction after a pressure event can be a
  few ms slower. Pruning only removes expired throttle records.
- **How to verify**: extend PostboxCacheLab: fill 20k peers, call the hook's entry point, assert the heap drop and
  intact data (`SQLITE_DBSTATUS_CACHE_USED` for the page cache; iOS `SqliteValueBoxReleaseMemoryTests`); a unit test
  that feeds AccountViewTracker 100k synthetic ids, prunes with a mocked clock and checks the counts; on the login
  screen, `sudo memory_pressure -S -l warn` and a new "postbox caches cleared" log line.
- **iOS cross-ref**: R22 (`9bc6231a`, `2398d68d`); the core ports as is, the trigger is Mac code.
- **Perflab**: PostboxCacheLab already measures exactly this cache.

### M6. Empty chat transitions never short-circuit, so the full merge and `applyTransition` tail run for no-op updates — `done (a84a3c8)`, verified

- **Evidence**: `packages/TGUIKit/Sources/TableView.swift:290-296` (`case none(TableAnimationInterface?)` in a
  synthesized `Equatable`); `TableAnimationInterface.swift:3` (`NSObject`, no `isEqual`, so identity);
  `packages/ChatUI/Sources/ChatUI/ChatController.swift:4167` (a new interface per emission) and `:1968-1972` (every
  `.Generic(.Generic)` update gets `.none(animationInterface)`); `TableView.swift:3416` (`if transition.isEmpty,
  lastAppliedScroll == transition.state { return false }` can therefore never match); `ChatController.swift:9848-9916`
  (`applyTransition` ignores `merge`'s result and always runs `collectFloatingPhotos` with a forced regroup,
  `notifyScrollHandlers`, `chatInteraction.update`, `updateBackground` on visible rows and the effects scan).
  `docs/perflab/chat-performance-2026-10-11.md` §10 made the same fix for the chat list only.
- **Mechanism**: the history pipeline has 15 inputs; a member count, ad, reaction setting, UI state or read-state
  re-emission with unchanged visible entries yields an empty diff, which still runs the whole merge pass and the main
  thread tail.
- **Impact**: open chats in large or active groups, once per no-op re-emission; likely ~1 ms of main thread each
  (perflab's scroll-listener and floating-avatar costs). Frequency not counted.
- **Fix**: (1) in `TableView.merge`, treat two `.none` states as equal for the empty short-circuit (keep exact
  equality for the others). (2) In `ChatController.applyTransition`, when `merge` returns false and loading state is
  unchanged, still update history state and `chatInteraction`, but skip the floating-photo regroup, scroll handlers,
  `updateBackground`, the effects scan and `invokeInitialAction`.
- **UX risk**: low to medium: anything that relied on the tail after a no-op update would stop refreshing (theme
  changes always produce non-empty transitions). Gate only view work, keep every state update.
- **How to verify**: extend `TGUIKitTests/TableMergeResultTests`: two empty transitions with different
  `.none(TableAnimationInterface())` instances; the second returns false after the fix. With the account: an
  `emptyMerges` counter in `ChatMergeProbe` and ChatNavigationLab `idle` in a large group.
- **iOS cross-ref**: none (Mac TableView).
- **Perflab**: ChatMergeProbe (DEBUG) already wraps the merge.

### M7. Tinted custom emoji are never frame-cached and run rlottie every frame — `done (b93d09d)`, verified (key claim corrected)

- **Evidence**: `packages/InlineStickerLayer/Sources/InlineStickerLayer/InlineStickerItemLayer.swift:790-795`
  (`cache = .temporaryLZ4(.effect); if !colors.isEmpty { cache = .none }`); colours are fixed at creation
  (`getColors` at `:792`); `packages/TelegramMedia/Sources/LottiePlayer.swift:1720-1733` (the cache key already
  includes every colour). The only live `setColors` callers (grep) are `ChatRecorderOverlayWindow.swift:150-151` and
  `AppMenuAnimatedImage.swift:104,190`, bundle animations with no cache; `InlineStickerItemLayer.setColors` and
  `MediaAnimatedStickerView.setColors` have no callers. Upstream left tinted emoji out of #13d because colours "can
  change live through setColors".
- **Correction**: the auditor's claim that `hexString` collides (e.g. `0A,BC` vs `AB,0C`) is wrong:
  `packages/Colors/Sources/Colors/Colors.swift` re-pads one-digit components to two. It does drop alpha.
- **Mechanism**: every visible tinted emoji (default-pack statuses in accent colour, `paintToText` packs in text, names
  and reactions) has no frame cache: rlottie renders each frame at up to 30 fps on the pool, plus a new buffer and
  `CGImage`; each context restart (scroll-in, Cmd-Tab) also gunzips and recolours the JSON. Untinted emoji pay rlottie
  for one loop only.
- **Impact**: continuous CPU while such emoji are visible in a key window, per unique (emoji, colour): a full rlottie
  frame (~0.5 ms or more) instead of a ~0.01 ms cache read. Chat lists and groups full of premium statuses keep
  several on that path.
- **Fix**: drop the `if !colors.isEmpty { cache = .none }` branch. Make the key carry alpha (fixed-width ARGB,
  `%08X`) and bump `version` in `LottieBufferCompressor.swift:41` (70 → 71) so old files are ignored. Keep `.none`
  only for callers that change colours live (today only the uncached bundle animations).
- **UX risk**: low. Frames are lossless round trips of what rlottie renders. Disk: one small cache file per (emoji,
  colour, size) with the 7-day lifetime; a theme change creates new ones.
- **How to verify**: unit test through the InlineStickerItemLayer path: `fileSupplyment` non-nil and frames
  `fromCache` after one loop; pixel parity of rlottie vs cache-read frames for a tinted bundled animation; Time
  Profiler on a synthetic window of 50 tinted emoji (InlineEmojiLayerLab-style host, no account).
- **iOS cross-ref**: iOS `f1b056ef` (tinted template emoji on the cached YUVA path); the idea ports, the code does not.
- **Perflab**: InlineEmojiLayerLab / InlinePlaybackLab hosts drive real tinted animations without an account.

### M8. Cached video emoji and stickers still open FFmpeg, probe the stream and allocate a VP9 decoder each time they start — `done (9734759, 0e20f68; core 867d5c5)`, verified

- **Evidence**: `packages/TelegramMedia/Sources/LottiePlayer.swift:1800-1812` (`.webm` always builds
  `SoftwareVideoSource`, while the `.lottie` branch at `:1778` skips its bridge when `fileSupplyment.isFinished`);
  `:1356` (the decoder is used for `getFramerate()` only on a cache hit; `render` returns cached frames at
  `:1380-1386`); `:1452-1456` (`markFinished` already drops the decoder); MediaPlayer
  `SoftwareVideoSource.swift:81-180` (open, `avformat_find_stream_info`, which decodes frames for VP9, then a libvpx
  context); `InlineStickerItemLayer.swift:296,703-712` (contexts are dropped on resign-key and scroll-out and rebuilt).
- **Mechanism**: since upstream #13d, frames come from the LZFSE frame cache, but every restart still pays the file
  open, probe and decoder setup.
- **Impact**: a burst on the lottie init queue at every window re-activation and every scroll of a chat or emoji panel
  with video emoji: a few ms per visible unique video emoji (estimate), tens to hundreds of ms per Cmd-Tab with the
  emoji panel open; it also delays the first animated frame. Nothing while idle.
- **Fix**: when `fileSupplyment?.isFinished == true`, build `WebmRenderer` with a lazy decoder factory, taking fps and
  end frame from the stored map (`reachedEnd` already stores `min(30, framerate)`); create `SoftwareVideoSource` only
  on the first cache miss. Separately port the probe skip from iOS `019e8379` for the opens that remain (first play,
  GIFs, MediaDataReader).
- **UX risk**: none expected with a valid cache; a cache deleted under a live context behaves as today.
- **How to verify**: inject a decoder factory and count inits for a finished-cache webm (0 after, 1 today); time
  `SoftwareVideoSource.init` on a VP9 webm in DecodeBench (`webm`, `webm-cache` modes).
- **iOS cross-ref**: `019e8379` (probe skip, VP9 open ~23× cheaper); the lazy decoder is Mac code.
- **Perflab**: DecodeBench without an account; emoji-panel `warm`/`cold` with one.

### M9. SQLite: `LIMIT ?` statements re-prepare on every call, BEGIN/COMMIT are parsed per transaction, the WAL is unbounded — `done (core 0319e83)`, verified

- **Evidence**: `submodules/telegram-ios/submodules/sqlcipher/Package.swift:27-44` (no `SQLITE_ENABLE_QPSG`);
  Postbox `SqliteValueBox.swift:995,1059,1155,1219` (cached range statements with `LIMIT ?`), `:668-683`
  (`begin`/`commit` through `database.execute`), `:1877-1913` (`filteredRange` re-issues `range()` in a loop),
  `:609-610` (`wal_autocheckpoint`/`journal_size_limit` commented out).
- **Mechanism**: without query-planner stability SQLite re-prepares a statement whose bound `LIMIT` changes (iOS
  counted 1600 of 1600 calls). Every transaction parses BEGIN and COMMIT text. A WAL that grows in a burst is never
  truncated.
- **Impact**: the hottest Postbox read path: iOS measured `range(limit:)` 14.6 → 6.9 µs. Small per call, on every
  view fill and transaction. The WAL bound affects disk only.
- **Fix**: port `9dbf0f93`: `.define("SQLITE_ENABLE_QPSG", to: "1")` in the SwiftPM sqlcipher target; BEGIN/COMMIT
  prepared once per connection (`SQLITE_PREPARE_PERSISTENT`); one statement in `filteredRange`; `journal_size_limit`
  8 MiB with a wal hook at the default 1000 frames. Leave `checkpoint_fullfsync` (power-audit #31f, user decision).
  Note upstream once had `journal_size_limit` and removed it in 2017 during the multi-process rework (iOS R9 history);
  the iOS fork re-added it with tests.
- **UX risk**: none visible. Check first whether TelegramShare opens the same database; if it does, use the same WAL
  settings in both processes.
- **How to verify**: port iOS `SqliteValueBoxConnectionTests` (`SQLITE_STMTSTATUS_REPREPARE` counter, statement reuse,
  WAL size bound) into a SwiftPM test on the pinned Postbox and sqlcipher; microbenchmark `range(limit:)`.
- **iOS cross-ref**: `9dbf0f93` (R9 re-done); ports as is.
- **Perflab**: PostboxCacheLab package shape.

### M10. Comment threads re-emit on every read-state change of their discussion group — `done (core 10e47fe)`, verified

- **Evidence**: Postbox `MessageHistoryView.swift:706-709`: `.UpdateReadState` sets `hasChanges = true` for every
  non-thread view, also views without transient read states (comment threads use `.external`).
- **Mechanism**: a view that shows nothing read-state dependent still re-samples and emits for every read and unread
  count change in a busy discussion group.
- **Impact**: iOS measured 10 extra emissions of an open comment thread for 5 messages arriving and being read
  elsewhere; 0 after. CPU for re-sampling plus the Mac chat diff while viewing comments of a busy channel.
- **Fix**: port `838d87e4`: `} else if self.transientReadStates != nil {` at line 708.
- **UX risk**: very low; views with transient read states behave as before.
- **How to verify**: port iOS `ReadStateEchoTests` to a SwiftPM test on the pinned Postbox.
- **iOS cross-ref**: `838d87e4`; ports as is.

### M11. Lite mode ignores Low Power Mode and thermal state, and polls the battery every 60 s even when the threshold is off — `done (e48de99)`, verified

- **Evidence**: `Telegram-Mac/account/SharedAccountContext.swift:66-79` (`isLite` checks the switch and
  `batteryLevel <= lowBatteryPercent` only; no `isLowPowerModeEnabled`/`thermalState` anywhere in Telegram-Mac,
  packages or TelegramCore); `:275-286` (a repeating 60 s IOKit power-source read for every user, also with
  `lowBatteryPercent == 100`, which means off, and on desktops); `:82-88` (`batteryLevel` didSet runs
  `syncLiquidGlassWithLite()` on every poll, changed or not).
- **Mechanism**: macOS Low Power Mode is the user's explicit "save energy" signal; Telegram keeps every animation,
  emitter, blur and liquid-glass compositing on through it, and through serious thermal pressure.
- **Impact**: in Low Power Mode, the app's largest steady GPU/WindowServer cost while visible (power-audit #13d, #27)
  keeps running. The poll itself is tiny (one IOKit copy and a main hop per minute, hidden too).
- **Fix**: in `isLite`, also return true for `ProcessInfo.processInfo.isLowPowerModeEnabled` (optionally
  `thermalState >= .serious`) when the user enabled automatic power saving (`lowBatteryPercent != 100`), to stay
  opt-in. Observe `NSProcessInfoPowerStateDidChange` and `thermalStateDidChangeNotification` and call
  `syncLiquidGlassWithLite()`. Replace the poll with `IOPSNotificationCreateRunLoopSource`, skip it when the
  threshold is off or there is no internal battery, and assign `batteryLevel` only on change.
- **UX risk**: real if unconditional (animated emoji stop looping, blur and glass fall back in Low Power Mode, as at
  low battery today). Gating on the existing setting keeps it opt-in. Removing the poll changes nothing visible.
- **How to verify**: inject a power-state provider into `isLite` and unit-test the matrix; toggle Low Power Mode with
  the Debug app on the login screen and watch `System.liquidGlass`/`System.blurEnabled` flip; System Trace shows no
  60 s IOKit calls with the threshold off.
- **iOS cross-ref**: R7 (`todo` on iOS: skipped because it changes what power saving turns off). Same product question.
- **Perflab**: upstream #29 and #31e, listed, not fixed. `PowerLabs/Emitter/offscreen.swift` shows what lite gating
  saves per emitter.

### M12. The chat list table does not skip AppKit's needs-display walk while scrolling — `done (28b6e26)`, verified (A/B with the account not measured)

- **Evidence**: `packages/TGUIKit/Sources/TGClipView.swift:24-47,264-268` (`skipsDisplayOnScroll`); only
  `ChatController.swift:483` and `PeerMediaPhotosController.swift:424` set it; the chat list's table
  (`packages/ChatListUI/Sources/ChatListUI/PeersListController.swift:1085`) does not. `docs/perflab/README.md:158`
  calls the walk pure cost; `chat-optimization-log.md:52-65` measured −15% main thread in the chat with
  pixel-identical rows.
- **Mechanism**: NSClipView marks itself dirty on every scroll step, and the next display pass walks every view
  under it (~50 avatars, ~50 text views, the story strip) to find nothing to draw.
- **Impact**: main-thread CPU while scrolling the chat list; by analogy a double-digit share of scroll main time. Not
  measured on the chat list.
- **Fix**: `tableView.clipView.skipsDisplayOnScroll = true` in `PeerListContainerView.init`. Later, the same A/B for
  contacts, settings lists and sticker/emoji panels.
- **UX risk**: low to medium: a view under the list that draws based on scroll position without marking itself dirty
  would stop updating (check `ChatListRowView.draw`, the archive autohide header, the stories strip collapse, sticky
  folder tabs).
- **How to verify**: no code change needed for the A/B: ChatListStoriesLab `wheel`/`scroll-down-from-top` with and
  without `-PerfLabClipNoDisplay 1` (needs the account), plus snapshot parity at several offsets. Census
  `censusDrawingViews` confirms nothing relies on clip redisplay.
- **iOS cross-ref**: none.
- **Perflab**: `-PerfLabClipNoDisplay 1` exists for exactly this.

### M13. The premium-lock badge rebuilds and cancels its blur pipeline on every emoji frame — `done (cdb8e5f)`, verified

- **Evidence**: `InlineStickerItemLayer.swift:452-457` (`contents` didSet calls `contentDidUpdate` every frame);
  `:39-43` (the lock layer's `tieToLayer` calls `applyBlur` each time); `:45-121` (a signal with
  `|> delay(contents != nil ? 0.1 : 0, …)` outermost, so the subscription itself waits 0.1 s and is disposed by the
  next frame before it runs); used by every locked premium emoji in the emoji and sticker panels
  (`EmojiesSectionRowItem.swift:1259`, `StickerPackItems.swift:400`).
- **Mechanism**: per locked emoji per frame: a signal graph and a DispatchSource timer created and cancelled; the blur
  runs only for the first image and after playback stops.
- **Impact**: for non-premium users with the emoji panel open: ~30 timer create/cancel cycles per second per visible
  locked emoji (≈1,200/s for 40). Allocation churn and probably ~1% of a core.
- **Fix**: compute the badge once (first frame or preview) and set `contentDidUpdate = nil`; re-arm on reset or preview
  change. Or ignore updates while playing.
- **UX risk**: none: mid-animation blurs are already always cancelled today.
- **How to verify**: a fake-layer unit test feeding 300 contents updates at 30 Hz: pipeline constructions 300 → 1,
  identical badge image.
- **iOS cross-ref**: `a349a378` (badge made once with the frame, off main); the idea ports.

### M14. Each incoming message while the chat is at the bottom forces a synchronous whole-window display pass — `done (f20014e)`, verified (Time Profiler with the account not run)

- **Evidence**: `packages/TGUIKit/Sources/TableAnimationInterface.swift:79-90`: with the user at the bottom, after
  making the new row views it calls `table.layoutSubtreeIfNeeded()` then `table.window?.displayIfNeeded()`;
  `TableView.swift:3739-3740` runs it for every `.none(interface)` merge, which every Generic chat update uses.
- **Mechanism**: `NSWindow.displayIfNeeded()` lays out and displays the whole window (chat list, header, input, chat)
  in the middle of the transition; the run loop's own display pass then runs again for what `applyTransition` dirties
  afterwards. `layoutSubtreeIfNeeded` already makes the positions read at line 95 final.
- **Impact**: watching a busy group at the bottom: one extra whole-window AppKit pass per incoming message, likely
  1-3 ms of main thread (from the ~1.4 ms/frame walk cost in chat-optimization-log). Not measured.
- **Fix**: remove the call or narrow it to `table.displayIfNeeded()`; if the first animation frame then shows an
  undrawn row, display only the newly created row views.
- **UX risk**: medium: the call may exist to stop new rows flashing blank on the first frame; git history is squashed,
  so the reason is lost. Check frame by frame.
- **How to verify**: a TGUIKit test with a counting Window subclass and a bottom insertion; assert identical position
  animations with and without the call and compare first frames with the ViewSnapshot helper. With the account,
  Time Profiler on `TableAnimationInterface.animate` in a busy group.
- **iOS cross-ref**: none.

### M15. dav1d is built without its DotProd/I8MM kernels because of a wrong `cpu_family` — `todo`, verified

- **Evidence**: `core-xprojects/dav1d/dav1d-arm64.meson`: `cpu_family = 'arm64'` (Meson's name is `aarch64`), so
  dav1d's `meson.build` skips the extension probes; `core-xprojects/dav1d/build/arm64/config.h:64,70`:
  `HAVE_DOTPROD 0`, `HAVE_I8MM 0`. Software AV1 runs on M1/M2 and for direct streams on any Mac
  (`ChunkMediaPlayerV2.swift:11-14,130-136`; FFmpeg `--enable-libdav1d`).
- **Mechanism**: dav1d picks kernels at runtime; with none compiled, 8-bit MC and filters fall back to plain NEON.
- **Impact**: CPU during software AV1 playback (videos, HLS, stories on M1/M2), roughly 5-15% of decode time in the
  affected functions (estimate). No idle effect.
- **Fix**: port `64fc8c95`: `cpu_family = 'aarch64'`, `cpu = 'aarch64'`; delete `core-xprojects/dav1d/build` (the
  build phase runs `build.sh` only when it is missing) and check `config.h`.
- **UX risk**: none: bit-exact assembly, runtime-selected.
- **How to verify**: `nm …/libdav1d.a | grep -ci dotprod` (iOS got 118); `checkasm --bench`; dav1d CLI with
  `--cpumask` on a sample file.
- **iOS cross-ref**: `64fc8c95` (same bug in the simulator cross file).

### M16. RangeSet is not inlinable and checks invariants in release — `done (core 09ee786)`, verified (measure first)

- **Evidence**: `submodules/telegram-ios/submodules/Utils/RangeSet/Sources/*.swift` (no `@inlinable`);
  `RangeSet.swift:64-77` (`_checkInvariants` on every construction, all builds); hot callers in other modules:
  Postbox `MediaBoxFileMap.swift:11,17,103`, `MediaBoxFileContextV2Impl.swift:528-531` (per downloaded chunk),
  TelegramCore `Network/FetchV2.swift:150-155,266-270,549`.
- **Mechanism**: unspecialized generic calls across modules plus a range walk per construction, per chunk of every
  download and streaming read.
- **Impact**: iOS measured ~0.5 s CPU per device session and 57-100× on a FetchImpl-like Mac benchmark. Caveat for the
  Mac: Xcode's SwiftPM release builds may already specialize some of it through cross-module optimization, so measure
  the Mac binary first (count `RangeSet` specializations with `nm | swift-demangle`).
- **Fix**: cherry-pick `faf90287` (public API `@inlinable`, storage `@usableFromInline`, invariant check only under
  `DEBUG`) with its RangeSetTests.
- **UX risk**: none; a corrupt range set no longer traps in release.
- **How to verify**: `swift test` (debug and `-c release`) for the ported tests; the iOS FetchImpl-like benchmark as a
  standalone SwiftPM bench.
- **iOS cross-ref**: `faf90287`; ports as is.

### M17. SwiftPM packages keep runtime exclusivity checks in Release while the app target has them off — `todo`, verified (measure first)

- **Evidence**: `Telegram.xcodeproj/project.pbxproj:4921,5147` (`SWIFT_ENFORCE_EXCLUSIVE_ACCESS = off` for the app
  target only); `AGENTS.md:68` ("Packages enforce runtime exclusivity (the app has it off)"); no package sets
  `-enforce-exclusivity`. Nearly all Swift code is in packages; SwiftSignalKit2's `@inlinable` `Atomic.with/modify`
  (~2,400 call sites) inline `swift_beginAccess`/`endAccess` pairs into callers.
- **Mechanism**: a runtime call per dynamic access to class stored properties in package code.
- **Impact**: an estimated low single-digit percent of Swift CPU in class-heavy hot paths (signal plumbing, Postbox
  views, table layout, Lottie state). Not measured.
- **Fix**: add `SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off` to the release `xcodebuild` invocation (`tg build --release`, or
  `buildbox/build-mac.sh:62-67`), next to the existing `SWIFT_ACTIVE_COMPILATION_CONDITIONS` override, which already
  reaches packages. Keep Debug and tests checked.
- **UX risk**: none on screen; a violation that would trap in a package becomes silent in Release, as it already is in
  the app target. Debug still traps.
- **How to verify**: `otool -tV … | grep -c swift_beginAccess` before/after; paired `swift test -c release` in
  TableLayoutLab/TextLayoutLab with and without `-Xswiftc -enforce-exclusivity=unchecked`.
- **iOS cross-ref**: the iOS fork has not done this either.

### M18. Group-call screen sharing logs every WebRTC INFO line into an in-memory stream that is never read, and to stderr — `done (1becb21)`, verified

- **Evidence**: `packages/TelegramCallsCore/Sources/TelegramCallsCore/PresentationGroupCall.swift:3037-3050` (the
  screencast context gets `logPath: ""`); `submodules/tgcalls/macos/Sources/OngoingCallThreadLocalContext.mm:1477`
  (`need_log = true` always; the Mac always uses `GroupInstanceCustomImpl`, `:1498`);
  `tgcalls/group/GroupInstanceCustomImpl.cpp:4524-4532` (sink created, `SetLogToStderr(true)`, `LS_INFO`, added as a
  process-global stream until the destructor); `tgcalls/LogSinkImpl.cpp:14-18,55` (empty path → every line goes to
  `_data`, an `ostringstream` that nothing reads).
- **Mechanism**: during a screen share, every INFO line from every WebRTC thread (also the main group call's, since
  sinks are global) is formatted and appended to a growing string, and written to stderr in release.
- **Impact**: memory that grows for the length of the share (plausibly a few MB per hour), freed when it stops, plus
  formatting and stderr writes on WebRTC threads.
- **Fix**: Mac-only and smallest: pass a real log path for the screencast context (as the main context does at
  `:1701`), or a TempBox path deleted after the call. Better, in tgcalls (shared with iOS, where the same fix sits
  uncommitted): don't create the sink for an empty path, stderr/`LS_INFO` only in DEBUG, and `need_log =
  logPath.length > 0` in the macOS `.mm`.
- **UX risk**: none; the dropped logs are unreachable today.
- **How to verify**: a host C++ test that builds `LogSinkImpl` with an empty path, feeds 100k INFO messages and checks
  `result().size()` stays 0 after the fix.
- **iOS cross-ref**: R4 (`in progress` on iOS, tgcalls working tree). Land once in the shared tgcalls.

### M19. libopus is built `-Os` — `todo`, verified

- **Evidence**: `core-xprojects/libopus/libopus/build.sh:60` (`-Os -DNDEBUG`, fixed point, NEON intrinsics kept);
  consumers: TelegramCallsCore (`Package.swift:17`), webrtc, voice messages (`AudioRecorder.swift`, `DataItem.swift`).
  The build phase runs only when `build/` is missing.
- **Mechanism**: 20 ms frames encoded and decoded for the whole call or voice message; `-Os` gives up unrolling and
  inlining in the CELT/SILK DSP loops.
- **Impact**: lower CPU during calls and voice messages; a modest share of call CPU, not measured.
- **Fix**: `-O2` (as iOS `64fc8c95`); keep `--enable-fixed-point` so output stays bit-identical; delete
  `core-xprojects/libopus/build`.
- **UX risk**: none with fixed point.
- **How to verify**: encode/decode a fixed PCM file with old and new libraries, compare bytes and time
  (PowerLabs/Audio pattern).
- **iOS cross-ref**: `64fc8c95`.

### M20. Pattern wallpapers put a `softLightBlendMode` compositing filter on every tile layer — `dropped: measured in WallpaperBlendLab (2184207): rasterizing saves 0.14 ms/frame (-15%) offscreen at 2x but differs by up to 2/255 and needs gradient-animation and scale handling; gain too small for the medium UX risk`, verified (low confidence: measure before changing)

- **Evidence**: `packages/TGUIKit/Sources/ViewController.swift:313-320` (light themes with ≥2 colours:
  `compositingFilter = "softLightBlendMode"`); `:180-210` (TileControl creates N tile layers and copies the filter to
  each). Listed as theme-optimization-log wp#4 / plan item C6, not in its Done list.
- **Mechanism**: a compositing filter needs a backdrop pass; when the chat scrolls above it, the render server may
  re-blend gradient plus N tiles every frame even though the background is static.
- **Impact**: WindowServer CPU/GPU during scrolling and animations over the chat, light pattern themes only. Unknown
  magnitude; whether CA re-renders the occluded background per frame is unverified.
- **Fix**: only if RenderBench shows a gain: rasterize the static background subtree (`shouldRasterize`,
  `rasterizationScale` = backing scale, updated on display change, off during the gradient send animation). Do not
  bake with CoreGraphics `.softLight`, which is a different formula (iOS CLAUDE.md).
- **UX risk**: medium (blurry pattern with a wrong scale; cache rebuilt per gradient animation frame).
- **How to verify**: RenderBench: BackgroundView with a pattern over 2/4-colour gradients, a moving foreground layer;
  time per frame filter vs rasterized and `compare_rgba.py` (≤1/255). With the account, `run.sh chat-navigation
  scroll` comparing `wsCores` and `gpu%`.
- **iOS cross-ref**: related to R23 (not fixed on iOS).
- **Perflab**: RenderBench and run.sh's `wsCores`/`gpu%`; the app's own CPU will not show this.

## Medium changes (M)

### M21. SwiftSignalKit timers have zero leeway, so no timer, `delay` or `timeout` can be coalesced — `done (770513f, core 1140dbe)`, verified

- **Evidence**: `submodules/telegram-ios/submodules/SSignalKit/SwiftSignalKit2/Source/Timer.swift:52-58`
  (`schedule(deadline:repeating:)`/`schedule(deadline:)`, no leeway); `Signal_Timing.swift` (`delay`, `timeout` built
  on it; only `suspendAwareDelay` got a leeway, power-audit #1); `docs/perflab/power-audit.md:16`. Always-armed timers
  of ≥1 s: `AppDelegate.swift:1309` (5 s presence), `AccountContext.swift:824-825`,
  `SharedNotificationManager.swift:276` (10 s), `SharedAccountContext.swift:275` (60 s battery),
  `AppearanceGlobal.swift:80` (60 s), the per-account loops in M3, `ManagedAccountPresence.swift:46` (30 s), every
  `delay(N) |> restart` poll in TelegramCore (`AccountStateManagementUtils.swift:3264`, `Network.swift:366`, …).
  ~92 `Timer(timeout:)` sites in packages and Telegram-Mac, 21 in TelegramCore/Postbox, ~131 `delay(...)` sites.
- **Mechanism**: each timer is a DispatchSource with leeway 0, so the kernel wakes a core at each exact deadline and
  cannot merge wake-ups across subsystems and accounts, even when Telegram is hidden.
- **Impact**: idle and background wake-ups. The iOS fork's Mac benchmark (40 staggered 1-5 s repeating timers): 15.1 →
  4.3 wake-ups/s. Scales with accounts and open chats. CPU time unchanged; the gain is idle residency.
- **Fix**: cherry-pick the SwiftSignalKit2 half of iOS `169301d9`: `TimerLeeway { automatic, precise }`, default
  `.automatic` = min(10% of timeout, 1 s) for timeouts ≥1 s, 0 below; `delay`/`timeout` inherit it; take its shared
  Behavior tests and the shared-core `.precise` hunks (Postbox typing-draft expiry, `PeerInputActivityManager`,
  `GroupCalls`). Then audit the Mac's visible timers of ≥1 s and pass `.precise`: slow-mode countdown
  (`ChatController.swift` ~10915), `CancelResetAccountController.swift:116`, `ChatPollItem.swift:2087`,
  `ExportedInvitationController.swift:511`, `Auth_AwaitingReset.swift:188`, `SuspiciousRevokeModal.swift:261`,
  `SearchGlobalApproveItem.swift:93`, `WalletAuthorizeController.swift:284`, `DiceRollController.swift:1283`,
  `MediaPlayerView.swift:228`, `FoundationUtils/SignalUtils.swift:9,32` (variable), call/recording duration labels,
  gift auction and poll countdowns, `FireTimerControl`, passcode lockout, code-resend countdowns.
- **UX risk**: medium if the audit misses a visible timer: it may tick up to 1 s late. Polls, retries and expiries
  are invisible. Sub-second animation timers are untouched by construction.
- **How to verify**: run `SwiftSignalKitTesting/Behavior` plus iOS's `leewaySeconds` table tests; extend
  `Stress/IdleWakeupTests` with 40 staggered 1-5 s repeating timers and compare `TASK_POWER_INFO` idle wake-ups; grep
  every `Timer(` and `delay(` of ≥1 s in packages against the precise list. On the login screen, `sysmon.py` idle
  wake-ups/s before and after.
- **iOS cross-ref**: iOS CLAUDE.md "Timers and wake-ups", `169301d9` (already applied to SwiftSignalKit2 in the iOS
  repo; the Mac submodule pin does not have it).
- **Perflab**: not fixed upstream (#1 only covered `suspendAwareDelay`). IdleWakeupTests is the harness upstream used.

### M22. Chat history and the chat list are rebuilt and merged on main while the window is hidden, minimized, closed to the Dock or occluded — `done (47580f4)`, verified

- **Evidence**: `packages/ChatUI/Sources/ChatUI/ChatController.swift:4087-4101` (15-input `combineLatest`, no
  visibility input), `:4235-4247` (prepare off main, then `applyTransition` on main: merge, floating photos, scroll
  handlers, `chatInteraction.update`, row backgrounds, `:9798-9916`);
  `packages/ChatListUI/Sources/ChatListUI/ChatListController.swift:980` (14-input `combineLatest`), `:1167-1177`,
  `:1397-1400` (`prepareEntries` builds row items with CoreText layouts, then `tableView.merge` on main). Only
  `ChatListStoriesLab` reads occlusion. `packages/TGUIKit/Sources/Window.swift:403-407,1096-1098` already publishes
  `takeOcclusionState`; `Telegram-Mac/app/AppDelegate.swift:1558-1562` already computes app visibility but uses it
  only for the display link and Lottie; `:1564-1576` keeps the app and window alive after the last window closes.
  SwiftSignalKit's `queue` operator processes every intermediate view, so a burst gives one merge per update.
- **Mechanism**: every history or chat-list emission is diffed, measured and merged into an NSTableView nobody can
  see, followed by a CA commit.
- **Impact**: background main-thread CPU and wake-ups proportional to traffic in the open chat and in any chat on the
  account (power-audit #7 estimates hundreds of chat-list emissions per minute on heavy accounts; roughly 1-5 ms of
  main per update). Telegram commonly sits hidden for hours, so this is likely the largest main-thread cost while the
  user is not looking.
- **Fix**: one visibility signal (window visible, not miniaturized, `occlusionState.contains(.visible)`,
  `!NSApp.isHidden`) as an extra `combineLatest` input to both pipelines. While not visible, return `.complete()`
  before swapping `previousView`/`previousEntries` (and before `previousChatList`, `first`, `scrollUp`, `animated`), but
  only for plain Generic updates without a scroll position; Initial, FillHole and scroll requests pass. On reveal,
  `combineLatest` re-fires and one diff from the last applied view covers everything, applied non-animated. Do not
  gate before the first transition (`readyOnce`). Also skip `chatListPreloadItems.set` while hidden (see M26).
- **UX risk**: real but bounded: on reveal the first frame may show stale content until the catch-up transition lands,
  which can be one longer frame, and insertion animations for messages that arrived meanwhile do not play. Mission
  Control previews of an occluded window may be stale. Read marking (key-window gated), notifications and the Dock
  badge use other pipelines.
- **How to verify**: a pure `shouldApplyHistoryUpdate(visible:updateType:hasScrollPosition:)` helper with ChatUITests;
  a ChatListUITests case feeding N updates while hidden (0 `prepareEntries`/merges) then 1 merge on reveal equal to
  applying all N (ChatListStateProjectionTests style). With the account: a `hidden` scenario in ChatNavigationLab
  (merges ≈ 0 while hidden, 1 on reveal; main%, wake-ups).
- **iOS cross-ref**: the idea of R21 ("pause views of invisible screens", `todo` on iOS) and R12; new Mac code.
- **Perflab**: upstream power-audit #8, listed, not fixed. ChatMergeProbe and ChatListStoriesLab can host it.

### M23. The 5 s presence heartbeat re-sets 4 promises per account forever and undoes the display-sleep network pause — `done (6bbcf5e)`, verified

- **Evidence**: `Telegram-Mac/app/AppDelegate.swift:1309-1312` (repeating 5 s main-queue timer, no gating);
  `:1328-1335` (each tick `presentAccountStatus.set(.single(isOnline) |> then(… delay(50) …) |> restart)`, replacing
  the promise's signal and re-emitting the same value); `account/SharedWakeupManager.swift:71-74`
  (`inForeground |> deliverOnMainQueue`, no `distinctUntilChanged`, then `checkTasks` → `updateAccounts`);
  `:182-198` (`updateAccounts` re-sets `shouldBeServiceTaskMaster(.always)`, `shouldExplicitelyKeepWorkerConnections`,
  `shouldKeepOnlinePresence`, `shouldKeepBackgroundDownloadConnections` for every account); `:61-66` (willSleep →
  wake handler and didWake → sleep handler, swapped; `screensDidSleep` → `.never`, undone by the next tick's
  `.always`).
- **Mechanism**: a polling heartbeat stands in for event-driven presence. Each tick fans out Promise re-subscriptions
  over the service, network and download queues (one combineLatest per live Download), all ending in
  `distinctUntilChanged`. Every display sleep produces a main-session pause then a resume within 5 s.
- **Impact**: 0.2 Hz main wakes plus ~5-15 cross-queue hops per tick per account, always on; a needless pause and
  reconnect on every display sleep.
- **Fix**: (1) run the idle check only while `NSApp.isActive` (otherwise `isOnline` is false by definition); start/stop
  it from the existing active/resign/hide/lock/sleep callbacks, ideally as a one-shot at `30 - SystemIdleTime()`.
  (2) Set `presentAccountStatus` only on change, without the `delay(50) |> restart` wrapper; add
  `distinctUntilChanged` at `SharedWakeupManager.swift:71`. (3) Skip unchanged `Promise.set`s in `updateAccounts`.
  (4) Decide display-sleep networking explicitly: to keep today's effective behaviour (network up), stop touching
  `shouldBeServiceTaskMaster` in the screen sleep/wake handlers, keep `isSleeping` for presence, and un-swap the
  system sleep observers.
- **UX risk**: steps 1-3 none (same online/offline transitions). Step 4 is a product decision (power-audit "Open
  decisions"): pausing the network while the display sleeps stops message notifications with the screen off; the
  spec keeps it up.
- **How to verify**: unit-test SharedWakeupManager with a fake `inForeground` that emits the same value 10 times
  (1 set, not 10); System Trace of the Debug app inactive and hidden; "Pause network connection" log lines on display
  sleep before/after. Check whether the timer is armed before login (if not, step 1 needs the account to observe).
- **iOS cross-ref**: related to R19; the iOS SharedWakeupManager is already event-driven.
- **Perflab**: upstream #10 and #13c, listed, not fixed.

### M24. Chat list views re-query the chat list on every Postbox transaction — `done (core 5751188)`, verified

- **Evidence**: Postbox `ChatListViewState.swift:1048-1049` (`if true || hadRemovals { self.fillSpace(…) }`);
  `:177-260` (a list anchored at the top always has fewer than `halfLimit` entries above, so it queries every time);
  `:203-215` (with a folder predicate a small folder walks every chat evaluating the predicate).
- **Mechanism**: every transaction that reaches the views (any message, read state, M1/M2's no-op writes) makes each
  live chat list view run one or two range queries, even when the chat list did not change.
- **Impact**: iOS measured 0.45 → 0.06 ms per unrelated transaction for a plain list; with folders over thousands of
  chats proportionally more. Per transaction, so it scales with update rate, and runs while hidden.
- **Fix**: port `718f4692`'s ChatListViewState change: per-direction exhausted flags, skip a direction's query while
  exhausted and `fillInputsMayHaveChanged(transaction)` is false (inclusion, embedded state, hidden peers, key-set
  changing chat list operations, and for filtered spaces the filter inputs); keep the `alwaysRefill` test hook.
- **UX risk**: medium in theory (a missed input leaves a chat missing from a folder until the next change); iOS pins
  identical output with a randomized old-vs-new test.
- **How to verify**: port `Postbox/Tests/ChatListViewFillSkipTests.swift` (randomized transactions, output with
  `alwaysRefill` on vs off, `ChatListViewFillCounters.queries`) into a SwiftPM package on the pinned Postbox;
  microbenchmark 5k chats with a folder predicate.
- **iOS cross-ref**: `718f4692`; ports as is.

### M25. Streamed (HLS) video leaves two temp copies of every segment until relaunch, and moves segments through JS as base64 — `partial (cb8d0f1): a-c done; d (ArrayBuffer bridge) not done`, verified

- **Evidence**: `packages/TelegramMedia/Sources/HLSVideoJSNativeContentView.swift:170` (a `partialFile` per request,
  never disposed: the `ActionDisposable` at `:297-305` disposes only `completeFile` and `metaFile`); `:920-935`
  (`sendResponseFileAndClose` reads it, base64-encodes it into JSON, never disposes); `:1751-1758,1791` (appendBuffer
  writes init+segment to a second temp file per segment); MediaPlayer `ChunkMediaPlayer.swift:42-44`
  (`deinit { //TempBox.shared.dispose(self.file) }`); Postbox `TempBox.swift:89-103,170` (an in-memory context per
  file; cleanup only at next launch). Used by the gallery (`GalleryUI/SVideoController.swift:34`), chat and media grid.
- **Mechanism**: ~2× the streamed bytes accumulate in the per-launch temp directory, plus a small leaked context per
  file. Each segment also crosses Swift↔JS as base64 inside JSON both ways (several × segment size in transient heap,
  plus encode/decode CPU).
- **Impact**: disk while watching streamed videos, reclaimed only on relaunch (iOS: 242 MB in a 3-minute browse,
  422 MB after an hour); a Mac that stays up for weeks can accumulate GBs. Transient memory peaks of ~4-6× segment
  size per segment.
- **Fix**: port iOS `7ddeada8` in two steps. First (a-c): dispose the part file in `sendResponseFileAndClose` after
  reading; add `deletesFileOnRelease` to `ChunkMediaPlayerPart.TempFile` and pass true from
  `SourceBuffer.appendBuffer` (the only Mac creator, so delete-on-release is safe); dispose on the write-failure,
  fragment-failure and `self`-gone branches. Second (d), optional: `HLSJSBinaryStore` and the `takeBinary/putBinary`
  bridge so segments cross as ArrayBuffers, keeping base64 as fallback (needs the hls bundle rebuilt).
- **UX risk**: (a-c) low; cover seek-back past the 30 s back buffer. (d) medium (bundle and bridge changes).
- **How to verify**: a MediaPlayer package test that a released `TempFile` with `deletesFileOnRelease` deletes its file;
  a TempBox context-count test; a harness driving `appendBuffer`/`remove` with a synthetic fMP4. With the account,
  `run.sh video-player … hls` plus a temp-dir byte count per phase.
- **iOS cross-ref**: `7ddeada8` ("Found and fixed while measuring").
- **Perflab**: video-player lab; add a temp-dir byte count to its report.

### M26. Up to 30 chat-history preload views stay live and are replayed on every transaction, also while hidden — `done (f4e1837, core 19875d3): option A`, verified (medium confidence)

- **Evidence**: `packages/ChatListUI/Sources/ChatListUI/ChatListController.swift:1459-1477` (up to 30 items, set only
  when on screen, never cleared when the window goes away); TelegramCore `State/ChatHistoryPreloadManager.swift:439`
  (one `messageOfInterestHole` view of 50 messages per item, kept after its hole is filled); Postbox
  `MessageOfInterestHolesView.swift:121-144`, `ViewTracker.swift:278-300` (every view replayed per transaction).
- **Mechanism**: after the top 30 chats are preloaded, 30 × 50-message views keep replaying every transaction (insert,
  media, story and peer scans; M1 makes the peer scan rebuild) and re-emitting onto the preload queue.
- **Impact**: Postbox-queue CPU proportional to transactions × 30, idle and hidden. M1/M2 remove most re-emissions;
  the replay cost stays.
- **Fix**: A: once an item's hole is nil, replace the live history view with a cheaper watch for its next hole (or
  re-check on chat-list index change). B (simple): after N minutes inactive or hidden, set the preload items to an
  empty set and restore them on activation. Optionally restrict to unread/unmuted chats.
- **UX risk**: medium: B can show a loading placeholder for a chat opened right after reactivation; A changes when a
  new hole is noticed. Both need a test that a chat with new messages is preloaded before it is opened.
- **How to verify**: a Postbox harness with 30 MessageOfInterestHolesViews over a 5k-message synthetic DB, ms per
  unrelated transaction with 0 vs 30 views; a manager logic test for release and recreation.
- **iOS cross-ref**: R21 (`todo` on iOS); nothing to port.

### M27. Hardware GIF frames are tagged by FFmpeg, then stripped and re-wrapped by the Mac path; the iOS VideoToolbox fixes are missing — `done (25b7f7a; FFmpeg rebuild pending for the VT patch)`, verified

- **Evidence**: FFmpeg 8.1.2 in `submodules/telegram-ios/submodules/ffmpeg/Sources/FFMpeg` has none of the iOS
  "Local patch (Nanogram)"; `libavcodec/videotoolbox.c:135` (`av_vt_pixbuf_set_attachments` per frame), `:763-764`
  (wait after every synchronous decode); MediaPlayer `FFMpegMediaVideoFrameDecoder.swift:479-484` (a new format
  description per frame); `SoftwareVideoSource.swift:322-370` (macOS `presentableFrame`: 7 `IOSurfaceRemoveValue`,
  `CVBufferRemoveAllAttachments`, a second description and sample buffer per frame);
  `packages/TelegramMedia/Sources/SoftwareVideoLayerFrameManager.swift:16,95` (hardware decode for every GIF);
  FFMpegBinding `FFMpegAVCodecContext.m:9-11,68-71` (`get_format` returns VideoToolbox unconditionally).
- **Mechanism**: per GIF frame (~25-30 fps each), FFmpeg writes colour attachments to the IOSurface (kernel IPC), reads
  them back, waits on the session; the Mac path then removes every tag and wraps the frame twice.
- **Impact**: CPU and kernel IPC per frame × playing GIFs: chat GIFs and the GIF panel (10-20 tiles). iOS measured
  0.74 s of IOSurface IPC per session for the attachments alone. Likely a few percent of a core with the GIF panel
  open. The `get_format` bug is a correctness fallback (no playback after a hwaccel setup failure).
- **Fix**: cherry-pick `019e8379` (videotoolbox.c attachment and wait patch, probe skip), `4cc94ee2` (cache the format
  description while it matches; reuse pool buffers), `42836192` (`get_format` falls back). Mac-specific on top: in the
  hardware path strip tags in the decoder before wrapping, so one sample buffer with the cached description is built;
  remove IOSurface keys once per pooled surface only if VideoToolbox does not re-tag them (measure first).
- **UX risk**: low to medium: colour tags decide colour matching; the Mac deliberately shows GIFs untagged, keep that
  final state. Port iOS `FFMpegVideoToolboxAttachmentTests` to pin it.
- **How to verify**: DecodeBench `decode --mode hw` on H.264 GIF mp4s (the iOS fork's `MediaPlayer/Tests/Resources`),
  cpu/frame and a System Trace IOSurface syscall count; port the attachment, pixel-buffer-reuse and `get_format`
  fallback tests to the SwiftPM MediaPlayer package. With the account, `run.sh gif-panel hw`.
- **iOS cross-ref**: `019e8379`, `4cc94ee2`, `42836192`; iOS CLAUDE.md "Upgrading the vendored FFmpeg".

### M28. MediaBox rewrites the partial-file map after every downloaded chunk — `done (core 0ff4315)`, verified

- **Evidence**: Postbox `MediaBoxFileContextV2Impl.swift:494-534` (after each write: `fileMap.fill`,
  `fileMap.serialize(to: metaPath)`, `storageBox?.update`); `MediaBoxFileMap.swift:204-230` (open, seek, re-encode
  every range, write).
- **Mechanism**: every 16-512 KB chunk costs an extra open, write and metadata update of `<id>_partial.meta`.
- **Impact**: iOS measured ~230 ms of `write()` per device session and 430.7 → 231.4 ms for 2,000 out-of-order
  16 KB writes. Matters during downloads, streaming and auto-download in media channels.
- **Fix**: port `41e7cd8d` and `13bb846e`: serialize every 16 writes and on completion, reset, truncation and close;
  in-process readers that bypass the file context (`internal_resourceData`, `internal_resourceDataIsCached`) consult
  `MediaBox.liveFileMaps`; `F_BARRIERFSYNC` before `link()`.
- **UX risk**: a crash mid-download re-downloads up to 15 chunks. Without the `liveFileMaps` reader path a streaming
  reader can stall on a lagging map; the ported tests cover it.
- **How to verify**: port `MediaBoxMapSerializationBatchingTests` (flush at the 16th write and on close, crash
  recovery, torn-map rejection, direct readers see unflushed chunks); the 2,000-write benchmark.
- **iOS cross-ref**: `41e7cd8d`, `13bb846e`; iOS CLAUDE.md "Media I/O invariants".

### M29. The Lottie frame cache stores whole frames with LZFSE, and chat-sticker caches expire after 1 hour — `done (ee9a00f, f55b999): LZ4 writer + v71; chat lifetime 7 days under a 512 MB budget`, verified

- **Evidence**: `packages/TelegramMedia/Sources/LottieBufferCompressor.swift:9` (`enableDifference = false`),
  `:459-466` (LZFSE encode of each full frame), `:507-511` (LZFSE decode per displayed frame), `:41` (`version = 70`);
  `LottiePlayer.swift:1146` (`case chat = 3_600`); `packages/ChatUI/Sources/ChatUI/MediaAnimatedStickerView.swift:346-347`
  (chat stickers in a chat use `.temporaryLZ4(.chat)`; the "LZ4" name hides LZFSE); square 208 pt chat stickers run at
  60 fps (`:346`, box size `ChatLayoutUtils.swift:55`).
- **Mechanism**: the first loop of every sticker renders with rlottie and LZFSE-encodes each frame (slow to encode;
  iOS attributed 12.1 s of 168 s to it); later frames are full LZFSE decodes; a chat reopened after an hour pays the
  rasterize-and-encode loop again.
- **Impact**: CPU bursts when opening chats with stickers (hundreds of ms per large sticker's first loop, estimate),
  continuous decode for 60 fps 416 px stickers, and cache writes.
- **Fix**: benchmark LZFSE vs LZ4 vs LZBITMAP on real frames; switch the writer to the winner with a version bump
  (70 → 71, coordinate with M7). If encoding gets cheap, raise `.chat` above 1 h under a byte budget (the cleaner
  already walks the directory).
- **UX risk**: none for the codec (lossless); a longer lifetime needs a disk budget.
- **How to verify**: extend `tools/perflab/DecodeBench/Sources/DecodeBench/WebmCache.swift` (already times LZFSE with
  scratch buffers) with LZ4/LZBITMAP on frames rendered from bundled LocalAnimations at 416 px and 40 px; a byte
  round-trip test.
- **iOS cross-ref**: `9d908ce1` (cache format 8, LZBITMAP writer). Note iOS kept LZFSE for XOR-delta video-sticker
  caches; this cache has no deltas.

### M30. Animation clocks are free-running dispatch timers per frame rate, not tied to vsync — `done (b78cfaf); real-display wake-up comparison pending (display asleep)`, verified (low confidence)

- **Evidence**: `packages/TelegramMedia/Sources/LottiePlayer.swift:230-288` (one `RenderFpsLoop` per (duration,
  queue)), `:316-322` (repeating zero-leeway `SwiftSignalKit.Timer`); rates: inline emoji 24-30 Hz (`:1499`), webm
  24/25/30 Hz, chat stickers 60 Hz, main-queue animations get their own loops. `packages/TGUIKit/Sources/DisplayLinkAnimator.swift:5-30,122-343`
  already has a vsync-counting shared driver.
- **Mechanism**: mixed animations on screen run unaligned clocks, each waking `lottieStateQueue` and hopping to main
  for a CA commit at an arbitrary phase; 30 Hz ticks do not merge into 60 Hz ones.
- **Impact**: on the order of 30-60 extra wake-ups/s and main commits while mixed animations are visible in a key
  window; smoother cadence as a side effect. Modest.
- **Fix**: drive `RenderFpsLoop`s from `SharedDisplayLinkDriver` (integer vsync divisors for 60/30/20, an accumulator
  for 24/25) and let its foreground state replace `setLottieRenderingSuspended`.
- **UX risk**: low to medium: 24/25 fps become vsync-quantized (they are presented on vsync anyway); test refresh-rate
  changes between displays.
- **How to verify**: a TGUIKitTests harness like `DisplayLinkRateTests` running 30 + 60 + 25 Hz loops for 10 s,
  counting process wake-ups and main deliveries, old vs new.
- **iOS cross-ref**: R14 (`3cd4aadf`, shared link at the highest requested rate), R5's timer tolerance.

### M31. No launch order file for the Mac binary — `done (311fe98): generator script only; Release ORDER_FILE for stage 1` (low confidence, low priority)

- **Evidence**: `Telegram.xcodeproj/project.pbxproj`: no `ORDER_FILE`/`-order_file` (Release `OTHER_LDFLAGS` is
  `-ObjC`, `:4914`); packages are static, so ~150 packages plus TelegramCore and Postbox link into one executable.
- **Mechanism**: functions touched at cold launch are scattered over a large `__TEXT`; each 16 KB page is a page-in.
- **Impact**: cold launch only (after reboot or memory pressure), probably tens of ms on Apple Silicon SSDs, plus fewer
  resident text pages. No runtime CPU effect.
- **Fix**: generate an order file from Instruments App Launch samples (adapt the iOS `tools/dev/orderfile.py`), set
  `ORDER_FILE` on the Release configuration only. Unknown symbols are ignored, so a stale list never breaks the build.
- **UX risk**: none.
- **How to verify**: `LD_GENERATE_MAP_FILE=YES` to check the layout; cold launch to the login screen after `sudo purge`
  (no account needed for the pre-login part).
- **iOS cross-ref**: `70a3b11e`.

## Design changes (L)

### M32. Every animated frame is a freshly allocated, copied `CGImage`; use pooled IOSurfaces — `partial: deferred, nothing changed — the IOSurface ring needs the onscreen PowerLabs harness (sysmon WindowServer CPU, VM Tracker, P3 captures) on an awake display; the dead metalSupport path is left for the same change`, verified (medium confidence)

- **Evidence**: `packages/TelegramMedia/Sources/LottiePlayer.swift:1584` (rlottie renders into a new
  `Data(count:)` per frame; cache hits decode into a fresh buffer, `LottieBufferCompressor.swift:507-520`);
  `:208-228` (`makeDirectFrameImage` mallocs again and copies or vImage-converts to the display colour space, then
  wraps a `CGImage`); `:2443` and `InlineStickerItemLayer.swift:671` (`layer.contents = image` per frame); square chat
  stickers at 60 fps (`MediaAnimatedStickerView.swift:346`: the `< 200` threshold vs the 208 pt box); no IOSurface in
  the Lottie path. The `metalSupport` renderer (`:1819-2138`) has no callers and would draw nothing (frame data is
  released before draw); delete it rather than revive it.
- **Mechanism**: per frame and per animation: allocate and fill, allocate and copy/convert, then Core Animation copies
  the bitmap into shared memory for WindowServer (VM allocate/free and page faults per new image).
- **Impact**: continuous while anything animates: per 208 pt sticker at 60 fps ≈ 3 × 690 KB × 60 ≈ 125 MB/s of copies
  and ~120 VM allocations/s; the CPU colour conversion upstream measured at 188 µs/frame at 400 px (~1% of a core per
  sticker). Emoji are ~100× smaller, so there the gain is mostly allocation churn. Estimates.
- **Fix**: a small ring (3-4) of IOSurface-backed BGRA buffers per player context (CVPixelBufferPool with IOSurface
  properties); render rlottie and decode the cache directly into the locked surface; tag its colour space once instead
  of converting on the CPU; `layer.contents = surface`; reuse only when `IOSurfaceIsInUse` is false; encode the first
  loop's cache from the surface. Separately (product decision): cap looping chat stickers at 30 fps or fix the
  threshold to match the 208 pt box, which halves everything above.
- **UX risk**: medium: colour matching moves to WindowServer (slight shifts on P3 displays possible); wrong reuse shows
  torn or stale frames; shared multi-target emoji must respect in-use checks. A 30 fps cap is visible.
- **How to verify**: an onscreen harness modelled on `tools/perflab/PowerLabs/Emitter` (N layers at 30/60 Hz, new
  `CGImage` per frame vs an IOSurface ring) with `sysmon.py` (app CPU, WindowServer CPU, GPU) and Instruments VM
  Tracker; window capture compared with `compare_rgba.py` on sRGB and P3. Bundled LocalAnimations, no account.
- **iOS cross-ref**: R11 (iOS went to Metal for large stickers, `56565017`/`93d7c407`); on the Mac the WindowServer
  hand-off copy is an extra cost, and IOSurfaces are lower risk than porting the GPU YUVA path (R5's lossy cache).
- **Perflab**: RenderBench is in-process and will not show the WindowServer copy; use the onscreen PowerLabs pattern.

## Optimizations to enable by default

| Switch | Mac default | Proposed | Gain | Risk |
|---|---|---|---|---|
| SwiftSignalKit `Timer` leeway (M21) | 0 for every timer | `.automatic` (min(10%, 1 s) for ≥1 s), `.precise` for visible timers | ~3.5× fewer timer wake-ups in the iOS fork's Mac benchmark | a missed visible timer ticks up to 1 s late |
| Chat list `skipsDisplayOnScroll` (M12) | off (on in chat and media grid) | on | −15% main while scrolling in the chat; similar expected | scroll-dependent drawing that does not mark itself dirty |
| Tinted custom emoji frame cache (M7) | `.none` | `.temporaryLZ4(.effect)`, ARGB key, cache version bump | rlottie per frame → cache read | disk use per colour |
| Lite mode on Low Power Mode / serious thermal (M11) | ignored | on, when automatic power saving is enabled | animation and compositing cost while the user asked to save energy | visible: animations stop in Low Power Mode |
| `SQLITE_ENABLE_QPSG` + `journal_size_limit` 8 MiB (M9) | off / unbounded | on / 8 MiB | `range(limit:)` 14.6 → 6.9 µs; bounded WAL | check TelegramShare's WAL settings |
| dav1d DotProd/I8MM (M15) | not compiled | compiled (runtime-selected) | ~5-15% of affected AV1 decode functions | none |
| libopus optimization (M19) | `-Os` | `-O2`, fixed point | call/voice codec CPU | none |
| Package exclusivity checks in Release (M17) | on | off (Debug stays on) | low single-digit % of Swift CPU in hot paths | violations no longer trap in Release |
| RangeSet invariant check (M16) | all builds | DEBUG only (+ `@inlinable`) | iOS: 57-100× on fetch bookkeeping | a corrupt set no longer traps in Release |
| WebRTC logging for the screencast instance (M18) | `need_log = true`, stderr, `LS_INFO` | only with a log path; stderr and INFO in DEBUG | unbounded in-memory log during screen share | none (logs were unreachable) |

Keep as they are: `SoftwareVideoLayerFrameManager.usesHardwareDecoding = true` (GIF decode on VideoToolbox; fix the path
instead, M27); TLottie as the default backend; the dead `metalSupport` Lottie path off (it skips colour matching,
hard-codes 60 Hz and leaks its loop timers; see M32); `useExperimentalDownload` already on; reflection metadata on in
packages; no `-Ounchecked` (TL, Lottie, WebP and FlatBuffers parse untrusted data).

## Already done well (keep)

- **Timers**: `suspendAwareDelay` is one wall-clock deadline with granularity as leeway
  (`SwiftSignalKit2/Source/Signal_Timing.swift:61-85`, power-audit #1). `RelativeDateUpdateTimer` schedules one timer
  to the next relative-date boundary. Cache sweep timers have 10% leeway and stop when empty
  (`ScopedImageCache.swift:261-276`, `UniqueGiftBackgroundCache.swift:126-136`). TGUIKit's GCD `delay(_:closure:)`
  gets an implicit leeway.
- **Display link and visibility**: the shared CVDisplayLink signals main only when a link is due (`DisplayLinkGate`,
  `DisplayLinkAnimator.swift:5-29,272-303`) and stops when no link is active or the app is not visible; app occlusion
  stops the display link and suspends all Lottie loops (`AppDelegate.swift:1545-1563`); emoji and stickers stop on
  resign-key and when not visible; emitters, typing indicators, spoiler dust and sparkles freeze when the window is not
  key; paused audio stops its AUGraph after 3 s; the 5 Hz read-metrics tick is gone (#26). This covers iOS R12.
- **App Nap is not defeated**: no `beginActivity`/`NSAppSleepDisabled`; IOPM assertions only during calls and while the
  wallet seed is shown.
- **Network**: keep-connection and presence inputs are deduplicated in TelegramCore (`Network.swift:1144-1156`,
  `ManagedAccountPresence.swift:25-34`); `network.isUserOnline` is not wired on macOS (`Account.swift:1377-1381`), so
  the Rust engine (the Mac default) uses the 30-60 s offline ping cadence and exponential reconnect back-off after 3
  flaps (`mtproto-core/src/transport/mod.rs:78-85`), not the 1-2 s online keepalive.
- **Postbox/core**: presences are stored only when changed (`Postbox.swift:3009-3023`); the chat list compares peers
  with `arePeersEqual`; `AccountStateManager` coalesces pending update groups; `Queue.async` runs inline on the current
  queue; SQLite runs WAL, `synchronous=NORMAL`, `temp_store=MEMORY`, no mmap.
- **Chat rendering**: entries are diffed and `ChatRowItem`s created and measured off main with a premeasured width, so
  merges do not re-measure on main (iOS R20 does not apply); one NSTableView update group per merge; floating avatars
  and chips as layer nodes; the chat's clip display-walk skip; the chat list's projection, `distinctUntilChanged`,
  merge-result tail skip, premeasured rows and `ChatListTextLayer` redraw skip.
- **Images and media**: photos decode off main at display size via `kCGImageSourceThumbnailMaxPixelSize`
  (`MediaUtils.swift:597-607`; iOS R17 is already done here, with a deliberate synchronous first-open path); bounded
  `ScopedImageCache`s with count, byte and idle limits, cleared on pressure; wallpaper decode capped and converted to
  8-bit; one render per unique emoji for all on-screen copies (`MultiTargetContextCache`); identical cached frames reuse
  the previous `CGImage`; H.264/HEVC/AV1 passthrough to `AVSampleBufferDisplayLayer`, AV1 hardware only where
  supported; the HLS player keeps a 30 s back buffer; the video-emoji frame cache (#13d).
- **Memory**: the DispatchSource memory-pressure monitor (extend it, M5); refcounted shared contexts that remove
  themselves; ChatMessageThrottledProcessingManager capped at 1000; ChatController teardown; upstream's lifecycle labs
  found no leaks in what was sampled.
- **Build**: the app target's Release already uses `-O`, WMO, exclusivity off, no reflection metadata,
  `SWIFT_OPTIMIZE_OBJECT_LIFETIME`; the Rust engine is opt-level 3, codegen-units 1, thin LTO, with `--cfg aes_armv8`
  picked up from `.cargo/config.toml` (the iOS Bazel pitfall does not apply); tlottie opt-level 3 with LTO off on
  purpose (one Rust std); mozjpeg `-O3` with NEON; FFmpeg and libwebp release builds.

## Dropped after checking

- **The built-in updater polls Telegram's feed every 20 minutes** (optimizations). The fork's stage-1 plan already turns
  off the internal MTProto updater (Task 8, `AppDelegate.swift:1188`, `AppUpdateViewController.swift:265-269`) and
  points Sparkle at the fork's own appcast (Task 9). What remains is 3 small HTTPS requests per hour, which picks up
  leeway with M21. Compiling it out with `GITHUB` would remove the direct edition's updates.
- **Beta/Alpha builds force file logging** (optimizations). The fork builds with `NANOGRAM STABLE` (stage-1 plan line
  102), so the `#if BETA || ALPHA` override at `AppDelegate.swift:978-982` never applies and the stored setting wins.
- **Tinted-emoji cache keys can collide** (part of the media finding behind M7). `hexString` re-pads single-digit
  components (`Colors.swift`), so the claimed `0A,BC`/`AB,0C` collision cannot happen; only alpha is dropped, and M7
  keeps the key change for that reason alone.
- **Deadline polls refetch from the first second after posting** (part of the CPU finding behind M4). The loop starts
  after waiting the poll's age at open time (`AccountViewTracker.swift:556`), and it ends when the poll closes; M4
  states the corrected behaviour and bound.

## Not checked

- No runtime measurement: nothing was built or run, and there is no account on this Mac. Every magnitude is an
  estimate or an iOS-fork/upstream-perflab measurement on the same code.
- Rust MTProto engine internals beyond ping and back-off timing (request batching, engine-thread wake-ups) and whether
  the Mac cargo build applies `aes_armv8`; MtProtoKit transport details (Network.framework keepalive 5/5/2 vs the iOS
  fork's 30/10/3 in `7abc778f`, shared reachability poll, transport-stats write throttling), which matter only on the
  MtProtoKit fallback.
- iOS R19 product decisions: 30 s `account.updateStatus` while online, promo-channel polling, channel difference cadence.
- Whether AppKit skips the display pass for ordered-out or occluded windows (how much of M22's cost is drawing);
  how often empty chat transitions happen (M6).
- Whether the AppDelegate presence timer (M23) is armed before login.
- Whether TelegramShare opens the same Postbox database (affects M9's WAL settings).
- Whether default cross-module optimization in Xcode's SwiftPM release builds already specializes RangeSet (M16).
- Whether VideoToolbox re-tags pooled IOSurfaces each frame (decides how much of M27's stripping can be avoided).
- `TableView.reloadData(row:)` fallback for offscreen updated rows; `TextView.update` always calling
  `setNeedsDisplay`; duplicate full-screen wallpaper layers (theme log C5); CALayer shadows without `shadowPath`
  (only on transient or small views).
- Upstream power-audit items already listed and not re-verified: #20, #25/#27 (custom emoji loop forever), #31a
  (MediaPlayer `.loop` rebuilds the decoder), #31b (key-window gating of autoplay video), #31d (lottie pool QoS), #31g
  (paused ChunkMediaPlayerV2 timer), #31f (`checkpoint_fullfsync`).
- An exhaustive retain-cycle audit (needs Instruments Leaks with real navigation); memory of the Rust engine, WKWebView
  Mini Apps, gallery frame buffers and call video pools; small Mini App story temp files that are never disposed.
- MediaBox/StorageBox items from iOS `2398d68d`, `80947bac`, `6b815d18`, `a566a470` (file re-touch interval, StorageBox
  batching, VACUUM scheduling, native AES-CTR, bulk FlatBuffers copies) and `0799a724`, `b3627d53`; the TelegramCore
  short log's per-line queue hop and write.
- tgcalls/WebRTC and group-call timers, the share extension, InstantPage V2/LiteHTML bubbles, Stories, Calls, Wallet,
  Gallery and Settings rendering; the rlottie/tlottie engine version; story previews and the HLS JS player beyond M25.
- One-shot bundled animations rasterized on main (`runOnQueue: .mainQueue()`, ~25 sites; the Mac analogue of iOS R13).
- Swift/clang PGO; `ENABLE_DEBUG_DYLIB=YES` in the app's Release config (assumed ignored by `archive`); x86_64 slices
  still built by the core-xprojects scripts; OpenH264 and libvpx optimization levels.

## Native macOS APIs and Apple Silicon hardware (H-specs)

A second pass (2026-11-02) over four areas: video, image and audio; graphics; system frameworks; Apple Silicon CPU features.
It looked for work the app does by hand that a macOS API or the chip already does better.
The lead re-read every cited line. Availability was checked against the MacOSX27.2 SDK headers and swiftinterfaces.
Two runtime probes ran on this Mac (Apple M4, macOS 27.2, no account). `VTIsHardwareDecodeSupported` returns true for VP9 (after
`VTRegisterSupplementalVideoDecoderIfAvailable`), AV1 and HEVC. A legacy `NSThread.threadPriority` gives `qos_class_self() == 0`,
the priorities are 1.0 → 62, 0.5 → 31 and 0.2 → 12, and a later `pthread_set_qos_class_self_np` fails with EPERM.
Nothing else was run. Other gains are estimates from reading the code or from iOS-fork measurements.
The status, size and path conventions are the same as for the M-specs. Paths are relative to `src/`, and `iOS <hash>` means a
Telegram-iOS fork commit. The macOS 15 deployment floor makes every API below unconditional unless a spec says otherwise.
Some SwiftPM packages still declare `.macOS(.v10_13)`, so they need an `#available` check or a raised `platforms`.

### Quick (S)

### H1. Decorative endless Core Animation loops run at 120 Hz on ProMotion; give them a 30-60 Hz frame-rate range — `done (da40434); app build check pending, ProMotion sysmon/Quartz Debug comparison needs an awake display`

- **Evidence**: `packages/TGUIKit/Sources/CAAnimationUtils.swift:76-133` is the shared `makeAnimation`/`animate` path and never
  sets `preferredFrameRateRange`. There is no `preferredFrameRateRange` or `maximumFramesPerSecond` anywhere in `packages/` or
  `Telegram-Mac/`. There are 58 `repeatCount = .infinity` sites, for example `ShimmerEffect.swift:113-124`,
  `ShimmerLayer.swift:218-221,495-500`, `InfiniteProgressView.swift:122-155`, `RadialProgressView.swift:754`,
  `SendingClockProgress.swift:72,85`, `ChatActivitiesModel.swift:156` (typing), `GCChatListIndicator.swift:83` and
  `AvatarStoryIndicatorComponent.swift:89,105,120`. In `docs/perflab/power-audit.md:220`, 8 typing indicators needed a render on 720 of 720 frames at 120 Hz.
- **Today**: while a spinner, shimmer, typing indicator, sending clock or story ring is visible, the render server makes up to 120
  frames/s and keeps a ProMotion panel at 120 Hz.
- **Use instead**: `CAAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)` on infinite
  decorative loops. The API is in `CAAnimation.h:63`, macOS 12+. Port the `setDecorativeLoopFrameRate()` helper from iOS `30ad5297`, or set it in
  `makeAnimation` when `repeatCount.isInfinite`. Leave transitions and scroll-linked motion at the default.
  The gain applies on ProMotion and ≥ 90 Hz panels (MacBook Pro 14/16 with M1 Pro and later, 120/144 Hz external displays), on any chip.
- **Gain**: energy. The render server and GPU do half the work (or less) while only decorative loops animate, and the panel can drop below 120 Hz.
  From the upstream lab cost, that is about 11-14 ms/s less render work for an 8-indicator scene. App CPU is unchanged.
- **Fallback**: none. On a 60 Hz screen the range has no effect.
- **UX risk**: low. These loops look the same as on any 60 Hz Mac. Other 120 Hz content on screen keeps the panel at 120 Hz.
- **How to verify**: port iOS `CAAnimationFrameRateTests` to TGUIKitTests (infinite animations get 30-60, finite ones are
  untouched). Build a PowerLabs/Emitter-style window with 8 shimmer and spinner layers on the built-in ProMotion panel, and compare
  `sysmon.py` wsCores and gpu% and the Quartz Debug frame meter with and without the hint.
- **Confidence**: medium (the mechanism is documented; the size on macOS was not measured).

### H2. CDN media parts are AES-CTR decrypted one 16-byte CommonCrypto call at a time; use native `kCCModeCTR` (iOS `a566a470`) — `done (f4bb74b, core 1e9c875)`

- **Evidence**: in `submodules/telegram-ios/submodules/MtProtoKit/Sources/MTAes.m`, `:279-330` creates an ECB cryptor and
  `nextKeystreamBlock` (`:322-329`) makes one `CCCryptorUpdate` per 16 bytes; `:352-395` loops it with a manual XOR.
  `MTEncryption.m:816-826` (`MTAesCtrDecrypt`). Every CDN part goes through it: `FetchV2.swift:918` (the Mac default
  downloader) and `MultipartFetch.swift:446`. This runs with the Rust engine too. The Mac `MTAes.m` is byte-identical to the file at the
  parent of iOS `a566a470` (diffed).
- **Today**: about 65,536 CommonCrypto calls plus an Objective-C message per block for each MiB of CDN media (large channels).
- **Use instead**: cherry-pick `a566a470`'s `MTAes.m`. It uses `CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES,
  ccNoPadding, iv, key, 32, NULL, 0, 0, kCCModeOptionCTR_BE, &ref)` and makes one `CCCryptorUpdate` per buffer, which lets corecrypto
  use the pipelined multi-block ARMv8 AES path. The ECB path stays for the 2^64-block carry.
  CommonCrypto has CTR since macOS 10.7, and every M-series chip has the AES instructions.
- **Gain**: CPU per downloaded CDN MiB drops from per-call overhead to roughly the hardware AES cost (estimate: an order of magnitude on
  the decrypt step). This removes the existing spec's "native AES-CTR" item under Not checked.
- **Fallback**: the ECB keystream when the CTR cryptor cannot be created, as `a566a470` does.
- **UX risk**: none if the output is byte-identical. A counter bug would corrupt media, which the FetchV2 hash check and the tests catch.
- **How to verify**: port `Tests/MTAesCtrStreamTests.m` (known-answer and chunked-stream equality against the old ECB code) into the
  MtProtoKit SwiftPM test target (`Package.swift:32-35`). Add a 64 MiB micro-benchmark in 128 KiB parts before and after.
- **Confidence**: high.

### H3. The Rust engine's network availability polls `SCNetworkReachability` every 5 s with zero leeway; use NWPath events — `done (core a001272)`

- **Evidence**: `MtProtoKit/Sources/MTNetworkAvailability.m:58-88` (an `SCNetworkReachability` for 0.0.0.0, plus a repeating 5.0 s
  `MTTimer` for the object's lifetime) and `MTTimer.m:68` (`dispatch_source_set_timer(..., 0)`, no leeway).
  `MTProtoRustEngine/Sources/MTProtoRustEngine/RustEngineRuntime.swift:198` creates it, and its delegate (`:362`) drives
  `mt_engine_set_network_available`. The runtime already resets on `NSWorkspace.didWakeNotification` (`:201`). `Reachability.swift:87-130`
  already runs an `NWPathMonitor`. iOS `3d30de4c` only merged the polls into one; it still polls.
- **Today**: 17,280 uncoalesced wake-ups a day for the whole uptime, idle or not. Three network monitors run per process. This is the
  "shared reachability poll" listed under Not checked in the existing spec. It applies to the Rust default, not only to the MtProtoKit fallback.
- **Use instead**: one `nw_path_monitor` (C API, as `RustStreamHost` uses) or `NWPathMonitor`, where `status == .satisfied` means
  available, shared with `Reachability.networkType`. Delete the 5 s timer; if a safety net is wanted, use 60 s with 10 s leeway.
  Keep `SCDynamicStore` for the router-MAC identity (`RustNetworkIdentity.swift:117-170`), which NWPath does not expose. Available on macOS 10.14+.
- **Gain**: about 17k fewer zero-leeway wake-ups a day and one fewer monitor. Change detection is as fast or faster.
- **Fallback**: none needed.
- **UX risk**: low. Sleep and wake are already handled. Captive portals and VPNs are covered by the engine's own back-off.
- **How to verify**: an `IdleWakeupTests`-style `TASK_POWER_INFO` count for a process holding `MTNetworkAvailability` vs the NW
  monitor. On the Debug app's login screen, run `sysmon.py` for idle wake-ups, and toggle Wi-Fi to see the availability-changed log line.
- **Confidence**: high.

### H4. Static-sticker thumbnails decode the same WebP twice at full size; decode once, at the target size — `done (2a53b7c); AJpeg path unchanged`

- **Evidence**: `packages/TelegramMediaUtils/Sources/TelegramMediaUtils/FetchCachedRepresentations.swift:416`
  (`convertFromWebP`, a full libwebp decode through `decodeForDisplay`, which redraws into a second bitmap, `submodules/libwebp/Sources/libwebp.m:8-17`).
  `:436-439`: when that succeeded, `WebPImageDecoder` decodes the same data again and replaces the image. `:444-452`: a PNG encode
  with `kCGImageDestinationLossyCompressionQuality`, which PNG ignores. The AJpeg representation at `:493,513-517` also decodes in full and then redraws.
- **Today**: each static sticker's cached representation costs two full 512×512 decodes and two full-size redraws, in bursts
  when a pack or the sticker panel opens for the first time.
- **Use instead**: delete the second `WebPImageDecoder` pass. Decode at the needed size, either with libwebp scaling
  (`WebPDecoderConfig.options.use_scaling/scaled_width/scaled_height`, vendored 1.3.2) or with ImageIO
  `CGImageSourceCreateThumbnailAtIndex` and `kCGImageSourceThumbnailMaxPixelSize` (WebP with alpha since macOS 11). Drop the ignored quality option.
- **Gain**: about half the CPU and peak memory of these jobs, more when the target is small. This is a one-off per sticker, so it shortens first-open bursts.
- **Fallback**: the current path when ImageIO returns nil.
- **UX risk**: low. ImageIO tags sRGB instead of DeviceRGB, which can shift colours slightly on P3. ImageIO also parses untrusted WebP in the
  system decoder, a security-ownership trade-off. The libwebp-scaling route avoids both.
- **How to verify**: a unit test on bundled `.webp` stickers comparing old and new output with `compare_rgba.py`, plus a micro-benchmark of time and peak allocation.
- **Confidence**: high.

### H5. Every GIF opens its own VideoToolbox session; use software below 320 px and a 16-session budget (iOS `c2c22996`, extends M27) — `done (28d0503, 8edbc7e; core 1aef8d8, 54151f1)`

- **Evidence**: `packages/TelegramMedia/Sources/SoftwareVideoLayerFrameManager.swift:16` (`usesHardwareDecoding = true`) and `:95`
  (hardware for every non-WebM GIF, with no size check and no cap). iOS `c2c22996` measured CPU per frame on the Mac host, software → VideoToolbox:
  256×144 77 → 172 µs (hardware slower), 320×320 433 → 158, 480×360 863 → 175.
- **Today**: tiny clips pay more for the session and IOSurface than software H.264 would cost. A full GIF panel opens one session per tile.
- **Use instead**: request the FFmpeg VideoToolbox hwaccel only when the longer side is ≥ 320 px and a slot is free in a process-wide
  `HardwareDecoderBudget(16)` (port `MediaPlayer/Sources/HardwareDecoderBudget.swift` as is). Otherwise decode in software with
  `skip_loop_filter`. Works on all M-series chips.
- **Gain**: about 2× cheaper decode for sub-320 px GIFs and a bounded number of hardware sessions in big grids. Small but steady while GIFs play.
- **Fallback**: the software decoder (exists).
- **UX risk**: low (iOS ships the same).
- **How to verify**: port `GifTileHardwareDecodeTests` (240 px stays software, larger asks for hwaccel, the budget caps live readers)
  and run DecodeBench `decode --mode hw|sw` per clip size. With the account, `run.sh gif-panel hw|sw`.
- **Confidence**: medium (iOS-measured on this host's chip family; the Mac tile mix is unmeasured).

### H6. HLS never picks AV1 renditions, even on M3+ where AV1 decodes in hardware — `done (9c174f7)`

- **Evidence**: `packages/TelegramMedia/Sources/HLSVideoJSNativeContentView.swift:320-322`: `isNativeVideoCodecSupported` accepts only
  h264/h265/avc/hevc, so the AV1 tie-break at `:351-368` is dead code. `ChunkMediaPlayerV2.swift:11-14` already has
  `internal_isHardwareAv1Supported`, and `MediaDataReader.swift:92-95` routes AV1 to VideoToolbox when it is true. On iOS,
  `TelegramUniversalVideoContent/Sources/HLSVideoContent.swift:28-47` allows AV1 behind `ios_enable_hardware_av1`.
- **Today**: every Mac streams the H.264/HEVC renditions of HLS videos and stories.
- **Use instead**: accept `"av1"/"av01"` when `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` is true (M3 and later; probed true on
  M4), optionally behind an app-config switch like iOS's. Never enable it for software dav1d on M1/M2.
- **Gain**: fewer bytes at the same quality on M3+ (AV1 renditions are typically smaller than H.264; depends on the server encode). That saves data,
  radio energy and cache disk. Decode stays on the media engine. Nothing changes on M1/M2.
- **Fallback**: H.264/HEVC when the probe or the switch is off.
- **UX risk**: low to medium. Check ABR switching when the AV1 and H.264 ladders differ, and check 10-bit renditions (see H22).
- **How to verify**: a unit test of `HLSQualitySet` built from synthetic h264+av1 alternatives, with the probe true and false. Confirming that real AV1
  renditions appear needs the Debug account.
- **Confidence**: medium (code path verified; server-side availability not).

### H7. Auto-download ignores Low Data Mode and expensive (tethered) networks; use `NWPath.isConstrained/isExpensive` (iOS `3d30de4c`) — `done (957d823, core 036e94f)`

- **Evidence**: `packages/TelegramMediaUtils/Sources/TelegramMediaUtils/AutomaticMediaDownloadAbility.swift:10-14` (only the global flag and
  per-peer categories) and `packages/InAppSettings/Sources/InAppSettings/AutomaticMediaDownloadCategoryPeers.swift:136-143,206-207`. There is no
  `isConstrained`/`isExpensive` in `packages/`, Reachability or TelegramCore.
- **Today**: on an iPhone hotspot, or on Wi-Fi marked Low Data Mode, the Mac auto-downloads video, files and GIFs as it does at home.
- **Use instead**: cherry-pick the `Reachability.isConstrained` part of `3d30de4c`, add `isExpensive`, and fold both into the
  auto-download settings signal so that video and file auto-download and prefetch pause while constrained (and optionally while expensive). Thumbnails and small photos stay.
  `isExpensive` needs macOS 10.14 and `isConstrained` 10.15.
- **Gain**: data savings on metered links, following the system setting as Safari and Mail do.
- **Fallback**: none needed.
- **UX risk**: media stops auto-loading on a hotspot. Expose a "Respect Low Data Mode" setting, on by default as on iOS.
- **How to verify**: a unit test with a fake path signal (`isDownloable` is false while constrained). Then turn on Low Data Mode for the Wi-Fi network
  and watch the signal in the Debug log on the login screen.
- **Confidence**: medium.

### H8. Messages read on another device keep their banners: `clearNotifies(by:)` removes pending requests, not delivered notifications — `done (0760adc)`

- **Evidence**: `Telegram-Mac/utils/UNUserNotifications.swift:362-375` collects delivered identifiers, then calls
  `removePendingNotificationRequests`. Every request is added with `trigger: nil` (`:327`), so none is ever pending. The caller is
  `ApplicationContext.swift:853-855` (`appliedIncomingReadMessages`). The sibling `clearNotifies(peerId:maxId:)` (`:339-357`) removes correctly but makes one XPC call per notification.
- **Today**: chats read on the phone stay in Notification Center on the Mac. Matching is O(n·m).
- **Use instead**: `removeDeliveredNotifications(withIdentifiers:)` once, matched with a `Set<MessageId>`. Batch the sibling into one call. macOS 10.14+.
- **Gain**: correctness, and fewer XPC round trips to `usernoted`.
- **Fallback**: none. **UX risk**: none (matches the in-app read path).
- **How to verify**: put a protocol over the UN centre calls and unit-test that delivered ids are removed. Manually, post a local notification with the `reply.*`
  userInfo keys from the Debug app's login screen, call `clearNotifies(by:)`, and check `getDeliveredNotifications`.
- **Confidence**: high.

### H9. The Spotlight index goes stale and leaks logged-out accounts' contacts; every item shows the app-update icon — `done (8f7c6e5)`

- **Evidence**: `Telegram-Mac/utils/Spotlight.swift:37-47`: `kUTTypeData`, `thumbnailData = theme.icons.appUpdate`, and one domain (the bundle id)
  for all accounts. `:94-110`: both `distinctUntilChanged` closures compare only `count`. `:128-151` diffs against an in-memory list that is empty
  at each launch, and `:157-161` (`deinit`) deletes only this session's items.
- **Today**: if the recent peers change but their count stays the same, the index is never updated. Items from earlier launches, or from an
  account that has since logged out, are never deleted.
- **Use instead**: `CSSearchableItemAttributeSet(contentType: .contact)` with `displayName` and a 64 px avatar PNG (the avatar
  pipeline already used for notifications), per-account `domainIdentifier "account.<id>"`, and an `expirationDate`. On start, call `deleteSearchableItems(withDomainIdentifiers:)`
  and re-index, or use a named `CSSearchableIndex` with `beginBatch`/`endBatch(withClientState:)`. Delete the domain on logout
  and when the passcode lock turns on. Compare peers by id and title. CoreSpotlight is macOS 10.13+ and UTType macOS 11. (H27's `IndexedEntity` is the longer-term replacement.)
- **Gain**: correct, fresh results with avatars, and privacy cleanup.
- **Fallback**: none needed. **UX risk**: low; honour the passcode lock.
- **How to verify**: a unit test of the comparator. A named-index test that indexes, rebuilds the context and checks with `CSSearchQuery` that
  old items are gone, using synthetic peers and no account.
- **Confidence**: high.

### H10. FFmpeg's I8MM kernels are dropped because gas-preprocessor comments out `.arch` lines; assemble with clang directly — `todo`

- **Evidence**: `core-xprojects/ffmpeg/ffmpeg/build.sh:126-131` (arm64 `AS="$GAS_PREPROCESSOR_PATH -arch aarch64 -- $CC"`).
  `submodules/telegram-ios/submodules/ffmpeg/Sources/FFMpeg/gas-preprocessor.pl:1099` comments out `.arch` lines for clang.
  `core-xprojects/ffmpeg/build/scratch/arm64/config.h:44-45,107` has `HAVE_DOTPROD 1`, `HAVE_I8MM 0` and `HAVE_I8MM_EXTERNAL 0`, and
  `ffbuild/config.log:16256,16289` shows "instruction requires: i8mm". `nm libavcodec.a | grep -ci i8mm` gives 0, although
  `ffmpeg-8.1.2/libavcodec/aarch64/hevcdsp_init_aarch64.c` has 13 I8MM references (HEVC qpel/epel).
- **Today**: HEVC software decode (whenever `hevc_videotoolbox` is not used) never uses the I8MM kernels on M2+, and the build drops CPU
  extensions without warning.
- **Use instead**: for arm64, drop gas-preprocessor and use clang's integrated assembler (`--as="$CC"`), as FFmpeg 8 supports. Runtime
  cpudetect (already on) then selects I8MM on M2+ only. This Mac (M4) reports `hw.optional.arm.FEAT_I8MM: 1`.
- **Gain**: small (software HEVC only). The main value is that the build stops losing kernels silently.
- **Fallback**: runtime dispatch; M1 keeps NEON+DotProd.
- **UX risk**: build-only (asm syntax that gas-preprocessor was smoothing over).
- **How to verify**: after reconfiguring, check `grep 'HAVE_I8MM 1' config.h`, check that `nm libavcodec.a | grep -c i8mm` > 0, and run `checkasm --bench` for hevc_pel.
- **Confidence**: medium (the build side is verified; HEVC software-decode frequency is unknown).

### H11. No `OSSignposter` intervals or MetricKit on the Mac; port the iOS signposts and the on-device report store (iOS `de19913f`) — `done (73de50e)`

- **Evidence**: no `os_signpost`, `OSSignposter`, `MXMetricManager` or `MetricKit` in `Telegram-Mac/` or `packages/` (grep).
  `packages/CrashReports/Sources/CrashReports/CrashReportStore.swift` has no MetricKit input. SDK: `MXMetricManager` is macOS 12 (marked
  to-be-deprecated, "Use MetricManager"), and `MetricManager` is macOS 27.
- **Today**: PerfLab and xctrace traces have no app-defined intervals, and users' hangs and CPU or disk-write exceptions are never seen.
- **Use instead**: `OSSignposter` (macOS 12) intervals around `chatHistoryEntriesForView`, the chat-list merge, the composer keystroke,
  Lottie and video frame production and media decode, named as on iOS so traces compare. Keep MetricKit diagnostics on device: `MetricManager` on
  macOS 27, `MXMetricManager` on 15-26. Export them only from Debug settings.
- **Gain**: attributable traces for every later spec and real-world hang and energy data. When nothing records, the cost is an enabled check.
- **Fallback**: `MXMetricManager` below 27. **UX risk**: none (nothing is uploaded).
- **How to verify**: an xctrace Time Profiler launch of the Debug app shows the intervals on the login screen and in the labs. Add unit tests of the report store's dedup and limits.
- **Confidence**: medium (which MetricKit payloads macOS actually delivers was not checked).

### H12. Passport MRZ OCR is a bundled Hough-transform plus neural net run synchronously on main; use Vision — `done (1a0cdb0)` (low priority)

- **Evidence**: `packages/OCR/Sources/ocr.mm` (630 lines), `genann.c` (357) and `fast-edge.cpp` (550).
  `packages/PassportUI/Sources/PassportUI/PassportController.swift:93-95,2294` calls `recognizeMRZ(image.precomposed(), nil)` in the main-thread file-panel completion.
- **Today**: choosing a passport scan blocks main while the custom OCR runs. About 1.5k lines of unmaintained C/C++ ship for this.
- **Use instead**: on a background queue, run `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection = false`, `["en-US"]`).
  Keep bottom lines matching `^[A-Z0-9<]{30,44}$` and pass them to the unchanged `TGPassportMRZ.parseLines`. Delete `packages/OCR`.
  Vision has run on the Neural Engine since macOS 10.15.
- **Gain**: no main-thread stall, less code, and probably better accuracy (not measured).
- **Fallback**: none. **UX risk**: low (rarely used feature).
- **How to verify**: a SwiftPM test with ICAO specimen MRZ images, comparing parsed fields from the old and new paths.
- **Confidence**: medium.

### Medium (M)

### H13. `ThreadPool` uses legacy `threadPriority`: the Lottie and avatar pools run at priority 62 with no QoS, above the main thread, and every enqueue wakes every worker — `done (52ffa2d, core df65bdef)`

- **Evidence**: `submodules/telegram-ios/submodules/SSignalKit/SwiftSignalKit2/Source/ThreadPool.swift:117-131` (`thread.threadPriority = …`
  before `start()`; `qualityOfService` is never set) and `:151` (`pthread_cond_broadcast` for every `workOnQueue`). The pools are
  `LottiePlayer.swift:67` (4 threads at 1.0, all frame filling) and `PeerAvatarImage.swift:19` (`graphicsThreadPool`, 5 at 1.0, avatars and gallery decode).
  `FetchCachedRepresentations.swift:395,763,820,825` runs background cache generation on the Lottie pool too, and `:74` has 1 thread at 0.1.
  Also `SoftwareVideoLayerFrameManager.swift:12` (3 at 0.2) and `TransformImageView.swift:5` (2 at 0.3, visible chat images).
  Probe on this Mac, same order as ThreadPool (set, then start): 1.0 → sched priority 62, 0.5 → 31 and 0.2 → 12, with `qos_class_self() == 0` and
  `pthread_set_qos_class_self_np` → EPERM. A `.userInitiated` thread reports QoS 0x19.
  SDK `pthread/qos.h:128-133` says a thread that has called `pthread_setschedparam` is permanently opted out of QoS. This is upstream power-audit #31d,
  listed under Not checked in the existing spec.
- **Today**: 15 parked threads. The 9 at 1.0 run at 62, above the user-interactive band (47) the main thread uses, so the scheduler keeps
  sticker, emoji, avatar and even background cache work on P-cores. That work can preempt main and gets no E-core placement, no App Nap or
  background clamping and no GCD QoS overrides. The pools at 0.1-0.3 (12-19) do visible image decode below the default band and can never be boosted.
  Each enqueue wakes all parked workers in the pool, but only one takes the task.
- **Use instead**: give `ThreadPool` `init(threadCount:qos: QualityOfService)`, setting `thread.qualityOfService` before `start()` (macOS 10.10+), and
  keep the old init as a shim that maps priority to a QoS (≥ 0.9 → `.userInitiated`, ≥ 0.4 → `.default`, else `.utility`) so iOS still compiles.
  Replace the broadcast with `pthread_cond_signal`. Suggested starting classes: Lottie `.userInitiated` (try `.utility` later, since frames are
  buffered ahead), cache generation moved to `cacheThreadPool` at `.utility`, `graphicsThreadPool` and `TransformImageView` at `.userInitiated`, GIF workers at `.utility`.
  As an L follow-up, back each queue with a serial `DispatchQueue` targeting a QoS-classed concurrent queue so GCD sizes the pool to the P/E topology.
  This applies to every M-series chip (P and E clusters).
- **Gain**: energy and main-thread latency. Sustained animation work can leave the P-cores, which matters most on M1/M2/M3 base chips with 4 P-cores, and stops
  competing with main while sticker- or emoji-heavy chats scroll. There are up to N-1 fewer spurious wake-ups per task (3 on Lottie, 4 on avatars).
  Visible decode gets a proper priority. Not measured; expected among the largest steady wins in this section.
- **Fallback**: none needed.
- **UX risk**: Lottie frames could drop under load if the pool is demoted too far. Start at `.userInitiated` and measure emoji-panel and gif-panel before going lower.
- **How to verify**: a SwiftSignalKitTesting test asserting `qos_class_self()` inside a task (0 today, the requested class after). A wake-count test
  (N parked workers, M tasks: about N×M wake-ups with broadcast, M with signal). `IdleWakeupTests`/`TASK_POWER_INFO` and `powermetrics --samplers cpu_power`
  (E and P residency) with an offscreen emoji-heavy LottiePlayer in PowerLabs.
- **Confidence**: high (the mechanism was measured on this Mac; the energy gain is an estimate).

### H14. Video stickers and video emoji decode VP9 on the CPU with libvpx, then convert and scale at full size; decode on VideoToolbox (iOS `632f1d87`/`06d7091f`) — `partial (091fa70): VP9Hardware port + hardware sticker reader in WebmRenderer done; VT-side scaling, fused conversion and the hardware cache builder not ported`

- **Evidence**: `core-xprojects/ffmpeg/ffmpeg/build.sh:63,69`: the only VP9 decoder is `libvpx_vp9`, and the hwaccels are h264/hevc/av1.
  `SoftwareVideoLayerFrameManager.swift:42,95` (`&& !hintVP9`). `LottiePlayer.swift:1800-1812` (`WebmRenderer` over `SoftwareVideoSource(hintVP9: true)`) and
  `:1395-1431` (decode, then `vImageScale_ARGB8888` to display size). `FFMpegMediaVideoFrameDecoder.swift:523-532,580` (`forceARGB`: a full-size
  YUVA→ARGB conversion into a new buffer, before any downscale). `FetchCachedRepresentations.swift:413` (the first-frame thumbnail is a full libvpx decode).
  On this Mac (M4, macOS 27.2), `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)` followed by `VTIsHardwareDecodeSupported` returns **true**.
  The iOS fork's `VP9Hardware` module (`VP9HardwareDecoder.swift`, `WebMStickerDemuxer.swift`) is already `@available(macOS 11.0)`.
- **Today**: each video sticker and emoji frame (VP9 with alpha in WebM BlockAdditional) is decoded by libvpx until the frame cache has a loop (#13d).
  When the panel or a pack opens, or a chat full of video emoji, or a cache is rebuilt after M29's 1 h expiry, dozens of libvpx decoders run at once.
  Each 512×512 frame is converted to ARGB on the CPU and then scaled down to 40-200 px.
- **Use instead**: port `VP9Hardware`. Register the supplemental decoder once, probe `VTIsHardwareDecodeSupported`, run two `VTDecompressionSession`s
  (colour, plus alpha from the demuxer's BlockAdditional), and keep a session only when
  `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` is true. Apply a process-wide session budget, and keep full-range or non-8-bit-4:2:0 on libvpx.
  Mac addition: put the display size in `destinationImageBufferAttributes` (`kCVPixelBufferWidthKey/HeightKey`), or use a
  `VTPixelTransferSession`, so scaling happens before the CPU YUVA→BGRA pass. Also port `632f1d87`'s fused bit-exact conversion and premultiply
  for the libvpx fallback, and `06d7091f`'s hardware frame-cache builder.
  The API needs macOS 11+. Hardware is confirmed on M4 by probe; M1/M2/M3 are decided at runtime by the same probe.
- **Gain**: CPU and energy at every first play and cache rebuild of video stickers and emoji. iOS measured libvpx at 1.45 s of a 4.79 s cache build
  burst, and VideoToolbox at 0.08-0.13 ms per frame. Converting at display size cuts the CPU conversion about 10-25× for emoji and panel thumbnails, and
  no full-size ARGB buffer is allocated per frame. Complements M8, which skips the decoder on cache hits.
- **Fallback**: libvpx on no hardware, an exhausted budget, a full-range or odd format, or any decode error (rewrite the whole cache file from libvpx, as `06d7091f` does).
- **UX risk**: low to medium. Full-range files must stay on libvpx (alpha 255 → 235 otherwise). Check BT.601 video-range colours if scaling moves into VT.
  A session adds a few ms of first-frame latency.
- **How to verify**: port `VP9HardwareTests`, `VideoStickerHardwareSelectionTests` and `VideoStickerFrameCacheTests` with their fixtures (`sticker_vp9.webm`,
  `sticker_24fps.webm`) into the SwiftPM TelegramMedia/MediaPlayer tests. Log `VP9HardwareProbeResult` on an M1/M2 Mac too. Measure CPU per frame in
  DecodeBench (libvpx vs VT) and compare frames with `compare_rgba.py`.
- **Confidence**: medium → high for M4 (probed); medium for older chips.

### H15. libvpx is v1.11.0 (2021) with runtime CPU detection off and no DotProd/I8MM kernels; update to v1.17.0 (iOS `9b3a7a94`) — `todo`

- **Evidence**: `core-xprojects/libvpx/source/CHANGELOG:1` (`2021-09-27 v1.11.0`), `build/arm64/vpx_config.h:18,56` (`HAVE_NEON 1`,
  `CONFIG_RUNTIME_CPU_DETECT 0`), `build/arm64/libs-arm64-darwin20-gcc.mk:25` (`-march=armv8-a -O3`), and `nm libvpx.a | grep -ci dotprod` → 0.
  Consumers: FFmpeg `--enable-libvpx` (VP9 sticker decode with alpha, `build.sh:59,63-64`), and tg_owt/WebRTC (VP8/VP9 call video,
  `submodules/tg_owt/CMakeLists.txt:154`, `packages/TelegramCallsCore/Package.swift:15`). In 1.17, `configure.sh` turns runtime detection on for arm64-darwin and
  probes `neon_dotprod`/`neon_i8mm` through `sysctlbyname`. This resolves the existing spec's "libvpx optimization levels" item under Not checked.
- **Today**: VP9 decode (the fallback for H14, and all of it until then) and call VP8/VP9 encode and decode run 2021 NEON-only kernels.
- **Use instead**: update `core-xprojects/libvpx/source` to the v1.17.0 tag iOS uses, keep runtime CPU detection on, delete `core-xprojects/libvpx/build`,
  and rebuild FFmpeg and tg_owt. DotProd is selected on M1+ and I8MM on M2+ at runtime (`hw.optional.arm.FEAT_*`). No Apple chip has SVE.
- **Gain**: an estimated 10-30% on VP9 decode and more on call encode (libvpx 1.13-1.17 Arm work; not measured here).
- **Fallback**: runtime dispatch to plain NEON.
- **UX risk**: API/ABI changes for tg_owt and FFmpeg. iOS already builds both against 1.17. Decoder output is bit-exact by spec.
- **How to verify**: check `nm libvpx.a | grep -c neon_dotprod` > 0 and `CONFIG_RUNTIME_CPU_DETECT 1`. Time a VP9 sticker in DecodeBench (which links this libvpx)
  before and after, and confirm identical output with a vpxdec-style `--md5` check.
- **Confidence**: high.

### H16. The voice-note recorder changes the microphone's system-wide sample rate, does not resample 44.1 kHz input, and locks and allocates on the IO thread; use AVAudioEngine and AVAudioConverter — `done (c18caa9)`

- **Evidence**: `packages/TelegramMedia/Sources/AudioRecorder.swift:431-433` (raw `kAudioUnitSubType_HALOutput`). `:470-498` reads the available nominal
  rates, picks the entry whose `mMinimum == 48000` or else `table[0]`, then calls `AudioObjectSetPropertyData(kAudioDevicePropertyNominalSampleRate)` on the
  default input device (passing an `AudioValueRange` with its size) and never restores it; `sampleRate = mMaximum`. `:720-741` is an integer upsampler only for
  16/24 kHz (`values[i]/3` truncates; the extra `values[count]` write overruns a `ratio-1`-byte pad), and every other rate passes through.
  `CustomAudioConverter` (`:9-100`) is created at `:504` but `.convert(` is never called. The Opus writer is fixed at `rate = 48000`
  (`OpusBinding/Sources/opusenc/opusenc.m:124-126`). `CallsUI/MicroListenerController.swift:161-175` forces the device rate the same way.
  The IO callback (`:222-258`) mallocs and takes locks. iOS `4c229c73` has the real-time-safe callback.
- **Today**: starting a voice note silently reconfigures the user's microphone for every app, which DAWs and video calls notice, and Audio MIDI Setup changes.
  On a device without a 48 kHz entry (44.1 kHz-only USB interfaces), 44.1 kHz samples go into a 48 kHz Opus stream, so the note plays
  about 8.8% fast and high (inferred from code, not reproduced). AirPods HFP get a crude interpolator.
- **Use instead**: `AVAudioEngine.inputNode.installTap(onBus: 0, bufferSize:, format: inputNode.outputFormat(forBus: 0))` at the device's native format,
  then `AVAudioConverter` to 48 kHz mono Int16 (`sampleRateConverterQuality = .max`) into the existing 20 ms `TGOggOpusWriter` path. Write no
  device properties. Optional, behind a setting: `inputNode.setVoiceProcessingEnabled(true)` (macOS 10.15) for system AEC, noise suppression and AGC, with
  `voiceProcessingOtherAudioDuckingConfiguration` (macOS 14) so music is not ducked. This also enables the user's Mic Mode (Voice Isolation, macOS 12+).
  The smaller variant keeps AUHAL, deletes the nominal-rate write, finishes `CustomAudioConverter` (device rate → 48 kHz), and ports iOS `4c229c73`'s C ring buffer.
  Apply the same to `MicroListenerController`. No chip dependency.
- **Gain**: correctness and quality: right pitch and speed on any mic, no global side effect, proper SRC for 16/24 kHz routes, and no priority inversion on
  the IO thread. CPU stays about the same. Voice processing (opt-in) gives clearly cleaner notes on MacBook mics.
- **Fallback**: none needed; voice processing off by default.
- **UX risk**: low for the converter. Start the engine early so recording-start latency does not grow. Voice processing changes timbre and may switch Bluetooth routes.
- **How to verify**: a unit test feeding synthetic sines at 16, 24, 44.1, 48 and 96 kHz through converter → Opus writer → `OggOpusReader`, checking pitch (vDSP FFT) and
  duration. A harness that records on the default mic and asserts that `kAudioDevicePropertyNominalSampleRate` is unchanged afterwards. Port the iOS `VoiceRecorderInputTests`.
- **Confidence**: high (code paths verified; the 44.1 kHz symptom is inferred).

### H17. The shared display link is a CVDisplayLink (deprecated in the macOS 15 SDK) that wakes on every vsync; drive it from `CADisplayLink` with a frame-rate range (extends M30) — `done (12d814a); real-display rate tests skip while the display sleeps, rerun awake`

- **Evidence**: `packages/TGUIKit/Sources/DisplayLinkAnimator.swift:31-110` (`CVDisplayLinkCreateWithCGDisplay` at `:47`; the callback at `:57-66` takes a lock and
  `gate.tick()` on every vsync; only the main hop is throttled). `:186-215` follows the screen by hand, and `:233-260` creates and destroys the link as links
  come and go. SDK `CVDisplayLink.h:51`: `API_DEPRECATED("use NSView.displayLink(target:selector:), NSWindow.displayLink…, or
  NSScreen.displayLink…", macos(10.4, 15.0))`. `NSView.h:655-662`/`NSScreen.h:141` `displayLink(target:selector:)` is macOS 14. Precedents:
  `GraphUI/.../ChartView.swift:62` and `PerfLab/PerfLabFrameClock.swift:43-46`.
- **Today**: with any link active (one 25 fps GIF tile), the CV thread wakes 120 times a second on ProMotion and takes a lock, and the system never learns the cadence the app needs.
- **Use instead**: `SharedDisplayLinkDriver` on a `CADisplayLink` from `NSScreen`/`NSWindow.displayLink(target:selector:)` (the key window's screen), in `.common`
  mode, with `preferredFrameRateRange` set to the highest rate any active link asks for (`.max` = `screen.maximumFramesPerSecond`). Use `isPaused` instead of
  recreating it, keep the gate and accumulators only for slower links, and use `targetTimestamp - timestamp` as the frame duration. Then M30 moves the Lottie
  `RenderFpsLoop`s onto it. macOS 14+; TGUIKit declares `.macOS(.v10_13)`, so add `#available` or raise the platform.
- **Gain**: with only 30 fps content on ProMotion, about 120 → 30 callbacks/s, no CV thread and no DispatchSource hop, and the panel can run at an adaptive rate.
  Smaller gains at 60 Hz. It also removes a deprecated API.
- **Fallback**: none at the macOS 15 floor.
- **UX risk**: low to medium. Callbacks land on the main run loop, so a busy main thread drops ticks (as today's hop does). Test moving between displays with different rates.
- **How to verify**: extend `TGUIKitTests/DisplayLinkRateTests` (`.fps(30)`, `.fps(60)` and `.max` links for 2 s, counting callbacks and main deliveries plus
  `TASK_POWER_INFO` wake-ups, old vs new). The existing rate tests must still pass.
- **Confidence**: medium.

### H18. Translation falls back to scraping Google's private `gtx` endpoint with a spoofed User-Agent; use Apple's on-device Translation framework through the existing TelegramCore hook — `partial (d0a7c3e): macOS 26+ on-device path, gtx deleted; macOS 15-25 hidden-view path and the download-consent sheet not done (server fallback)`

- **Evidence**: `packages/Translate/Sources/Translate/Translate.swift:277-282,334` (random fake browser User-Agents) and `:321-365`
  (`translate.googleapis.com/translate_a/single?client=gtx`, the URL split into pieces, sent over `URLSession.shared`).
  `packages/TranslateUI/Sources/TranslateUI/TranslateModalController.swift:977-1005`: server first, `.tryAlternative` → Google, `.alternative` →
  Google directly, `.system` skipped. `:1012` adds a 2 s delay per block. `packages/ChatHistoryModel/.../ChatLiveTranslateContext.swift:630` passes
  `enableLocalIfPossible: false, fromLang: nil`. TelegramCore `Translate.swift:228-232,348-364` already has `ExperimentalInternalTranslationService` and
  `engineExperimentalInternalTranslationService`, unused on the Mac. The iOS 18 implementation is `Telegram-iOS/submodules/TranslateUI/Sources/Translate.swift:258-352`.
  SDK: `TranslationSession(installedSource:target:)` is `@available(macOS 26.0)`.
- **Today**: when server translation is unavailable or configured as "alternative", the message text and the user's IP go to an unofficial Google endpoint,
  bypassing the app's MTProto or SOCKS proxy. Formatting is lost, the endpoint can break or block, and there is a 2 s wait per block. Live chat translation never tries local.
- **Use instead**: a Mac `ExperimentalInternalTranslationService`, set at startup. On macOS 26+, `TranslationSession(installedSource:target:)` with a batched
  `translations(from:)`. On macOS 15-25, the iOS approach: a hidden `NSHostingView` with `.translationTask(configuration)`. Check pairs with
  `LanguageAvailability().status(from:to:)` and call `prepareTranslation()` for download consent. Pass `enableLocalIfPossible: true` with `fromLang` from
  `NLLanguageRecognizer` (already in `Translate.detectLanguage`), route the modal's fallback through the service, and delete the `gtx` code.
  Models run on the Neural Engine, on every M-series chip.
- **Gain**: privacy (nothing goes to Google, and it works with a proxy-only or offline network), lower latency (no HTTP round trip, no 2 s delays), and no endpoint fragility.
- **Fallback**: server translation (Premium) for unsupported or uninstalled pairs, otherwise hide the action. Google only behind an off-by-default debug switch, if kept at all.
- **UX risk**: a system download sheet on the first use of each pair. Fewer languages, so filter `supportedTranslationLanguages`. Plain text only
  (entities lost, same as iOS). No tone option.
- **How to verify**: a unit test with a fake service that asserts `ChatLiveTranslateContext` and `translateBlocks` use it and never call `translateText`.
  A SwiftPM test on macOS 26 translating en→de with installed models. `strings` on the binary shows no `translate_a`, and `nettop` shows no googleapis.com connection.
- **Confidence**: high.

### H19. Voice messages are transcribed only by the Premium/trial server; add on-device transcription with the composer's SpeechAnalyzer engine — `partial (0f80540): engine + action done; results are not labelled local-only and the switch has no UI yet (UserDefaults nanogram.localVoiceTranscription)`

- **Evidence**: `packages/ChatUI/Sources/ChatUI/ChatController.swift:7221-7290` (Premium and trial checks, then only
  `engine.messages.transcribeAudio` at `:7273`). `ChatInputDictationEngine.swift:405-433,614-680` already runs SpeechAnalyzer/SpeechTranscriber with
  `AssetInventory` on macOS 26 and `SFSpeechRecognizer` below that. `OggOpusReader` (OpusBinding, already a ChatUI dependency) decodes `.ogg` to PCM.
  TelegramCore `TelegramEngineMessages.swift:811` has `storeLocallyTranscribedAudio`, and `Telegram-Mac/Info.plist:86` already has
  `NSSpeechRecognitionUsageDescription`. iOS reference: `LocalAudioTranscription.swift` and the `ChatMessageInteractiveFileNode.swift:422-467` debug switch.
- **Today**: every transcription is a server request. Non-Premium users hit the weekly cap and the cooldown modal, and nothing works offline.
- **Use instead**: a Mac `LocalAudioTranscription`. Decode the cached `.ogg` with `OggOpusReader` (48 kHz mono Int16) into an `AVAudioPCMBuffer`; no AAC
  transcode is needed, unlike iOS. On macOS 26, feed `SpeechAnalyzer` + `SpeechTranscriber` through the dictation code's converter and `AssetInventory` install. On 15-25,
  use `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true`, `addsPunctuation = true` and `.dictation`. Store the result with
  `storeLocallyTranscribedAudio` so `ChatVoiceContentView` renders it unchanged. Gate it behind a setting, use it first for non-Premium users, and try the app and system locales.
  Do not copy iOS's unconditional `supportsOnDeviceRecognition = true`. Runs on the Neural Engine of every M-series chip.
- **Gain**: unlimited, offline, private transcription. Apple describes SpeechAnalyzer as faster than real time on Apple Silicon (not measured here).
- **Fallback**: server transcription when the locale or assets are missing (start the install in the background) or Speech permission is denied.
- **UX risk**: a Speech Recognition prompt on first use, wrong language guesses in multilingual chats, and results that are local only and not synced (label them).
- **How to verify**: a SwiftPM test with a bundled `.ogg` (decode, SFSpeech path, SpeechAnalyzer on 26): non-empty text and timing. Add a unit test that the
  action calls the local engine when the switch is on.
- **Confidence**: high.

### H20. Media playback audio is forced to 44.1 kHz 16-bit stereo through an AUGraph with an always-on time-pitch unit; render at the source rate with AVSampleBufferAudioRenderer — `partial: measured, no code change — see ledger`

- **Evidence**: `MediaPlayer/Sources/FFMpegAudioFrameDecoder.swift:17,21` (default 44100 Hz, 2 channels, S16 via swresample), used by
  `FFMpegMediaFrameSourceContext.swift:549`. In `packages/TelegramMedia/Sources/MediaPlayerAudioRenderer.swift:397-468`, AUGraph runs AUConverter →
  `AUiPodTimeOther` → HALOutput, with a zeroed `AudioStreamBasicDescription` "set" on the converter output and time-pitch input. `:697-707` fixes the input at 44.1 kHz S16
  stereo, and `:101,106,108,623` hard-code the 44100 timescale. `:726-836` is hand-written device and clock handling. `ChunkMediaPlayerV2.swift:205-207,420` already uses
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`. SDK: AUGraph is marked "deprecated in favor of AVAudioEngine" (to be deprecated).
- **Today**: voice notes (Opus, 48 kHz mono), music and round-video audio go 48 → 44.1 kHz in software with a mono→stereo upmix and S16 requantization, through
  a time-pitch unit even at 1.0×, and then HAL resamples back to 48 kHz for the speakers or AirPods.
- **Use instead**: `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` (macOS 10.13), as ChunkMediaPlayerV2 does. Enqueue PCM sample buffers at the
  stream's own rate and layout, use `setRate` for speed, and `audioTimePitchAlgorithm` `.timeDomain` for voice and `.spectral` for music. The system converts once and
  follows the default device. The minimal variant passes the source rate and channels to the decoder, parametrizes 44100, sets real formats on the units, and
  sets `kAudioUnitProperty_BypassEffect` on the time-pitch unit at 1.0×.
- **Gain**: one SRC instead of two, no upmix or requantization, no 1.0× stretch, and about 110 lines of device and clock code removed. CPU during playback is small
  (estimate: low single-digit % of an E-core). Better fidelity, and less energy over long music or podcast sessions.
- **Fallback**: keep the AUGraph path behind a debug switch during migration.
- **UX risk**: medium. A/V sync and progress depend on the 44100 anchoring, 1.5×/2× voice speed must sound the same, the 3 s paused-graph stop needs an equivalent,
  and the speaker and playAndRecord flags need a mapping.
- **How to verify**: a unit test that the decoder at source rate yields the same samples per media second. A harness playing bundled Opus and AAC fixtures old vs new,
  with `sysmon.py`/`powermetrics` for app and `coreaudiod` CPU. A DecodeBench micro-benchmark of swresample 48→44.1 stereo vs passthrough.
- **Confidence**: medium (whether `AUiPodTimeOther` self-bypasses at 1.0 was not checked).

### H21. The round-video recorder composites through deprecated OpenGL with a CPU texture upload per frame; use Metal and `CVMetalTextureCache` — `todo — not started in the runtime run, see ledger ruling`

- **Evidence**: `packages/TGVideoCameraMovie/Sources/TGVideoCameraGLRenderer.m:85-113` (a CGL context with 4× MSAA). At `:355-364` it locks the camera
  `CVPixelBuffer`, `glTexImage2D` copies it, and `glGenerateMipmap` runs every frame. `:331`: `CVOpenGLTextureCache` is used only for the destination.
  `packages/MediaRecorderUI/Sources/MediaRecorderUI/VideoRecorderPipeline.swift:122,214` delivers 500×500 32BGRA IOSurface buffers. Encode is already
  hardware (`TGVideoCameraMovieRecorder.m:60-89`, AVAssetWriter H.264).
- **Today**: at 30 fps, about 1 MB/frame (about 30 MB/s) of CPU copies into GL, mipmaps that are not needed, and Apple's GL-over-Metal translation, all while recording.
- **Use instead**: a Metal compositor. `CVMetalTextureCacheCreateTextureFromImage` wraps the camera IOSurface and the pool destination with no copy, and the
  circle-crop, mirror, rotation and decoration shader is ported to MSL with plain linear sampling (the input is already 500×500). Alternatively, Core Image with
  `CIContext(mtlDevice:)` rendering into the pool buffer. Keep H.264 (HEVC would hurt other clients). Metal and CVMetalTextureCache are available on every M-series Mac (macOS 10.11+).
- **Gain**: removes about 30 MB/s of CPU copies and GL driver overhead during recording, with less risk of dropped frames, and gets off OpenGL. Recording-only, so moderate overall.
- **Fallback**: keep the GL class until pixel parity is shown.
- **UX risk**: medium. The mask edge, mirroring and decoration animation must match exactly. Keep BGRA untagged, as today, and check iOS `58bda613` (BT.709 tagging) while there.
- **How to verify**: an offscreen test feeding synthetic 500×500 BGRA IOSurface buffers (gradients, skin tone, decoration on and off) through both renderers,
  comparing with `compare_rgba.py` and measuring CPU per frame. Optionally encode with `TGVideoCameraMovieRecorder` and read back with AVAssetReader. No camera needed.
- **Confidence**: medium.

### H22. Software-decoded video (VP9, AV1 on M1/M2, any fallback) reaches AVSampleBufferDisplayLayer untagged and always video-range, and 10-bit frames are dropped — `done (9ad344d)`

- **Evidence**: `MediaPlayer/Sources/FFMpegMediaVideoFrameDecoder.swift:532-541`: always `420YpCbCr8BiPlanarVideoRange` or `…8A_TriPlanar`, whatever
  `colorRange` is. There is no `CVBufferSetAttachment`/`kCVImageBufferYCbCrMatrix` anywhere in `MediaPlayer/Sources`, while the hardware path at `:472-480`
  keeps VT's attachments. `FFMpegBinding/Sources/FFMpegAVFrame.m:110-130` maps only 8-bit yuv420p/422p/444p, so yuv420p10 is `Unsupported`
  and is rejected by `isPlanarYUV420Safe` (`:249-256`). `MediaDataReader.swift:92-98` sends VP8/VP9, and AV1 when the hardware probe is false (M1/M2), down this path.
- **Today**: the same AV1 stream gets tagged VT buffers on M3+ and untagged 420v on M1/M2, so colours differ between Macs. JPEG-range sources show crushed blacks and
  clipped whites. 10-bit (VP9 Profile 2, 10-bit AV1) software streams show no picture at all.
- **Use instead**: expose `color_primaries`/`color_trc`/`colorspace` from `FFMpegAVFrame`. Set `kCVImageBufferColorPrimariesKey`,
  `TransferFunctionKey` (including PQ/HLG) and `YCbCrMatrixKey` with `CVBufferSetAttachments(…, .shouldPropagate)` before
  `CMVideoFormatDescriptionCreateForImageBuffer`. Use `…8BiPlanarFullRange` for full-range frames. Add a 10-bit path into
  `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (x420/P010) so the layer tone-maps, or shows EDR on XDR panels. All of these APIs exist on macOS 10.13 and earlier.
  This matters most on M1/M2, which decode AV1 in software.
- **Gain**: correctness: the same colours as the hardware path, correct full-range levels, and 10-bit/HDR files that play at all. CPU about the same (one small interleave for P010).
- **Fallback**: downconvert a 10-bit frame to tagged 8-bit 420v rather than dropping it.
- **UX risk**: low to medium. Tagged output may look slightly different from today's untagged output on P3. Keep M27's deliberate untagged GIF display consistent.
- **How to verify**: a SwiftPM MediaPlayer test with hardware off on small local clips (yuvj420p H.264, VP9 Profile 2, AV1 10-bit): non-nil frames, the expected pixel
  format and attachments. In DecodeBench, render one frame through software and through VT and compare with `compare_rgba.py`.
- **Confidence**: medium.

### H23. Photo Live Text is a custom Vision stack that runs on every gallery photo and rewrites one shared Postbox blob per photo; use VisionKit — `partial (9d62367): custom UI kept (one Vision pass, per-photo file cache, 1 s dwell, shared CIContext); VisionKit overlay not adopted`

- **Evidence**: `packages/GalleryUI/Sources/GalleryUI/GalleryRecognition.swift:46-75` (every photo at magnify 1 and visible starts `TextRecognizing.recognize`).
  `packages/TextRecognizing/Sources/TextRecognizing/TextRecognizing.swift:202-262` (accurate OCR, then a second `perform` for barcodes, and `NLLanguageRecognizer` per line)
  and `:284-316` (one preferences entry holding up to 100 photos' results; each new photo decodes, edits and rewrites the whole entry).
  The custom UI is `ImageTextSelector.swift` (523 lines), `BarcodeOverlay.swift` (246) and `DrawRects.swift` (119). `SubjectLifting.swift:55-66` creates a new `CIContext` per lift.
  SDK: `ImageAnalyzer` and `ImageAnalysisOverlayView` (AppKit) are macOS 13.
- **Today**: flicking through an album runs two Vision passes per photo plus a Postbox transaction that re-encodes up to 100 results and fires preference views.
- **Use instead**: `ImageAnalyzer().analyze(cgImage, orientation:, configuration: .init([.text, .machineReadableCode, .visualLookUp]))` with an
  `ImageAnalysisOverlayView` over the gallery image (`preferredInteractionTypes`, `contentsRect` driven by zoom and pan). This gives native selection, data detectors,
  Copy/Translate/Look Up, QR and subject lift (macOS 14). Add Telegram items through the overlay's menu delegate, and keep the `isCopyProtected` gate
  (`GalleryRecognition.swift:43`). If the custom UI stays: one `perform([barcode, text])`, start after hover or a ~1 s dwell, store per media rather than in one blob,
  and reuse one `CIContext`. Runs on the Neural Engine of every M-series chip.
- **Gain**: one analysis instead of two, no Postbox blob rewrite per viewed photo, system-consistent Live Text, and about 900 lines removed. With lazy start, less energy per photo.
- **Fallback**: none needed.
- **UX risk**: highlight styling becomes the system's. `tg://` and t.me barcode actions need the menu hook. The overlay must track the gallery zoom.
- **How to verify**: ImageAnalyzer variants of `RecognitionSnapshotTests`, `BarcodeRecognitionTests` and `SubjectLiftingTests` on the same fixtures, plus a
  Postbox-transaction count per viewed photo (PostboxCacheLab pattern).
- **Confidence**: medium.

### H24. Notifications use an avatar attachment and a single app stack; post communication notifications (`INSendMessageIntent`) with per-chat threads (iOS `397ac282`) — `partial (0eb0950): code done; needs the Communication Notifications capability + entitlement (owner step); the < 10.14 NSUserNotificationCenter path is kept while the shipped deployment target is 10.13`

- **Evidence**: `Telegram-Mac/utils/UNUserNotifications.swift:285-330` (no `threadIdentifier`, `interruptionLevel` or intent) and `:388-405` (each avatar is written as
  `tiffRepresentation(using: .jpeg, factor: 1)`, TIFF data in a `.jpeg` file, into a new `globallyUniqueString` temp folder per notification that is never removed).
  `SharedNotificationManager.swift:537-548,760` (50×50 avatar, dropped when locked or `hideSender`). Neither the upstream nor the fork entitlements
  (`nanogram/entitlements/*.entitlements` in the fork) have `com.apple.developer.usernotifications.communication`, and there are no `NSUserActivityTypes`.
  `:36-43,150-210`: the NSUserNotificationCenter fallback for macOS < 10.14 is still compiled. SDK: `INSendMessageIntent` and `content.updating(from:)` are macOS 12.
- **Today**: banners show the Telegram icon with a small avatar thumbnail, all chats group as one stack, Focus "Allowed People" cannot let a Telegram contact
  through, and an empty temp folder is left per notification.
- **Use instead**: an `INPerson` (handle and `customIdentifier` `tg<peerId>`, `INImage(imageData:)` avatar PNG) and an
  `INSendMessageIntent(recipients:, outgoingMessageType: .outgoingMessageText, content:, speakableGroupName:, conversationIdentifier: "tg<peerId>", serviceName: nil,
  sender:, attachments: nil)`. Donate an incoming `INInteraction`, then `content = try content.updating(from: intent)`. Set `threadIdentifier` (peer plus topic) and
  `interruptionLevel = .passive` for muted-but-shown chats. Add the entitlement and `NSUserActivityTypes`. Skip the intent when the sender is hidden. Encode
  the avatar once to PNG in one reused cache directory, and delete the < 10.14 path.
- **Gain**: Messages-style sender avatars, per-chat grouping, Focus breakthrough, and no temp-dir litter or TIFF encode per banner.
- **Fallback**: plain content (today) when `updating(from:)` throws or the entitlement is missing.
- **UX risk**: needs the Communication Notifications capability on the Mac App ID (developer portal, as done for iOS). Donations feed Siri suggestions, so delete them on logout.
- **How to verify**: `codesign -d --entitlements -` shows the key. A Debug-only menu item on the login screen posts a fake message through the same `add()` path, and
  `log stream --predicate 'subsystem == "com.apple.UserNotifications"'` shows the result.
- **Confidence**: medium (whether macOS renders the avatar for this app needs a run).

### H25. GIF tiles each own an AVSampleBufferDisplayLayer fed a new CMSampleBuffer per frame plus two queue hops; try IOSurface `layer.contents` — `partial (b0fbff2): the unused layer pool now reuses tile layers; the IOSurface contents path is unmeasured (onscreen harness, display asleep)` (measure first, after M27 and H5)

- **Evidence**: `packages/TelegramMedia/Sources/SampleBufferPool.swift:36-53`: the `pool` is never read, and `takeSampleBufferLayer()` always creates a new
  `SampleBufferLayerImpl`. `SoftwareVideoLayerFrameManager.swift:100-130`: each tick hops to `applyQueue`, calls `enqueue(frame.sampleBuffer)`, then
  `DispatchQueue.main.async { onRender }`. `GifPlayerBufferView.swift:131-140` runs a 25 fps animator per tile.
- **Today**: 10-20 video queues with the GIF panel open, each frame costing a format description, a sample buffer, an enqueue and two hops (on top of M27).
- **Use instead**: for muted loops, set `layer.contents` to the decoded frame's IOSurface (`CVPixelBufferGetIOSurface`) inside an actions-disabled `CATransaction`.
  Retain the previous 1-2 buffers (or check `IOSurfaceIsInUse`) before the VT pool reuses them, tag the colour once per pooled surface, and use `contentsGravity`.
  Keep AVSampleBufferDisplayLayer for real video with audio. At minimum, fix the unused pool so tiles reuse layers.
- **Gain**: unknown. There would be no per-frame sample-buffer objects or per-tile video queue, and one hop instead of two. Measure before committing.
- **Fallback**: the AVSampleBufferDisplayLayer path behind a flag for software or unusual formats.
- **UX risk**: medium. A wrong buffer lifetime gives torn or stale frames, and colour matching changes if tags differ.
- **How to verify**: an onscreen PowerLabs-style harness with 16 layers playing a bundled H.264 GIF mp4 at 25 fps (enqueue vs IOSurface contents), with `sysmon.py` app
  CPU, wake-ups and wsCores, and window captures compared with `compare_rgba.py`.
- **Confidence**: low.

### H26. Picture-in-picture is a custom floating panel plus an off-screen helper window; use system PiP with an AVSampleBufferDisplayLayer content source — `todo — product decision, not started in the runtime run, see ledger ruling` (product decision)

- **Evidence**: `packages/GalleryUI/Sources/GalleryUI/PIPVideoWindow.swift:96-170` (a `.nonactivatingPanel` with `.canJoinAllSpaces/.fullScreenAuxiliary`, a second
  `Window` parked at (3000,3000) at `:109-110`, hand-written snapping and an event monitor). No `AVPictureInPictureController` anywhere. Playback is already
  AVSampleBufferDisplayLayer (`TelegramMedia/MediaPlayerView.swift:19,65`). SDK: `initWithContentSource:` is macOS 12.
- **Today**: two extra app windows, with Spaces, full screen and snapping handled by hand.
- **Use instead**: `AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer:playbackDelegate:))` with an
  `AVPictureInPictureSampleBufferPlaybackDelegate` mapped to the player's play, pause, seek and time range. Works on all chips.
- **Gain**: native integration (system controls, Spaces, Stage Manager, snapping) and less window code. Energy about the same.
- **Fallback**: keep `PIPVideoWindow` for the WebView/HLS-JS player.
- **UX risk**: medium. Telegram-specific PiP controls ("look at message") are lost.
- **How to verify**: in the VideoPlayerLab/MediaPlaybackLab host with a local file, check `isPictureInPicturePossible`, start and stop, and confirm that delegate play, pause and seek reach the player.
- **Confidence**: medium.

### H27. No App Intents, Shortcuts or Focus filter — `done (02d4e35)` (integration, no efficiency gain)

- **Evidence**: no `AppIntents`, `AppShortcutsProvider`, `SetFocusFilterIntent` or INIntent handling in `Telegram-Mac/` or `packages/`, and no `NSUserActivityTypes`.
  The only system entry point is the CoreSpotlight continuation (`AppDelegate.swift:1756-1766`).
- **Use instead**: a `ChatEntity: AppEntity` with an `EntityQuery` over recent peers and search, `OpenChatIntent` (`openAppWhenRun`), `SendMessageIntent` (with
  `requestConfirmation`), an `AppShortcutsProvider`, and a `SetFocusFilterIntent` filtering notifications by folder or account in SharedNotificationManager. Mark
  `ChatEntity` as `IndexedEntity` (macOS 15) to replace `Spotlight.swift` later. App Intents need macOS 13, and Spotlight actions macOS 26.
- **Gain**: Shortcuts, Siri, Spotlight actions and Focus integration.
- **Fallback**: none. **UX risk**: confirmation before sending, multi-account handling, and no entities while the passcode lock is on.
- **How to verify**: the build produces `Contents/Resources/Metadata.appintents`, and the Shortcuts app lists the actions without login. Unit-test the `EntityQuery` with a fake engine.
- **Confidence**: low (scope and product choices open).

### Large (L)

### H28. Screen sharing uses the legacy CGDisplayStream/CGWindowListCreateImage capture (obsoleted at a macOS 15 deployment target) and scales and converts every full-resolution frame on the CPU; move to ScreenCaptureKit — `partial (9efe49a): SCStream capturer done; picker/thumbnails still legacy`

- **Evidence**: `submodules/tgcalls/tgcalls/desktop_capturer/DesktopCaptureSourceManager.cpp:42-50` (webrtc `DesktopCapturer`).
  `submodules/tg_owt/src/modules/desktop_capture/mac/screen_capturer_mac.mm:440-494` (`CGDisplayStreamCreate`, full pixel size, BGRA).
  `window_capturer_mac.mm:153-196` with `mac/desktop_frame_cgimage.mm:22-45` (a synchronous `CGWindowListCreateImage` per frame).
  `tgcalls/desktop_capturer/DesktopCaptureSourceHelper.cpp:157-200` (`libyuv::ARGBScale` + ARGB→I420 on the CPU per frame) and `:256-257,315-337`
  (a timer every 1000/fps ms). `CallsUI/DesktopCapturerWindow.swift:223` (24 fps) and `DesktopCapturePreviewItem.swift:18` (a live capturer per picker thumbnail).
  SDK `CGWindow.h:223-224,274,283` and `CGDisplayStream.h:245`: `SCREEN_CAPTURE_OBSOLETE(…,14.0,15.0)`, i.e. `obsoleted=15.0, "Please use ScreenCaptureKit instead."`.
  `packages/CallsUI/Sources/CallsUI/ScreenCaptureLab.swift:71-140,196-202` already prototypes an SCStream pipeline (DEBUG), and tgcalls links ScreenCaptureKit.
- **Today**: each shared frame is a full-resolution BGRA surface or a synchronous window snapshot, read back, scaled and converted to I420 on the CPU.
  Window capture runs on a timer even when nothing changes, and the picker runs one capturer per source. macOS 15+ shows the recurring
  "continue to allow" prompt for legacy capture, which needs a Screen Recording grant (the fork ships sandboxed MAS entitlements).
- **Use instead**: an SCStream capturer in `tgcalls/platform/darwin`, modelled on `VideoCameraCapturerMac`, pushing `CVPixelBuffer`s into `DarwinVideoTrackSource`.
  Configure `SCStreamConfiguration` with width and height at the encode size (GPU scaling), `pixelFormat '420v'`, `minimumFrameInterval 1/24`, `queueDepth` 3-5
  and `showsCursor`. Drop `SCFrameStatus.idle` frames, and exclude Telegram's own windows in `SCContentFilter`. Use `SCContentSharingPicker` (macOS 14) as the picker, which needs no
  Screen Recording permission and avoids the Sequoia re-prompt. Use `SCScreenshotManager.captureImage` for thumbnails. Optionally share system audio with
  `capturesAudio` and `excludesCurrentProcessAudio` (macOS 13). The alternative is a tg_owt update to a libwebrtc with `screen_capturer_sck.mm`. SCStream needs macOS 12.3;
  scaling and conversion run on the GPU, and the VT encoders on the media engine of every M-series chip.
  Related, not verified: `tgcalls/platform/darwin/DarwinInterface.mm:101-106` reports H.264 encoding as supported only on x86_64 (H.265 only on arm64), so on Apple
  Silicon 1:1 calls go H.265 → software VP8/VP9 when the peer lacks H.265. Find the reason before changing it.
- **Gain**: estimated. No per-frame CPU readback of the full display (a 5K panel is about 59 MB per BGRA frame, about 1.4 GB/s at 24 fps), no CPU scale or I420,
  and no frames for an unchanged screen. Expect tens of percent of a core less during screen share (measure with ScreenCaptureLab). It also removes
  APIs that will not compile once tg_owt targets macOS 15, and the recurring privacy prompt.
- **Fallback**: none needed at macOS 15. Keep the legacy capturer behind a switch until SCK is verified.
- **UX risk**: the system picker replaces Telegram's own list, minimized windows behave differently, and the user can stop the stream from the menu bar
  (handle `didStopWithError`). Check HiDPI and cursor rendering.
- **How to verify**: `-PerfLab screen-capture -PerfLabScenarios legacy,sck`. Move the lab's start before login (`AppDelegate.swift:1127-1136`); it does not use the
  account. Compare process CPU, footprint and WindowServer/GPU numbers with `run.sh`. Feed SCK sample buffers into the track source in a tgcalls unit test.
- **Confidence**: high (the deprecation and the CPU path are verified; the magnitude needs ScreenCaptureLab).

### Already native (keep)

Only items not already listed in "Already done well (keep)" above:

- **Video encode is hardware everywhere**: round videos, avatars, the editor, sticker export and GIF→MP4 use AVAssetWriter or AVAssetExportSession (VideoToolbox), and trims use
  `AVAssetExportPresetPassthrough`. Call video uses VideoToolbox H.264/H.265 and Metal renderers. The Mac call UI is MetalEngine with zero-copy
  `CVMetalTextureCache` NV12/BGRA textures and a GPU blur (`CallVideoLayer/MetalVideoRenderView.swift:130-320`).
- **AudioToolbox inside FFmpeg** for AAC decode/encode, ALAC and GSM (`aac_at`, `alac_at`, `gsm_ms_at`). Opus stays on libopus, because AudioToolbox Opus is also software (M19).
- **Photo send** decodes with `CGImageSourceCreateThumbnailAtIndex` at the upload size (`SenderController.swift:376-392`). JPEG decode goes through ImageIO.
- **EDR done right** in `InteractiveDiamondLayer` (`contentsHeadroom`/`preferredDynamicRange` on macOS 26, the `wantsExtendedDynamicRangeContent` fallback, rgba16Float,
  gated on `maximumPotentialExtendedDynamicRangeColorComponentValue`). This is the pattern for H22's EDR work. MetalEngine composites into shared IOSurface atlases.
- **Liquid Glass** via `NSGlassEffectView` behind `#available(macOS 26)` with an `NSVisualEffectView` fallback, and the navbar progressive blur on a render-server
  `CABackdropLayer`. These and `LiquidGlassLens`/`ObjcUtils.m:1708-1760` use private CA/NSGlass internals, so re-check them on every SDK beta.
- **CPU pre-matching of drawn images to the screen colour space** (`DrawingContext.swift:89-155`) is deliberate (upstream measured CA's in-process matching at
  1.55 ms/frame). The IOSurface route is M32.
- **Vision** (`VNRecognizeTextRequest` rev 3, barcodes, `VNGenerateForegroundInstanceMaskRequest`), **NaturalLanguage** language detection, **Speech**
  dictation (SpeechAnalyzer on 26), the **UNUserNotificationCenter** reply action, **Core Location** `requestLocation` at 3 km accuracy, **AUVoiceIO** muted-speech detection (`DetectSpeech.m`).
- **Network.framework** for the Rust engine's TLS/WebSocket carriers (`RustStreamHost.swift`) and `NWPathMonitor` in Reachability. Plain MTProto TCP stays on mio
  sockets on purpose.
- **Hardware crypto and hashing**: CommonCrypto SHA/MD5/AES (corecrypto, ARMv8 AES/SHA); SQLCipher with `SQLCIPHER_CRYPTO_CC`; OpenSSL 1.1.1s built with ARMv8 asm
  (`aes_v8_encrypt`, `sha256_block_data_order`), used only for RSA/bignum.
- **SIMD builds**: libwebp `-O3` with NEON, FFmpeg 8.1.2 `-O3` with NEON+DotProd and runtime cpudetect, tg_owt Release with NEON, Rust crates on
  `aarch64-apple-darwin` (apple-m1 baseline), and the fork's `Nanogram.xcconfig` (O3, thin LTO, arm64-only Release; fork `67ec00a6` removed the x86_64 slices). Accelerate/vImage
  already does YUV→ARGB, premultiply, scaling and colour matrices in 15 files, and Metal buffers use `storageModeShared`.
- **libwebp 1.3.2** includes the CVE-2023-4863 fix. **Compression.framework** LZFSE (M29 for the codec choice). The GCD queue QoS outside ThreadPool is sensible (H13 covers ThreadPool).

### Dropped after checking (H)

- **"NSThread priority 1.0 maps to pthread priority 47 (the main-thread band)"** (CPU finding behind H13): corrected by the probe. It is 62, above the
  user-interactive band, which makes the finding stronger. H13 states the measured values.
- **"Unknown whether M-series reports a VP9 hardware decoder"** (graphics, Not checked): resolved. The probe is true on M4, so H14 is kept at medium-to-high confidence.
- **A hand-written ARMv8 AES intrinsics IGE decrypt** (part of the CPU AES finding, merged into H2): dropped. IGE is serial by construction, the volume (secret-chat and
  encrypted file parts) is small, and hand-rolled crypto is a correctness and side-channel risk for little gain. CommonCrypto per-block IGE stays.
- **"Xcode 27 already warns about OpenGL"** (the media finding behind H21): not checked and removed. GL has been deprecated since 10.14 either way.
- **vDSP for the voice waveform and mic level** (`AudioRecorder.swift:804-842`, about 48k Int16 ops/s, microseconds per second), **GPU for thumbnail blurs** (vImage box
  convolution on ≤ 150 px images, once per image) and **AudioToolbox `kAudioFormatOpus`** (also software): no measurable gain.
- **The ImageIO JPEG encoder instead of mozjpeg**: iOS `0e715cda` measured +16% size at equal SSIM. Keep mozjpeg (libjpeg-turbo 3.2.1 is a maintenance option).
- **MtProto TCP over Network.framework**: protocol-critical, with its own back-off; not recommended. `NSPurgeableData` for image caches: they are already bounded (about 60 MB) and
  cleared on pressure.
- **SF Symbols / `.symbolset` for the 1,285 bundled imagesets**: a large icon-pipeline rewrite with brand risk, and icons render once per theme, so the energy gain is small.
- **HEVC for round videos, or an HEVC re-encode on send**: hurts compatibility with other clients, or is a product decision rather than an efficiency fix.
- **Duplicates merged**: the AES-CTR finding from two domains → H2. VP9 VideoToolbox from three domains → H14 (libvpx 1.17 kept separately as H15, because it also covers calls
  and the fallback). The CVDisplayLink finding is H17, the driver half of M30.

### Not checked (H)

- `VTIsHardwareDecodeSupported(VP9)` and the per-session hardware flag on M1, M2 and M3 (only M4 was probed). Whether AVSampleBufferDisplayLayer shows tagged
  PQ/HLG frames in EDR without opt-in. Whether macOS renders communication-notification avatars for this app (H24).
- Calls audio: tgcalls on macOS wraps WebRTC's AUHAL device module with software AEC3/NS, not VoiceProcessingIO, so Voice Isolation and the system AEC are unavailable
  in calls. Group-call screencast codec choice. The arm64 H.264 encode gate (H28 note). tgcalls/WebRTC thread priorities and `os_workgroup` for audio and render threads.
- Seek-bar scrub previews decode in software (`UniversalSoftwareVideoSource.swift:213`, `preferHardwareAccelerationCapable: false`). The VT hwaccel there depends on M27's
  `get_format` fallback.
- HDR still photos: no `kCGImageSourceDecodeRequest`/gain-map handling (gain-map HEIC/JPEG shows as SDR). Whether iPhone P3 photos are clipped in the DeviceRGB 8-bit
  `DrawingContext` (compare iOS `918a6467`/`7067d311`).
- Rust engine worker thread QoS (`mtproto-engine/src/lib.rs:100-103`). Visible custom-emoji placeholders rendered on `.concurrentBackgroundQueue`
  (`InlineStickerItemLayer.swift:118-120`), which may be too low. OpenH264 version and flags (iOS moved to 2.7.0, `6aeb0603`).
- The custom download folder stored as a path without a security-scoped bookmark (`AutomaticMediaDownloadCategoryPeers.swift:143`); this matters for the sandboxed MAS build
  the fork ships. `TGGifConverter` feeding 32ARGB rather than 32BGRA (`TGGifConverter.m:86,219`). `BlurEdgeView` Core Image `backgroundFilters`. SceneKit premium scenes.
- Translation and SpeechTranscriber language coverage against Telegram's lists (runtime queries).

## Sound and video quality (Q-specs)

A third pass (2026-11-02) looked at what the user hears and sees: voice notes, round videos, calls, sending, and playback, with AirPods and other Bluetooth headsets in focus. It is the macOS counterpart of the iOS fork's audio and video quality work.
The lead re-read every cited line. Availability was checked against the MacOSX27.2 SDK headers. Nothing was built or run, and there is no account, so the gains are expected effects, not measurements.
There is no macOS equivalent of the iOS 26 high-quality AirPods recording opt-in: `AVAudioSessionCategoryOptionBluetoothHighQualityRecording` (`AVAudioSessionTypes.h:635`) and `AVCaptureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording` (`AVCaptureSession.h:569`) are both `API_UNAVAILABLE(macos)`.
The Mac equivalent is to keep the AirPods' microphone closed (Q9).
The conventions are the same as for the H-specs: paths are relative to `src/`, `iOS <hash>` is a Telegram-iOS fork commit, and the macOS 15 floor makes every API below unconditional unless a spec says otherwise.

### Quick (S)

### Q1. Streamed, chunked and inline videos play their soundtrack in mono; decode to stereo (upstream 13.1.2) — `done (2955fe5 core)`

- **Evidence**: `submodules/telegram-ios/submodules/MediaPlayer/Sources/FFMpegFileReader.swift:381` builds every playback audio decoder with
  `FFMpegAudioFrameDecoder(codecContext:, sampleRate: 48000, channelCount: 1)`. `FFMpegAudioFrameDecoder.swift:21` resamples down to that channel count,
  `:37` always uses `kAudioChannelLayoutTag_Mono`, and `:154` computes `sampleCount: data.count / 2` (correct only for mono S16).
  `MediaDataReader.swift:114` opens audio only through FFMpegFileReader, and ChunkMediaPlayerV2 (`packages/TelegramMedia/Sources/ChunkMediaPlayerV2.swift:131-140,420-424`) plays it.
  The callers are every HLS video (`HLSVideoJSNativeContentView.swift:1220`), gallery videos with an AV1 or unknown codec (`GalleryUI/ChunkedNativeMediaPlayer.swift:35`),
  and inline chat videos (`ChatUI/ChatInteractiveContentView.swift:52`). The iOS fork already has the fix, from the upstream 13.1.2 import `0650eac5`
  (`FFMpegAudioFrameDecoder.playbackChannelCount`, `FFMpegFileReader.swift:431`).
- **Today**: stereo music clips, concerts and ASMR collapse to the centre on AirPods, headphones and the MacBook speakers, and wide ambience can partly
  cancel out when L and R are summed. The same file still plays in stereo in the old MediaPlayer path, so a video sounds different depending on which player opens it.
- **Fix**: port the upstream change. Add `playbackChannelCount(codecContext:)` (1 for mono sources, otherwise 2), use a Stereo layout and divide by
  `2 * channelCount` in both sample-count computations, and pass it at `FFMpegFileReader.swift:381`. Keep `SoftwareVideoSource.swift:520` mono for voice
  conversion (the iOS `isPlayback` flag). Optional follow-up: set `AVSampleBufferAudioRenderer.allowedAudioSpatializationFormats = .monoAndStereo` (macOS 12+)
  in ChunkMediaPlayerV2, so AirPods can spatialize and head-track video soundtracks. Make it a setting, because some people dislike spatialized stereo. No fallback is needed.
- **Gain**: real stereo for every streamed and inline video, the largest audible playback difference in this pass. Stereo is also what makes spatial audio possible.
- **Risk**: very low. The channel change and the sample-count fix must land together, otherwise timestamps run at half speed and A/V sync breaks.
- **How to verify**: a SwiftPM MediaPlayer test with a 2-channel clip (L = 440 Hz, R = 880 Hz, ffmpeg lavfi, kept in Tests/Resources) read through
  `FFMpegFileReader(selectedStream: .mediaType(.audio))`. Assert `mChannelsPerFrame == 2`, a Stereo layout, `numSamples × 4 == data length`, and FFT peaks of 440/880 Hz per channel.
  A mono Opus file must still give 1 channel. Run the iOS ChunkMediaPlayerV2 audio-timing test against the stereo clip.
- **iOS cross-ref**: `0650eac5` (upstream 13.1.2).
- **Confidence**: high.

### Q2. Pausing and resuming a voice note breaks the Ogg stream (second BOS page, page numbers restart), which clicks at the join and makes trim fail — `done (b23b004 core, 36315cc)`

- **Evidence**: `packages/TelegramMedia/Sources/AudioRecorder.swift:595` (`pause()` stores `oggWriter.pause()`) and `:608-613` (`resume()` calls
  `oggWriter.resume(with:encoderState:)` on the same live writer). In `OpusBinding/Sources/opusenc/opusenc.m:647-655,712-765`, `restoreState` calls `[self cleanup]`, creates a new
  `opus_encoder_create` (`:748`) and calls `ogg_stream_init(&os, serialno)`. `ogg/framing.c:189-209` memsets the stream state, so `pageno = 0` and `b_o_s = 0`,
  and `:454` flags the next page BOS. On the reader side, `framing.c:859-871` marks a hole on a page-number mismatch, `opusfile.c:1950` returns `OP_HOLE`
  (`op_read` passes `_ignore_holes = 0`, `:2743`), and `AudioRecorder.swift:313-316` (`trimOpusFile`) fails on any negative read. The trim path re-inits the same way
  (`AudioRecorder.swift:663-680` → `beginAppend`, `opusenc.m:458-497`). iOS `ManagedAudioRecorder.swift:478` only flushes on pause and keeps the same encoder.
- **Today**: every pause→resume and trim→resume adds a second BOS page and restarts page numbers at 0. The cold encoder drops the ~6.5 ms lookahead tail and
  adds pre-roll, so speech that spans the join gets a tick or a clipped syllable. After any earlier pause, trimming the note silently does nothing.
  Recipients whose player stops on `OP_HOLE` may lose the rest of the note (other clients not checked). FFmpeg does not check sequence numbers, so local playback hides it.
- **Fix**: (1) Mac recorder: match iOS. In `resume()`, do not call `resume(with:)` while the same writer is alive; clear `encoderState`. `pause()` keeps
  flushing pages for the preview. (2) OpusBinding (shared with iOS; fixes the draft-resume and trim-append paths): record the last page's
  `ogg_page_pageno` in `parseExistingOpusFile`. After `ogg_stream_init` in `initializeEncoderForAppend` and `restoreState`, set `os.b_o_s = 1` and
  `os.pageno = last + 1`. Save `pageno` in `saveState` under a new key, and re-parse the data item when the key is missing. Pure C/ObjC, so there is no OS dependency.
- **Gain**: valid single-link Ogg Opus files, seamless joins with no click, and trim that works after pause/resume.
- **Risk**: low. Notes already sent are unaffected. A unit test pins the restored `pageno` for the draft path.
- **How to verify**: an OpusBinding unit test writes 50 frames of a 440 Hz sine, then `pause()`, `resume(with:)`, 50 more frames, and finish. Walk the pages with `ogg_sync_pageout`
  and assert exactly one BOS page and `pageno` strictly +1 (this fails today). `OggOpusReader` reads to EOF with no negative return and exactly 100 × 960 samples. Repeat for `beginAppend`.
  A recorder-context test feeds synthetic buffers through pause → resume → pause → `applyTrim` and asserts it returns true. Optionally, `ogginfo` reports no sequence errors.
- **iOS cross-ref**: `ManagedAudioRecorder.swift:478` (flush-only pause). iOS `63094959` (trim on resume via `beginAppend`) needs the same OpusBinding fix.
- **Confidence**: high (libogg and opusfile behaviour read in the bundled sources).

### Q3. Every video the Mac encodes is written without colour tags, so iPhones and FFmpeg players decode small videos as BT.601 and reds shift — `done (0879d4e)`

- **Evidence**: `packages/TGVideoCameraMovie/Sources/TGVideoCameraMovieRecorder.m:60-90` (`videoSettingsForPreset:` has no `AVVideoColorPropertiesKey`);
  `TGVideoCameraGLRenderer.m:613-630` (BGRA pool without `kCVBufferPropagatedAttachmentsKey`); `ImageCanvasUI/EditVideoExport.swift:605-614` (re-encode writer,
  240p/360p presets at `:87-100`); `AvatarEditorUI/AvatarVideoExport.swift:55-63` (640×640 avatar writer).
- **Today**: round videos (300×300), compressed or edited sends and avatar videos go to VideoToolbox as untagged BGRA. iOS `7d600b48` showed that VT
  converts these with BT.709 but writes no colour tags. Decoders treat untagged video up to 720×576 as BT.601, so recipients see darker, less saturated reds and pinker skin
  (pure red decodes to about 233,0,2).
- **Fix**: add `AVVideoColorPropertiesKey` (primaries, transfer and matrix all `ITU_R_709_2`, macOS 10.7+) to the three writers. Add `kCVBufferPropagatedAttachmentsKey` with the 709
  matrix, primaries and transfer to the GL renderer pool and the avatar adaptor buffers, so the conversion matrix is explicit (as iOS `58bda613`). Leave VP9/WebM stickers untagged.
  No fallback is needed. This revises H21's "keep BGRA untagged": do it with H21 or before it.
- **Gain**: circles, small edited sends and avatar videos show the preview colours on every client. Only metadata changes.
- **Risk**: none for battery or latency. If the harness shows VT converts untagged BGRA with 601 on macOS, tag 601 instead; the test catches either case.
- **How to verify**: port the iOS `RoundVideoColorTests`/`MediaEditorTests` into the three SwiftPM test targets. Write 30 frames of pure red and a skin patch at 300², 480² and 640×360 through
  the real settings, read back as BGRA (±2 levels), and assert that the track's format description carries 709 matrix, primaries and transfer. `ffprobe -show_streams` should report `bt709`.
- **iOS cross-ref**: `58bda613`, `7d600b48`, `9876c249`.
- **Confidence**: high.

### Q4. Paused round videos keep the microphone and camera running, so AirPods stay in HFP and the paused preview plays narrowband; the audio track is fixed at 44.1 kHz — `done (0ee33a3)`

- **Evidence**: `packages/MediaRecorderUI/Sources/MediaRecorderUI/VideoRecorderPipeline.swift:407-417` (`pause()` only finishes the segment writer; `stopRunning` is only in
  `stopCapture`, `:636`). `VideoRecorderModalView.swift:186-202` plays the paused clip through an unmuted `AVPlayer`. `TGVideoCameraMovieRecorder.m:42-57`
  sets `AVSampleRateKey: 44100` whatever the source rate is. For contrast, voice notes tear the audio unit down on pause (`AudioRecorder.swift:586-599`).
- **Today**: pausing a circle on AirPods leaves them in the hands-free profile. The paused preview, and any music, then plays as narrowband mono, so the user judges the clip by
  worse sound than they recorded. The mic and camera indicators stay on. A 48 kHz capture is also resampled to 44.1 kHz AAC and then back to 48 kHz for playback.
- **Fix**: on pause, remove `audioDeviceInput` inside `beginConfiguration`/`commitConfiguration`, or stop the session, since the capture layer is hidden anyway. On resume, re-add it
  and gate `configureRecorderTracks` on the first audio buffer (reuse the `startRecordAfterAudioBuffer` gate, `:325-331,385-387`, after resetting `outputAudioFormatDescription`).
  Set `AVSampleRateKey` to the source rate when it is 44.1 or 48 kHz, otherwise 48000, and keep mono. `AVCaptureAudioDataOutput.audioSettings` (macOS-only, `AVCaptureAudioDataOutput.h:87`)
  can request 48 kHz mono up front. Every API is available on all supported macOS versions. Fallback: if re-adding the input fails, resume with the session restarted.
- **Gain**: AirPods return to stereo AAC while the circle is paused, and the mic and camera turn off. There is one SRC fewer on the circle's audio, which is small on built-in mics.
- **Risk**: AirPods take about 1-2 s to re-enter HFP on resume, so the first fraction of a second may be lost unless resume waits for audio. Segment composition must tolerate audio that starts slightly late.
- **How to verify**: a pipeline test (camera and mic permission only): after `pause()`, `session.inputs` has no audio input (or `isRunning == false`), and after `resume()` the next segment has an
  audio track. `AVAsset` shows the segment's audio ASBD at 48000 Hz, 1 channel. On hardware, Audio MIDI Setup shows the AirPods output back at 48 kHz/2 ch while paused.
- **iOS cross-ref**: CameraNeo `VideoRecorder.swift:774-781` (AAC at the source rate and channel count).
- **Confidence**: medium (pause behaviour verified in code; HFP timing needs hardware).

### Q5. Screen shares are converted to limited-range YUV but every Telegram Apple renderer decodes full range, so blacks are grey; fixes H28's `'420v'` too — `partial: SCStream 420f/601 done by H28 (9efe49a); libyuv J420 switch is an owner decision (cross-client)`

- **Evidence**: `submodules/tgcalls/tgcalls/desktop_capturer/DesktopCaptureSourceHelper.cpp:207-217` (`libyuv::ConvertToI420(..., FOURCC_ARGB)`, BT.601 limited range:
  `tg_owt/.../libyuv/source/row_common.cc:562`, `(66R+129G+25B+0x1080)>>8`). The receivers decode as full-range BT.601 with no 16/219 expansion:
  `packages/CallVideoLayer/Sources/CallScreenShaders.metal:353-356` (`videoYUVToRGB`) and `Resources/shaders/MetalFunctions.metal:56-71` (tgcalls `TGRTCMTLI420Renderer`).
  `TGRTCVideoEncoderH264.mm:69,452-457` copies I420 into a `420f` pool, so H.264 screen shares even signal full range. H28 "Use instead" recommends `pixelFormat '420v'`.
- **Today**: in a shared screen, pure black shows as about 6% grey and pure white as about 92%, so dark-mode UIs, code editors and slides look washed out on Mac and iOS receivers.
- **Fix**: replace the conversion with `libyuv::ARGBToJ420` (full-range BT.601, `convert_from_argb.h:208`), which is what Apple receivers decode. The sender-agnostic alternative
  keeps `ARGBToI420`, tags `webrtc::ColorSpace` as limited, and teaches receivers to expand (Q14). Amend H28: configure SCStream with `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
  `colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_601_4` and `colorSpaceName = sRGB` (macOS 12.3+), not `'420v'`. Otherwise the VP8 group-call path, which has no range
  signalling, inherits the same look. No fallback is needed.
- **Gain**: true blacks and whites in screen shares, about 14% more contrast, and crisper dark-mode text.
- **Risk**: cross-client. Before changing the sender, check the tdesktop and Android YUV shaders (unverified; they may assume limited range); prefer the tagged variant if they disagree.
  The helper code is shared with tdesktop, so land it in the klaipher/tgcalls fork.
- **How to verify**: a unit test feeds BGRA black, white and 75% bars through `SourceFrameCallbackImpl::OnCaptureResult` and asserts that Y is 0 for black and 255 for white (16/235 today).
  An offscreen Metal test renders the result through `videoBiPlanarFragment` and asserts black ≤ 2 and white ≥ 253. For H28, assert the SCStreamConfiguration pixel format and matrix.
- **iOS cross-ref**: the iOS call shaders are the same (TelegramCallsUI `CallScreenShaders.metal`/`I420VideoShaders.metal`); land it once in tgcalls (iOS `e871519b`).
- **Confidence**: medium (sender and receiver maths verified; other clients' conventions unverified).

### Q6. Call video encoders run with `RealTime = false` and without low-latency rate control; use Apple's conferencing configuration with a fallback — `done (tgcalls 9ab1773, c66b2ea)`

- **Evidence**: `submodules/tgcalls/tgcalls/platform/darwin/TGRTCVideoEncoderH264.mm:643-662` (encoder spec only enables hardware) and `:697-717`
  (`RealTime = false`, "TODO: colorspace matrices"). `TGRTCVideoEncoderH265.mm:408-419,455-475` is the same. Upstream WebRTC sets `RealTime = true`
  (`tg_owt/src/sdk/objc/components/video_codec/RTCVideoEncoderH264.mm:677`). SDK `VTCompressionProperties.h:61-65` gives the conferencing recipe, and
  `:1212` makes `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` available from macOS 11.3.
- **Today**: the encoder runs in the mode Apple describes for offline transcoding. Its soft average-bitrate control tends to overshoot when WebRTC's bandwidth estimate drops,
  which can show up as freezes, keyframe bursts and quality pumping after congestion (inferred, not measured).
- **Fix**: add `EnableLowLatencyRateControl = true` to `encoder_specs` when the negotiated profile is High or Constrained High, and retry with today's spec if
  `VTCompressionSessionCreate` fails. On that session set `RealTime = true` and `ExpectedFrameRate = 25`, and leave GOP to PLI (low latency is infinite-GOP). Do the same for HEVC
  and rely on the create-failure fallback. Set `ColorPrimaries`/`TransferFunction`/`YCbCrMatrix` from the first frame's attachments (default 709), so the SPS states the colour.
  Constrained Baseline peers keep the old path.
- **Gain**: tighter bitrate on bad networks (fewer freezes and less pumping) and lower glass-to-glass latency. Apple's own conferencing apps use this mode.
- **Risk**: shared tgcalls code (iOS too). Telegram deliberately chose `RealTime = false`, possibly for per-frame quality on idle networks, so A/B PSNR/SSIM per platform before switching.
- **How to verify**: an offline harness encodes a 60 s 1280×720 25 fps clip with a scripted bitrate schedule (1000 → 300 → 800 kbit/s). Log per-frame bytes and encode latency, and decode for PSNR/SSIM.
  Pass criteria: no 1 s window above 1.1× target after a drop, lower latency, and SSIM within 0.01 of today. Parse the SPS for `profile_idc = 100` and `colour_description_present_flag = 1`.
- **iOS cross-ref**: shared tgcalls; land it in the klaipher/tgcalls fork (iOS `e871519b`).
- **Confidence**: medium (configuration verified; the network-behaviour gain is inferred).

### Q7. Gallery scrub previews and cached sticker previews are BT.709 pixels labelled Display P3; M3+ AV1 is forced to 8-bit (extends H22) — `done (0a053b6 core)`

- **Evidence**: `MediaPlayer/Sources/FFMpegMediaVideoFrameDecoder.swift:16-27` (the macOS `deviceColorSpace` is Display P3), `:414` (YCbCr→RGB with the ITU-R 709 matrix) and `:443`
  (that BT.709-primaries RGB wrapped in a P3-tagged `CGImage`). `render(frame:)` is used by `UniversalSoftwareVideoSource.swift:306` (scrub previews) and
  `SoftwareVideoSource.swift:382` (cached previews). Separately, `MediaDataReader.swift:256` reads AV1 on M3+ through `AVAssetReaderTrackOutput` with `420YpCbCr8BiPlanarVideoRange` fixed.
- **Today**: seek-bar thumbnails and sticker previews look visibly more saturated than the video itself, with reds and greens pushed toward P3. A 10-bit AV1 stream on M3+ is truncated to 8 bits, which bands.
- **Fix**: tag the `CGImage` with `CGColorSpace.sRGB` (or `.itur_709`). In `AVAssetVideoDataReader`, request `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` when the track's
  format description has more than 8 bits per component or an HDR transfer function. Both work at macOS 10.13+, and no fallback is needed. The rest of the software-path colour work is H22.
- **Gain**: thumbnails that match the video, and no banding in 10-bit AV1 on M3+.
- **Risk**: low. 10-bit doubles frame memory for those streams only.
- **How to verify**: a unit test asserts that `render(frame:)` returns an sRGB-tagged image and that a 75% red bar is about (191,0,0) after conversion to sRGB. An AV1 10-bit fixture through
  `AVAssetVideoDataReader` yields an x420 buffer.
- **iOS cross-ref**: iOS has the same P3 tag, so the fix can be shared back.
- **Confidence**: medium.

### Q8. Photo sends are flattened to DeviceRGB with no ICC profile, so Display P3 photos and screenshots lose their wide-gamut colours — `done (dab5e38, f51c974; Debug Settings switch, off)`

- **Evidence**: `submodules/Mozjpeg/Sources/Mozjpeg.m:76-87` draws the source into `CGColorSpaceCreateDeviceRGB()` and writes no ICC marker. Every non-GIF/WebP send goes through it
  (`ChatHistoryModel/SenderController.swift:373-392`, `TelegramMediaUtils/MediaUtils.swift:1850-1858`). `jpeg_write_icc_profile` is in the bundled `jpeglib.h:1030`.
- **Today**: iPhone HEIC photos and screenshots from P3 displays lose their saturated reds, oranges and greens, giving flat sunsets and neon and banding in strong gradients.
  Official iOS gallery sends behave the same way.
- **Fix**: when `CGColorSpaceIsWideGamutRGB` is true for the source, draw into that colour space and write its ICC (`CGColorSpaceCopyICCData`, then `jpeg_write_icc_profile` after
  `jpeg_start_compress`). Otherwise draw into an explicit sRGB space, still without an ICC. Ship it behind a Debug Settings switch, off by default. The APIs are available at macOS 10.12+.
- **Gain**: P3 colours preserved for colour-managed recipients (Telegram Apple clients decode through ImageIO).
- **Risk**: real compatibility risk. Clients that ignore ICC show P3 values as sRGB (less saturated), and the server's re-encoded sizes may strip the profile. Keep it off until a
  send to Saved Messages confirms the downloaded sizes keep the ICC (needs an account).
- **How to verify**: a unit test builds a P3 image (pure P3 red plus a green gradient), runs `compressImageToJPEG`, and checks that `kCGImagePropertyProfileName == "Display P3"` and the decoded red is within ±3.
- **iOS cross-ref**: `918a6467` (chat-camera photos keep Display P3).
- **Confidence**: low (the server behaviour decides the value).

### Medium (M)

### Q9. AirPods and Bluetooth headsets: notes, circles and calls always open the headset mic, dropping the AirPods to HFP; honour the chosen mic and offer the Mac's built-in mic — `done (85d4081, b78de4d; option off by default)`

- **Evidence**: there is no macOS opt-in (see the intro). The voice recorder always binds the system default input (`packages/TelegramMedia/Sources/AudioRecorder.swift:457-466`), and it has an
  upsampler written for the 16/24 kHz HFP rates (`:720-741`, covered by H16). Round video uses `AVCaptureDevice.default(for: .audio)`
  (`MediaRecorderUI/VideoRecorderPipeline.swift:183-199`). The user's mic choice (`InAppSettings/VoiceCallSettings.swift:79` `audioInputDeviceId`, resolved by
  `TelegramMediaUtils/DevicesContext.swift:306-311,328-330`) reaches calls only (`TelegramCallsCore/PCallSession.swift:1058`). With "Default" selected, calls get the AirPods.
  CoreAudio already exposes the transport types (`AudioHardwareBase.h:608,614-615`), and `AVCaptureDevice.transportType` (macOS-only, `AVCaptureDevice.h:248`).
- **Today**: connected AirPods are the default input and output. Opening their mic switches them from A2DP/AAC to HFP for the whole note, circle or call: the
  recording or the remote side gets muffled "phone-line" 16/24 kHz voice, and everything the user hears, music included, becomes narrow mono until the mic closes. Notes and circles
  also ignore a USB or MacBook mic the user picked in call settings.
- **Fix**: one pure device policy in DevicesContext, used by all three paths. (a) Honour `audioInputDeviceId` in notes and circles: for AUHAL, translate the UID with
  `kAudioHardwarePropertyTranslateUIDToDevice` and set `kAudioOutputUnitProperty_CurrentDevice` (after H16, `engine.inputNode.auAudioUnit.setDeviceID(_:)`). For
  circles, use `AVCaptureDevice(uniqueID:)`. (b) Add a setting, "Use the Mac's microphone with Bluetooth headphones". When the selection is "Default", the resolved input's
  transport type is Bluetooth or BluetoothLE, and an alive `kAudioDeviceTransportTypeBuiltIn` device with input streams exists (macOS 14 `DiscoverySession([.microphone])` also works),
  record from the built-in mic. The AirPods then stay in A2DP for playback. An explicit AirPods choice is always honoured. Fallback: with no built-in mic (Mac mini or Studio, a closed MacBook), use today's behaviour.
  Extend `CaptureDeviceCandidate` with the transport type so `resolveCaptureDeviceId` stays pure, and re-run the policy on device-change notifications (Q12).
  (c) Re-check each SDK for a macOS opt-in, and test on hardware whether a VoiceProcessingIO client (Q15, the H16 option) gets the system's AirPods studio-quality mode. That cannot be verified from code.
  The default is a product decision: on for laptops is reasonable.
- **Gain**: the most audible AirPods change. Calls, notes and circles get full-band 48 kHz audio from the MacBook's beamformed mic array instead of HFP, and the AirPods keep stereo AAC
  playback during and after recording or calls. Users with a chosen USB mic get it everywhere.
- **Risk**: the built-in mic is farther away, so the level is lower and it picks up more room and keyboard noise, hence the setting. On headphones, echo is negligible.
  When the lid is closed, the built-in mic is unavailable; check `isConnected` there.
- **How to verify**: unit-test the pure resolver with fake candidates (UID, transport, alive, has input): Bluetooth default plus built-in → built-in when the flag is on;
  flag off → AirPods; explicit selection → always honoured; no built-in → AirPods. Code check: notes, circles and both call paths read the policy. On hardware without an account, a
  small CLI opens the chosen input and reads the AirPods output's `kAudioDevicePropertyNominalSampleRate` (it stays 44.1/48 kHz with the built-in mic). A decoded note's spectrum stops at
  8/12 kHz under HFP and reaches about 20 kHz with the built-in mic.
- **iOS cross-ref**: `63094959` (voice), `a4f2a32b` (circles), `de29c10d` (story-reply circles). These are the iOS 26 opt-in and cannot be ported; this is the Mac equivalent.
- **Confidence**: high for the code paths and the missing API; the user-facing default is a product call.

### Q10. Round videos are encoded at 300×300 after two hidden resamples (server diameter 384, iOS 400/480); encode at the server diameter with one controlled downscale — `done (ddfa750)`

- **Evidence**: `packages/TGVideoCameraMovie/Sources/TGVideoCameraMovieRecorder.m:26-30,176-183` (the size is `vmSide`, NSUserDefaults `videoMessageSide`, default 300, never set).
  `MediaRecorderUI/VideoMessageConfig.swift:13,33` parses `round_video_encoding.diameter` (default 384), and nothing reads it. `VideoRecorderPipeline.swift:176-180`
  uses the 1280×720 preset, `:214` asks the capture output for 500×500 BGRA (the first implicit resample), and `:397-402` gives the writer 300×300 (the second, inside the encoder).
  `ChatRecordingState.swift:310` sends 200×200 as the dimensions. The writer has no profile or entropy settings (`TGVideoCameraMovieRecorder.m:60-90`), while
  `EditVideoExport.swift:609-613` uses High + CABAC. iOS: `CameraLegacy/CameraRoundVideoFilter.swift:16` (400), `CameraNeo/RoundVideoFrameProcessor.swift:225-226` (480).
- **Today**: the circle is scaled 720 → 500 → 300 with filters nobody chose, then upscaled two to three times on Retina or an iPhone. Faces look soft, and hair and text shimmer. Mac circles are
  visibly worse than iOS circles from the same account, even though the 1 Mbit/s bitrate is far more than 300² pixels need.
- **Fix**: (1) use `config.diameter` (or 480, capped by the server value) for `AVVideoWidthKey`/`HeightKey` and the sent `PixelDimensions`, and fall back from `vmSide` to it. (2) Resample once:
  drop the width and height keys from `videoOutput.videoSettings` and let `TGVideoCameraGLRenderer` crop the native frame (its aspect and offset code handles non-square input). Size its output pool to the final
  diameter, so the writer never rescales. The renderer already mipmaps (`TGVideoCameraGLRenderer.m:364-366`); for ratios of 2× or more, prefilter with `vImageScale_ARGB8888` +
  `kvImageHighQualityResampling`, or `MPSImageLanczosScale` once H21 moves the renderer to Metal. (3) Set `AVVideoProfileLevelH264HighAutoLevel` + CABAC. Keep `config.videoBitrate`.
  All of these are available at macOS 10.13+; there is no fallback beyond keeping the 720p preset when no larger format exists.
- **Gain**: 1.6× (384²) to 2.6× (480²) more pixels at the same bitrate (about 0.15 bits per pixel at 480², still comfortable), sharper faces, no shimmer, and parity with iOS circles.
- **Risk**: file size stays under the server bitrate and `fileSizeLimit`. Uploading 1280×720 into GL costs more until H21 (or until the unused `_textureCache` maps the camera buffer). The field of view may
  change slightly if the capture format changes.
- **How to verify**: a unit test checks that the track settings and sender dimensions equal `config.diameter`. An offline harness feeds the renderer and recorder a synthetic 1280×720 zone-plate sequence and asserts
  the output `naturalSize` is 384² (or 480²). Compare aliasing against an ffmpeg Lanczos reference with SSIM, today's path against the new one, and run `ffprobe` (profile High, CABAC).
- **iOS cross-ref**: `918a6467` (supersampling when the camera is more than 2× the output), CameraNeo `RoundVideoLanczosScaler`, `93c4de0e`. Do it with or after H21.
- **Confidence**: high.

### Q11. Edited or compressed video sends: HDR (HLG/Dolby Vision) clips come out flat and washed out, and the downscale is plain bilinear — `done (2be3958, cc4584b)`

- **Evidence**: `packages/ImageCanvasUI/Sources/ImageCanvasUI/EditVideoExport.swift:312` (a `CIContext` with NSNull working and output colour spaces). `:428-437`
  (`AVMutableVideoComposition(applyingCIFiltersWithHandler:)` with `colorPrimaries`/`colorTransferFunction`/`colorYCbCrMatrix` left nil, so the source's are propagated).
  `:596,605-614` (8-bit BGRA reader into an 8-bit H.264 writer). `:410` (downscale by an affine transform, linear sampling). `:221-223` sends any quality change, crop or adjustment down this path.
- **Today**: an iPhone HDR clip that the user crops, adjusts or sends at a lower quality keeps its HLG transfer and BT.2020 primaries through an unmanaged 8-bit pipeline, so recipients see flat,
  grey, desaturated video, sometimes banded. A 4K → 720p/480p downscale has no prefilter, so foliage, fabric and text crawl. Unedited sends are passed through untouched.
- **Fix**: (1) set the composition's primaries, transfer and matrix to `ITU_R_709_2` (macOS 10.12+), so AVFoundation hands the handler SDR 709 frames, and tag the writer (Q3). (2) Use a
  colour-managed `CIContext` (default working space, output `CGColorSpace.itur_709` or sRGB). (3) When the scale is below 0.75, downscale with `transformed(by:highQualityDownsample: true)` (macOS 10.12+) or
  `CILanczosScaleTransform`. Optional: for "original" quality with an HDR source, write HEVC Main10 with 2020/HLG tags. That has compatibility risk on older Android, so it is not the default.
- **Gain**: HDR clips sent from the Mac look as they do in Photos, and downscaled sends lose their shimmer and moiré.
- **Risk**: a little more GPU per frame on an offline export. The adjustment kernel was tuned on raw values, so compare the preview with the export. Confirm that the CI-handler composition actually tone-maps when tagged 709.
- **How to verify**: synthesize a 2 s HLG clip (HEVC Main10, 2020/HLG attachments, a grey ramp, skin and saturated patches), export at `.high`, and assert 709 tags plus patch ΔE < 3 against an
  `AVAssetImageGenerator` SDR render. For scaling, export a 3840×2160 zone plate at `.medium` and compare SSIM with ffmpeg Lanczos.
- **iOS cross-ref**: `7d600b48` (export tags).
- **Confidence**: medium (code verified; the tone-map behaviour of the CI-handler composition is to be confirmed by the harness).

### Q12. The voice recorder never reacts to device or rate changes and fails silently, so an AirPods switch mid-note can give an empty, cut or wrong-pitch note (extends H16) — `done (fa42c17, 107ee55)`

- **Evidence**: `packages/TelegramMedia/Sources/AudioRecorder.swift:429` publishes `.recording` before any audio setup. `:466-468,493-495` return without disposing the unit or changing the state,
  and `:435-449,461-464,499-528` also return silently. `:470-498` picks the rate before `AudioOutputUnitStart` (`:541`), and Bluetooth headsets change rate when input IO starts.
  `:252-255` only traces render errors. There is no device, rate or default-input listener in the recorder, and `DevicesContext.swift:218` listens for calls only.
  `VideoRecorderPipeline.swift` has no `AVCaptureSession.runtimeErrorNotification`/`wasDisconnectedNotification` observers. For contrast, `ChatUI/ChatInputDictationEngine.swift:68-74` observes `AVAudioEngineConfigurationChange`.
- **Today**: if mic setup fails, the timer runs while nothing is captured, and the unit leaks. If the rate changes after the format was chosen (AirPods entering HFP, an input switch in Control Center,
  AirPods disconnecting), the note gets a silent tail or stops. Where AUHAL keeps delivering, samples are labelled with the old rate, giving the wrong pitch and speed (inferred, not reproduced).
- **Fix**: with H16's AVAudioEngine design, observe `AVAudioEngineConfigurationChange` (macOS 10.10) on the recorder queue, then rebuild the tap and `AVAudioConverter` for the new
  input format, restart, and keep writing to the same Ogg writer (seamless after Q2). Until then, add `AudioObjectAddPropertyListenerBlock` (macOS 10.7) for the device's
  `kAudioDevicePropertyNominalSampleRate`/`DeviceIsAlive` and the system's `kAudioHardwarePropertyDefaultInputDevice`, and run teardown plus `start()` on the queue. Publish `.recording` only
  after `AudioOutputUnitStart` succeeds. On failure, dispose the unit and publish `.paused` or an error. For circles, observe the capture-session notifications and fall back to the new default mic (Q9 policy).
- **Gain**: no silently empty voice notes, and no cut or wrong-pitch notes when AirPods connect, drop or switch profile mid-recording.
- **Risk**: low to medium. A rebuild leaves a short gap (tens of ms, longer for a Bluetooth profile switch). Listener callbacks must hop to the recorder queue.
- **How to verify**: inject a device-format provider and stream 48 kHz then 24 kHz: the Ogg duration matches the input ±20 ms, and the FFT peak of a 1 kHz tone stays at 1 kHz in both halves.
  Force an `AudioUnitSetProperty` failure and assert that the state is not `.recording` and the unit is disposed.
- **iOS cross-ref**: `4c229c73` (the queue-side drain design to reuse when rebuilding).
- **Confidence**: medium (the silent failures are verified; the wrong-rate symptom is inferred).

### Q13. Hand-built passthrough format descriptions force video range and carry no colour or HDR metadata (old player: non-HLS H.264/HEVC, gallery GIFs, live photos) — `done (3afe194 core)`

- **Evidence**: `MediaPlayer/Sources/FFMpegMediaFrameSourceContextHelpers.swift:11-35` (avcC) and `:67-91` (hvcC) hard-code `FullRangeVideo = 0` (twice), chroma "left" and depth 24, with no
  primaries, transfer, matrix, mastering-display or content-light extensions. `FFMpegMediaFrameSourceContext.swift:503-514` uses the passthrough decoder for H.264/HEVC whenever hardware is allowed.
  The callers are `GalleryUI/NativeMediaPlayer.swift:49` (non-HLS videos with an h264/hevc attribute), `MGalleryGIFItem.swift:74` and `MGalleryPhotoItem.swift:99` (live photos).
- **Today**: if VideoToolbox trusts the description over the SPS VUI, full-range H.264 from Android phones and screen recorders shows crushed blacks, and HLG/PQ HEVC (iPhone HDR sent as a file)
  loses its transfer and primaries and looks flat instead of HDR/EDR. The same file opened through ChunkMediaPlayerV2 looks different, because FFmpeg tags it.
- **Fix**: expose `color_range`/`color_primaries`/`color_trc`/`color_space` and the mastering and light-level side data in `metricsForStream`, set the matching `kCMFormatDescriptionExtension_*` keys
  (including `ITU_R_2100_HLG`/`SMPTE_ST_2084_PQ`, macOS 10.14+), and drop the hard-coded `FullRangeVideo = 0`. The alternative is `CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets`
  with the colour keys in `extensions`, or moving NativeMediaPlayer to the FFmpeg-hwaccel decode that ChunkMediaPlayerV2 uses. No fallback is needed.
- **Gain**: correct contrast for full-range clips, real HDR on XDR/EDR displays for HDR files, and the same picture in both players.
- **Risk**: low for SDR. HDR files get brighter on EDR displays, as intended; check that HDR in small chat bubbles is not too bright.
- **How to verify**: generate H.264 pc-range, HEVC Main10 HLG, HEVC Main10 PQ (with mastering SEI) and SD 601 files. Compare our description's extensions with `AVURLAsset`'s track descriptions, then decode
  frame 0 through `VTDecompressionSession` with each and compare the attachments and the Y/Cb/Cr of a known bar. That also shows whether VT already falls back to VUI, which decides whether the fix is needed.
- **iOS cross-ref**: the same idea as `58bda613`/`d5d3b440`/`7d600b48` (tags must describe the pixels), applied to decode. The iOS code is identical.
- **Confidence**: medium (code verified; the visible effect depends on VT, which the harness measures).

### Q14. Call-video renderers ignore the frame's YCbCr matrix and range and always use full-range BT.601 — `partial: CallVideoLayer renderers (221326e); tgcalls I420 renderer not changed`

- **Evidence**: `packages/CallVideoLayer/Sources/CallScreenShaders.metal:353-356,475-482` and `Resources/shaders/MetalFunctions.metal:56-71` use fixed full-range BT.601 coefficients.
  `CallVideoLayer/Sources/MetalVideoRenderView.swift:9-10,76,107` copies I420 into `420f` without range conversion. `tgcalls/platform/darwin/macOS/TGRTCMTLI420Renderer.mm:59` sends every frame, hardware
  NV12 included, through a CPU `toI420`. Mac and iPhone cameras deliver BT.709-matrixed HD.
- **Today**: camera video from Apple senders gets a mild hue shift on skin and reds (the bug class iOS fixed for circles). Limited-range sources (VP8 group-call screencasts, cameras delivering `420v`) look washed out.
- **Fix**: for `CVPixelBuffer` frames, choose the matrix from `kCVImageBufferYCbCrMatrixKey` (601, 709 or 2020) and the range from the pixel format, and pass a 3×3 matrix and offset uniform to both
  shaders. Keep full-range 601 for untagged I420 (the de-facto Telegram convention). Drop the CPU `toI420` for NV12 in `TGRTCMTLI420Renderer` (use `CVMetalTextureCache`, as MetalVideoRenderView does). Pure code; no fallback.
- **Gain**: correct skin tones and contrast for tagged sources, and one full-frame CPU copy fewer per received frame in the tgcalls renderer.
- **Risk**: iOS camera frames can be tagged 601 while carrying 709 data (iOS `d5d3b440`), so measure the real tags before trusting them.
- **How to verify**: an offscreen Metal test renders a 709-tagged `420f` colour-bar buffer and matches `vImageConvert_420Yp8_CbCr8ToARGB8888` with the 709 matrix within 2 levels, and a 601 untagged buffer is unchanged.
- **iOS cross-ref**: `58bda613`, `d5d3b440`, `7d600b48`. iOS shares the same full-range 601 call shaders.
- **Confidence**: medium.

### Large (L)

### Q15. Calls use WebRTC's plain AUHAL device module with software AEC3/NS, not Apple voice processing, so Voice Isolation, Wide Spectrum and the system echo canceller never apply — `dropped: needs a VPIO ADM in tgcalls verified by an ERLE harness on real hardware (ledger ruling)`

- **Evidence**: `submodules/tgcalls/tgcalls/v2/InstanceV2Impl.cpp:2150-2175` (on macOS `webrtc::AudioDeviceModule::Create(kPlatformDefaultAudio)`; only `WEBRTC_IOS` gets
  `AudioDeviceModuleIOS`), and `:1123-1124,150-153` (default AudioProcessing with AEC3 and NS on). Group calls: `group/GroupInstanceCustomImpl.cpp:4339-4398` (the same ADM) and `:2311-2320` (RNNoise).
  There is no `VoiceProcessingIO` in `tg_owt/src/modules/audio_device/mac/`. The ADM hooks are commented out in `tgcalls/macos/Sources/OngoingCallThreadLocalContext.mm:1047,1684`.
  `tg_owt/src/media/engine/webrtc_voice_engine.cc:534-545` turns software AEC/NS off when the ADM reports built-in ones. `tgcalls/platform/darwin/iOS/tgcalls_voice_processing_audio_unit.mm`
  is a reusable VPIO wrapper. SDK: `kAUVoiceIOProperty_MutedSpeechActivityEventListener` and `kAUVoiceIOProperty_OtherAudioDuckingConfiguration` are macOS 14+ (`AudioUnitProperties.h:2678,2714`).
  WWDC21 10047 says Mic Modes need the AUVoiceIO unit. This resolves the calls-audio item in "Not checked (H)".
- **Today**: the mic goes raw into generic AEC3 and NS. On MacBook speakers and mic, the most common Mac call setup, that means residual echo and clipped word starts during double talk,
  and "underwater" suppression of fans and typing. Choosing Voice Isolation or Wide Spectrum in Control Center does nothing in a Telegram call, while FaceTime and Zoom get Apple's tuned processing.
- **Fix**: add a macOS ADM in tgcalls (`platform/darwin/macOS/tgcalls_audio_device_module_macos.mm`) on `kAudioUnitSubType_VoiceProcessingIO`, reusing the iOS wrapper without the RTCAudioSession
  parts. Set `kAudioOutputUnitProperty_CurrentDevice` on both buses from DevicesContext (Q9 policy), and run 48 kHz mono Int16 on the client side. Set
  `OtherAudioDuckingConfiguration {enableAdvancedDucking = true, duckingLevel = Min}`, so music is not pushed to near silence. Report `BuiltInAEC/NS/AGCIsAvailable = true` so WebRTC turns AEC3/NS off,
  and keep RNNoise off while VPIO is active. Wire it through `createWrappedAudioDeviceModule` for 1:1 and group calls, and keep the screencast FakeADM. Show the mode via KVO on
  `AVCaptureDevice.activeMicrophoneMode`, and add a button for `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`. Muted-talker detection comes with the macOS 14 listener.
  An equivalent route is `AVAudioEngine` with `inputNode.setVoiceProcessingEnabled(true)` (macOS 10.15) feeding the ADM's buffer.
  Fallback: if `AudioUnitInitialize` fails, or the user turns the new setting off, use today's ADM.
- **Gain**: Apple's device-tuned echo cancellation (cleaner double talk on laptop speakers), beamforming and noise suppression from the MacBook mic array, and the user's choice of
  Voice Isolation (strong background removal) or Wide Spectrum (music, several people). This matches FaceTime, and AEC3/NS CPU leaves the WebRTC worker.
- **Risk**: VPIO forces mono output (group-call stereo playout is lost while it is active) and adds about 10-20 ms of latency. Device changes need a unit restart. Some developers report low output volume with Bluetooth
  output plus the built-in mic (Apple forums thread 655610), so test that route together with Q9. Voice Isolation users who play music into a call need Wide Spectrum, so show the mode in the call UI. Land it in the klaipher/tgcalls fork behind
  `#if WEBRTC_MAC && !WEBRTC_IOS`.
- **How to verify**: an offline harness (a CLI linking TgVoipWebrtc, no account) creates the ADM, plays a far-end speech WAV and records the near end for 20 s on the MacBook speakers and mic. Compute ERLE against the
  same run with the AUHAL ADM plus offline `webrtc::AudioProcessing`. Check the log line "Disabling EC since built-in EC will be used instead", and check that `activeMicrophoneMode` follows Control Center while the harness
  runs (the app should appear under Mic Mode). A unit test covers the VPIO-init-failure fallback.
- **iOS cross-ref**: iOS calls already use VPIO (upstream `tgcalls_voice_processing_audio_unit.mm`). The voice-note half on the Mac is H16's optional voice processing.
- **Confidence**: high for the code path and the APIs; the size of the audible gain needs the harness.

### Already good (keep)

- **Voice notes open the mic only while recording**, and pause tears the audio unit down (`AudioRecorder.swift:586-599`), so AirPods return to A2DP for the paused voice preview.
  Nothing opens the mic at launch or idle: MicroListenerContext runs only in the call-settings preview row, and dictation runs AVAudioEngine only while dictating and handles configuration changes.
- **Opus voice settings match iOS**: 48 kHz mono, 20 ms frames, 30 kbit/s VBR, `APPLICATION_AUDIO` (`opusenc.m:124-127,215-225`). The recording-state throttle (10 Hz) and the 2-byte waveform
  peaks are correct, so the iOS bugs fixed in `63094959` are absent here.
- **Playback follows the output device**: device changes rebuild the renderer, and the clock follows the device (`MediaPlayerAudioRenderer.swift:812-866`). ChunkMediaPlayerV2 syncs through
  `AVSampleBufferRenderSynchronizer` and paces video on the layer's timebase, so ProMotion frame pacing comes from the system.
- **Main video path colour**: H.264/HEVC in ChunkMediaPlayerV2 decode through FFmpeg's VideoToolbox hwaccel, which picks P010 for 10-bit and writes real matrix, primaries and transfer (PQ/HLG included).
- **Unedited sends are bit-exact**: the original file is uploaded (`FetchVideoMediaResource.swift:60-72`), and round-video joins and trims use passthrough export (`RecordingVideoExport.swift:84`).
  Photo downscale uses ImageIO thumbnails with orientation, and mozjpeg uses ISLOW DCT, optimized Huffman and progressive scans. The edited-video writer uses H.264 High + CABAC.
- **Calls**: hardware H.264/H.265 encode and decode in 1:1 calls (offer order: Constrained High, Baseline, VP8, VP9, H.265), and Opus with in-band FEC at 48 kHz (WebRTC converts HFP rates with an AudioConverter).
  The arm64 H.264 gate in `DarwinInterface.mm:82-111` feeds only the legacy MediaManager path (`CodecSelectHelper.cpp:37-46`), so current V2 calls on Apple Silicon are not pushed off H.264.
  This resolves H28's "related, not verified" note. The Mac camera is a plain AVCaptureSession at 1280×720/25 fps, inside the limits for system video effects (Portrait, Center Stage, reactions),
  and Continuity Camera already works.

### Dropped after checking (Q)

- **Playback P2 (a)-(c)** (software video ignores range and tags, 10-bit dropped): a duplicate of **H22**. The new parts, the P3-labelled previews and the M3+ AVAssetReader 8-bit output, are Q7.
- **Playback P4** (music and voice decoded to 16-bit 44.1 kHz and resampled twice): a duplicate of **H20**. When doing H20, also decode to float, so 24-bit FLAC/ALAC is not truncated without dither and hi-res files
  are not downsampled, and set `kAudioUnitProperty_SampleRateConverterComplexity = Mastering` if an AUConverter remains.
- **The capture-send and calls AirPods findings** (round-video mic policy, calls built-in mic): merged with the voice-note finding into **Q9**, one device policy for all three paths.
- **"Port the iOS 26 high-quality Bluetooth recording API"**: impossible. Both APIs are `API_UNAVAILABLE(macos)` in the 27.2 SDK (see the intro).
- **The crude 16/24 kHz upsampler, the system-wide nominal-rate write, and the 44.1 kHz pass-through in the voice recorder**: already **H16**. M19 (libopus `-Os`) is not repeated.
- **`OPUS_SET_MAX_BANDWIDTH` for HFP input**: not needed. libopus 1.3.1 already limits bandwidth automatically once H16 resamples properly.

### Not checked (Q)

- Real AirPods on macOS 26/27: the rates HFP input reports, when the profile switch happens relative to `AudioOutputUnitStart`, and whether the system's AirPods studio-quality mode engages for VPIO clients (Q9, Q15). This needs hardware.
- How Telegram Android, iOS and Desktop players handle `OP_HOLE` or a mid-stream BOS page in notes already received (Q2).
- The YUV range conventions of tdesktop and Android receivers (Q5), and the codec the group-call SFU picks for screencasts.
- libopus on the Mac is 1.3.1, while the iOS fork is on 1.6.1 with OSCE/BWE/DRED off. The quality difference at 30 kbit/s speech was not evaluated.
- Which camera pixel format (420v or 420f) Mac cameras deliver to calls (`VideoCameraCapturerMac.mm:636-647`), and the camera frame-rate floor in low light (`:672-693` may allow drops toward 1 fps).
- How `AVCaptureVideoDataOutput` scales 1280×720 to the requested 500×500 (crop or fit, and with which filter); Q10 removes that step either way.
- Whether Telegram servers keep ICC profiles in re-encoded photo sizes (Q8), and whether P3 photos are clipped in the DeviceRGB `DrawingContext` on display (already in "Not checked (H)").
- Time-stretch quality at 1.5×/2×, volume normalisation of voice notes, and 4:4:4 chroma for screenshot JPEGs (product ideas, not evaluated).

## Implementation status (2026-11-02)

Runtime branch `nanogram/runtime` after integration (2026-11-03): clean Debug build at the macOS 15 target succeeds, the app opens its login window and stays up 60 s with no crash report. Details, rulings and owner steps are in `.superpowers/sdd/runtime/progress.md`; core commits are in `submodules/telegram-ios` (branch `nanogram-mac-runtime`), tgcalls commits in `submodules/tgcalls` (local branch `nanogram-mac-runtime`).

| Spec | Status | Commit |
|---|---|---|
| M1 | done | dd412d9 |
| M2 | done | 7136832 |
| M3 | done | 795c4f8, e605e56; core 3ec2f14, 3a11ddd |
| M4 | done | 1ac6562 |
| M5 | done | 934ac65, core d985e78 |
| M6 | done | a84a3c8 |
| M7 | done | b93d09d |
| M8 | done | 9734759, 0e20f68; core 867d5c5 |
| M9 | done | core 0319e83 |
| M10 | done | core 10e47fe |
| M11 | done | e48de99 |
| M12 | done | 28b6e26 |
| M13 | done | cdb8e5f |
| M14 | done | f20014e |
| M15 | stage 1 | — |
| M16 | done | core 09ee786 |
| M17 | stage 1 | — |
| M18 | done | 1becb21 |
| M19 | stage 1 | — |
| M20 | dropped | 2184207 (lab) |
| M21 | done | 770513f, core 1140dbe |
| M22 | done | 47580f4 |
| M23 | done | 6bbcf5e |
| M24 | done | core 5751188 |
| M25 | partial | cb8d0f1 |
| M26 | done | f4e1837, core 19875d3 |
| M27 | done | 25b7f7a, core d6c3ef8 (FFmpeg rebuild pending for the VT patch) |
| M28 | done | core 0ff4315 |
| M29 | done | ee9a00f, f55b999 |
| M30 | done | b78cfaf |
| M31 | done | 311fe98 |
| M32 | deferred (ruling) | — |
| H1 | done | da40434 |
| H2 | done | f4bb74b, core 1e9c875 |
| H3 | done | core a001272 |
| H4 | done | 2a53b7c |
| H5 | done | 28d0503, 8edbc7e; core 1aef8d8, 54151f1 |
| H6 | done | 9c174f7 |
| H7 | done | 957d823, core 036e94f |
| H8 | done | 0760adc |
| H9 | done | 8f7c6e5 |
| H10 | stage 1 | — |
| H11 | done | 73de50e |
| H12 | done | 1a0cdb0 |
| H13 | done | 52ffa2d, core df65bdef |
| H14 | partial | 091fa70 |
| H15 | stage 1 | — |
| H16 | done | c18caa9 |
| H17 | done | 12d814a |
| H18 | partial | d0a7c3e |
| H19 | partial | 0f80540 |
| H20 | measured, no change (ruling) | — |
| H21 | not done (ruling) | — |
| H22 | done | 9ad344d |
| H23 | partial | 9d62367 |
| H24 | partial | 0eb0950 |
| H25 | partial | b0fbff2 |
| H26 | not done (ruling) | — |
| H27 | done | 02d4e35 |
| H28 | partial | 9efe49a |
| Q1 | done | 2955fe5 core |
| Q2 | done | b23b004 core, 36315cc |
| Q3 | done | 0879d4e |
| Q4 | done | 0ee33a3 |
| Q5 | partial | 9efe49a (via H28) |
| Q6 | done | tgcalls 9ab1773, c66b2ea |
| Q7 | done | 0a053b6 core |
| Q8 | done | dab5e38, f51c974; Debug Settings switch, off |
| Q9 | done | 85d4081, b78de4d; option off by default |
| Q10 | done | ddfa750 |
| Q11 | done | 2be3958, cc4584b |
| Q12 | done | fa42c17, 107ee55 |
| Q13 | done | 3afe194 core |
| Q14 | partial | 221326e |
| Q15 | dropped | — |

Integration fixes: 6fe2eb1, 4c375e3 (`CGWindowListCreateImage` is unavailable at the macOS 15 target; looked up at runtime).
