# macOS specs

Repo: `klaipher/nanogram-macos` (local `~/Projects/nanogram-macos`). Base for all new branches: the `build/modernize` tip (c489f3fd, released as 13.2.0 and containing `fix/2026-11-13`). The checked-out `nanogram/integration` is behind it. Do not commit with `-a` in Mac worktrees (a stale core submodule rewinds the pin).

Shared iOS core changes reach the Mac only through `tg core-bump <iOS main SHA>` (spec MAC-CORE-BUMP-1 below). Mac-only code lives in `packages/`, `Telegram-Mac/` and `TelegramShare/`.

---

### MAC-CORE-BUMP-1: Take the shared-core changes from this plan
- **Severity:** medium (process; carries IOS-CRYPTO-1, IOS-SIMD-1, IOS-VIDEO-1, iOS-MEDIA-THREADS-1 step 2, iOS-QOS-1, iOS-CONC-1, iOS-CONC-4 MediaDataReader part)
- **Evidence:** the standing rule that every shared-core fix reaches both apps; pin policy in `docs/mac-core-paths.txt` (lag block from 2026-11-18).
- **Change:** after the iOS core workstream is merged into iOS `main`, run `tg core-bump <sha>`; run the Mac package tests for MtProtoKit (IGE vectors on Apple Silicon), MediaPlayer, SSignalKit and GraphCore; confirm the parity gate.
- **Risk:** low; Mac behaviour is unchanged for code under `#if os(iOS)`.
- **Measurement:** IGE micro-benchmark on an M-series Mac; parity gate green.
- **Effort:** small
- **Status:** open

### MAC-POWER-1: User-started video export runs without a ProcessInfo activity or QoS
- **Severity:** medium
- **Evidence:** only `ChatExportManager.swift:167/1153` use `performActivity`. `EditVideoExport.swift:722` and `:882` and `EditVideoStreamingWriter.swift:104-105` create queues with no QoS and no activity.
- **Change:** `beginActivity(options: [.userInitiated], reason:)` around export setup to finish or cancel, `endActivity` on every path; export queues at `qos: .userInitiated`. Idle sync keeps App Nap.
- **Docs:** https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:)
- **Risk:** low (activity must end on every path).
- **Measurement:** 2-minute 4K export while occluded: wall time; `pmset -g assertions`.
- **Effort:** small
- **Status:** open

### MAC-IMAGE-1: Photo send reads the whole file before downsampling
- **Severity:** low
- **Evidence:** `SenderController.swift:377` `Data(contentsOf:)`, then `CGImageSourceCreateWithData(..., nil)` at 387.
- **Change:** `CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false])` and ShouldCache false in thumbnail options; `.mappedIfSafe` for the voice and round-video reads at 349 and 362. Same output (JPEG 0.75, same size).
- **Docs:** https://developer.apple.com/documentation/imageio/cgimagesourcecreatewithurl(_:_:)
- **Risk:** very low.
- **Measurement:** peak footprint dropping 10 x 40 MB photos.
- **Effort:** small
- **Status:** open

### MAC-IMAGE-2: WebP fully decoded to read its size
- **Severity:** low
- **Evidence:** `SenderController.swift:533-537` `convertFromWebP(data)?.size`.
- **Change:** `CGImageSourceCopyPropertiesAtIndex` pixel width and height (ImageIO WebP, macOS 11+), fallback 512x512.
- **Risk:** very low (check animated canvas size).
- **Measurement:** time `fileAttributes` on a 4000x3000 WebP.
- **Effort:** small
- **Status:** open

### MAC-VISION-1: Subject lift creates a CIContext per call and scans pixels
- **Severity:** low
- **Evidence:** `SubjectLifting.swift:164` new CIContext although `outlineContext(for:)` (72-83) caches them; scalar alpha scan at 188-190 over up to 6.5M pixels.
- **Change:** reuse the cached context; bounding box from the instance mask or `generateMaskedImage(ofInstances:from:croppedToInstancesExtent: true)`. Keep `Subject.rect` normalized with the y flip.
- **Docs:** https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatemaskedimage(ofinstances:from:croppedtoinstancesextent:)
- **Risk:** low.
- **Measurement:** signpost around liftSubject on a 12 MP photo, cold and warm.
- **Effort:** small
- **Status:** open

### MAC-MEDIA-1: Video first-frame thumbnails use deprecated synchronous AVFoundation and a temp symlink
- **Severity:** low
- **Evidence:** `TelegramMediaUtils/FetchCachedRepresentations.swift:342-349` and `:598-604`, `TransformOutgoingMessageMedia.swift:91-94`, `SenderController.swift:64-67`, on `cacheThreadPool`.
- **Change:** `AVURLAsset(url:options:[AVURLAssetOverrideMIMETypeKey:])` on the MediaBox path, `generator.image(at:)` bridged into the Signal on a Task, keep maximumSize 800, preferred transform, JPEG 0.6 and cancellation.
- **Docs:** https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:)
- **Risk:** low to medium (test webm, mkv, mov).
- **Measurement:** media grid of 100 uncached videos: time to last thumbnail, pool thread count.
- **Effort:** medium
- **Status:** open

### MACOS-DRAG-1: Drag-out uses the legacy filenames type, a temp copy, and needs downloaded media
- **Severity:** low (feature and correctness, not performance)
- **Evidence:** `ChatMediaContentView.swift:367` drag only when `.Local`; `putFileToTemp` (`FastSettings.swift:794`) copies to tmp; `.kFilenames` and `.string` at 318. No NSFilePromiseProvider.
- **Change:** NSFilePromiseProvider with a UTType from the MIME type; write on an operation queue (clone if complete, otherwise fetch via MediaBox, then write to the given URL). Keep the drag image, threshold and an in-app copy path.
- **Docs:** https://developer.apple.com/documentation/appkit/nsfilepromiseprovider
- **Risk:** medium (retest Finder, Mail, browsers, Photos).
- **Measurement:** drag a 1 GB video: drag-start time, tmp usage; drag an undownloaded video.
- **Effort:** medium
- **Status:** open

### MACOS-ACTIVATE-1: 28 calls to deprecated activate(ignoringOtherApps:)
- **Severity:** low
- **Evidence:** IncomingCallPresenter.swift:83/91, AppDelegate.swift, SharedAccountContext.swift:215, UNUserNotifications.swift:115/119, PeerCallScreen.swift:523, ChatController.swift:13198-13310, AuthController.swift:1393, CrashRecovery.swift:208 (28 total).
- **Change:** `NSApp.activate()` in one mechanical commit; `yieldActivation(to:)` only for handoffs we control.
- **Docs:** https://developer.apple.com/documentation/appkit/nsapplication/activate()
- **Risk:** low.
- **Measurement:** accept a call from a notification with another app frontmost; 28 fewer warnings.
- **Effort:** small
- **Status:** implemented on `mod/mac-conc`: all 28 `activate(ignoringOtherApps: true)` calls are `activate()`; no handoff we control needed `yieldActivation`; not built or run

### MACOS-PANEL-1: FilePanels uses deprecated allowedFileTypes
- **Severity:** low
- **Evidence:** `FilePanels.swift:33`.
- **Change:** `allowedContentTypes` from `UTType(filenameExtension:)`; keep the extension re-check only for directories; nil stays any file.
- **Risk:** low (test .tgs, .json, .strings pickers).
- **Measurement:** every picker that passes `exts` selects the same files.
- **Effort:** small
- **Status:** implemented on `mod/mac-conc`: `allowedContentTypes` via `filePanelContentTypes(for:)` (FilePanels platform raised to macOS 12 for `UTType`); tests added, not run

### MACOS-MAINSEM-1: Main-thread view creation waits on a semaphore
- **Severity:** low
- **Evidence:** `TabBadgeItem.swift:243` `semaphore.wait()` on `activeAccounts |> take(1)`; `GlobalBadgeNode.swift:183-208`; `ChatInterfaceInteraction.swift:1644-1655`.
- **Change:** build from a cached main-actor value kept fresh by a held subscription; update the view on emission. Minimal diff (upstream files).
- **Risk:** low to medium (first-frame layout).
- **Measurement:** Hangs template during account switches; no `semaphore_wait_trap` on main.
- **Effort:** small
- **Status:** partly implemented on `mod/mac-conc`: `TabAllBadgeItem.makeView` reads a cached value kept by a held subscription (bounded 0.25 s wait only if never emitted); `GlobalBadgeNode` and `ChatInterfaceInteraction` waits deferred (upstream files, intentional sync flush); not built or run

### MAC-DESIGN-1: 163 packages and the app target build in Swift 5 mode
- **Severity:** low
- **Evidence:** 163 packages at tools 5.5, 1 at 5.9, 1 at 6.0, 8 at 6.2; 9 use `swiftLanguageModes [.v6]`; 8 `SWIFT_VERSION = 5.0` in the pbxproj.
- **Change:** phase 1: leaf packages (AppAnalytics, AudioPlayerCore, CrashReports, LocalAudioTranscription, ChatAppIntents, CallVideoLayer first) raise tools-version to 6.x and enable complete strict-concurrency checking as warnings; record a baseline in docs. Phase 2 per package at zero warnings. Never on packages with `treatAllWarnings(as: .error)` as errors. Postbox/SSignalKit-dependent packages wait.
- **Docs:** https://www.swift.org/migration/documentation/migrationguide/
- **Risk:** low for phase 1.
- **Measurement:** warning count per package; packages in v6 mode.
- **Effort:** large
- **Status:** phase 1 implemented on `mod/mac-conc`: AppAnalytics, AudioPlayerCore, CrashReports, CallVideoLayer at tools 5.9 with `StrictConcurrency` as warnings; LocalAudioTranscription and ChatAppIntents already v6; baseline in `docs/strict-concurrency-baseline.md` to be measured; phase 2 deferred

### MAC-DESIGN-2: Export drives Signals through four copied semaphore-polling helpers
- **Severity:** low (maintainability; one blocked thread per export by design)
- **Evidence:** `ChatExportManager.swift` waitForComplete (668), waitForResource (808, 1933), blockingFirst (990, 1966), 0.2 s polling.
- **Change:** one fileprivate helper with an `OSAllocatedUnfairLock<T?>` result, dispose-before-return, called from all sites. Async rewrite is optional and out of scope.
- **Risk:** low.
- **Measurement:** export of 10k messages identical output; wakeups.
- **Effort:** small
- **Status:** implemented on `mod/mac-conc`: `ExportBlocking` replaces the four helpers (result in `Atomic`, dispose before return); async rewrite out of scope; tests added, not run

### MAC-DESIGN-3: Share extension waits on two unbounded semaphores in viewDidLoad
- **Severity:** low
- **Evidence:** `TelegramShare/ShareViewController.swift:55-69`.
- **Change:** one `combineLatest(...) |> take(1) |> deliverOnMainQueue` step that continues launch, or bounded waits with defaults. Same order of logic.
- **Risk:** low (manual share-sheet test).
- **Measurement:** viewDidLoad to first frame with a cold account store.
- **Effort:** small
- **Status:** implemented on `mod/mac-conc`: theme and localization read by one `combineLatest |> take(1) |> deliverOnMainQueue` step, launch continues in `continueLaunch`; manual share-sheet test needed

### MAC-DESIGN-7: 41 @unchecked Sendable declarations without an isolation story
- **Severity:** low
- **Evidence:** IncomingCallPresenter.swift:9, DecoderXPCClient.swift (3, 264), IsolatedDecoderBackend.swift (10, 134), ChatInputDictationEngine.swift (57, 634), LocalAudioTranscription.swift (13, 121), CrashReportStore.swift:12.
- **Change:** UI classes to `@MainActor`; lock-guarded state into `OSAllocatedUnfairLock<State>` or `Mutex`; XPC reply boxes to checked continuations; a one-line invariant comment on the rest. Target fewer than 15.
- **Risk:** low to medium (isolation ripples).
- **Measurement:** count of `@unchecked Sendable`; TSan run of perflab suites.
- **Effort:** medium
- **Status:** partly implemented on `mod/mac-conc`: `DecoderQuarantine` and `ReplyBox` are checked Sendable (`OSAllocatedUnfairLock`); 41 to 39; the rest deferred (UI-bound and package-platform-limited classes need a build to verify isolation changes)

### MACOS-LIST-1: End of live resize re-measures every loaded row
- **Severity:** medium
- **Evidence:** `TableView.swift` viewDidEndLiveResize to `layoutItems()` (~2308): makeSize then `reloadData(row:)` per item; per-row `noteHeightOfRows`, and remove/insert per row for offscreen items. Also from `TGSplitView.swift:103`.
- **Change:** phase 1: visible range plus margin measured synchronously; phase 2: one `noteHeightOfRows` with a single IndexSet inside begin/endUpdates; scroll state restored after phase 2. Phase 3 (off-main measuring) only after a TextViewLayout thread-safety check; otherwise lazy measuring on main in chunks.
- **Docs:** https://developer.apple.com/documentation/appkit/nstableview/noteheightofrows(withindexeschanged:)
- **Risk:** medium (scroll anchor).
- **Measurement:** add a `tableLayoutItems` signpost; longest hang at resize end in a 500-message chat.
- **Effort:** medium
- **Status:** open

### MACOS-LIST-2: TableView.remove(range:) removes the wrong rows
- **Severity:** low (no callers)
- **Evidence:** `TableView.swift:~3039` loops `remove(at: i)` with increasing i.
- **Change:** delete the method (no callers).
- **Risk:** none.
- **Measurement:** build passes; grep shows no callers.
- **Effort:** small
- **Status:** open

### MACOS-IMG-1: Decoded-photo cache fixed at 24 MB with a 15 s grace
- **Severity:** low (needs hit-rate data first)
- **Evidence:** `PhotoCache.swift:397-409`; about 12 display-size photos at 2x.
- **Change:** first read the ScopedImageCache counters (01740f7c) in a debug build. Then scale byteLimit with physical memory (clamped 24-128 MB for photos) and raise the photos grace to 60-120 s. Keep memory-pressure and idle purges; stay under the 120 MB DrawingContext cap.
- **Risk:** low to medium (resident memory).
- **Measurement:** hit rate scrolling a 300-photo chat and bouncing between chats.
- **Effort:** small
- **Status:** open

### MACOS-MEDIA-1: Per-chunk download and upload status reaches every visible view
- **Severity:** low
- **Evidence:** `ChatInteractiveContentView.swift:1050-1262` status signals with `deliverOnMainQueue` and no throttle; same in ChatFileContentView:297, ChatAudioContentView:291, ChatVideoMessageContentView:444, ChatVoiceContentView:204.
- **Change:** a `coalescedProgress(minDelta: 0.01, minInterval: 1/30)` operator in a new TelegramMediaUtils file: state changes pass at once, only progress is rate-limited, last value always delivered; applied before `deliverOnMainQueue`. Mac packages only, never the shared core.
- **Risk:** low.
- **Measurement:** status next() per second during a 200 MB download with 6 visible items.
- **Effort:** small
- **Status:** open
