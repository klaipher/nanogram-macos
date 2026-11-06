# Profiling Nanogram (iOS and macOS)

How to measure a performance complaint on either app with Xcode 27 / Instruments 27, from the command line
first. The same file lives in the iOS and the Mac repo; keep them identical.

Checked on 2026-11-05 against `xcrun xctrace` 27.2 (27B52), the macOS 27.2 SDK headers and Apple's
documentation (links at the end). Commands were read from `xctrace help`, not recorded, unless noted.

## Rules that decide whether a trace means anything

1. **Profile an optimised build.** Debug is `-Onone` on both apps; Apple's own guidance (WWDC26 session 268)
   is that Debug data misleads. Debug traces are only good for "is this called at all".
2. **The app must be debuggable** (`get-task-allow = true`) for Allocations, Leaks, VM Tracker, Swift
   Concurrency, Processor Trace on device, and for attaching on an iPhone. Builds we ship are not:
   TestFlight/App Store and the Developer ID direct edition carry no `get-task-allow`, and the direct edition
   has the hardened runtime. Sampling a shipped Mac app still works with `--all-processes` for Time Profiler,
   System Trace and Hangs only; nothing that needs the task port, and never Metal System Trace or Processor
   Trace (those are attach-only, see "Recording rules").
3. **Do not profile under Xcode's debugger or with `CA_DEBUG_TRANSACTIONS`.** lldb, queue debugging and the
   transaction backtraces distort every number. The Mac `Telegram` scheme sets `CA_DEBUG_TRANSACTIONS=1` for
   Run, and its Profile action reuses Run's environment and the Debug configuration (see "Known gaps").
4. **One machine, one device, same state.** Power, thermal state and the account's data all move the numbers.
   Compare runs of the same build on the same device, plugged in the same way, with the app warmed up the same
   way. Never compare power numbers across device models.
5. **Disk.** A trace is 0.1–3 GB, and Instruments leaves `instruments*.ktrace` files in
   `$(getconf DARWIN_USER_TEMP_DIR)`. Record to `~/traces/` and delete what you do not keep; `tg cache-cleanup`
   removes stale `.ktrace` files on the Mac repo. Check `df -h /` first: no recording below 15 GB free.

## Recording rules

Learned from the 2026-11-05 iPhone and Mac sessions; each one cost a recording.

1. **`toc` after every recording, before anything else.** `xcrun xctrace toc ~/traces/<name>.trace` must
   print the run and its tracks. If it fails, the recording is lost: stop and record again instead of
   analysing a half-written file.
2. **Metal System Trace and Processor Trace are attach-only.** Use `--attach Telegram` (iPhone) or
   `--attach Nanogram` (Mac), never `--all-processes`, with `--time-limit 20s` for Metal System Trace and
   `--time-limit 5s` for Processor Trace. A Metal System Trace of 62 s without a limit was 10.3 GB and never
   finalized; a Processor Trace save failed (exit 17) and the file was gone.
3. **Allocations and Leaks need `xcrun xctrace remodel`** on the trace before `export` (the memory recording
   of 2026-11-05 did): `xcrun xctrace remodel --input ~/traces/x.trace --output ~/traces/x-modelled.trace`
   (check `xctrace help remodel` for the exact options). Delete the unmodelled copy and any large export when
   done.
4. **Power: off the charger, thermal state Nominal.** The iPhone power recording of 2026-11-05 was made
   while charging at thermal state Fair: `DeviceChargingState` covered the whole recording and
   `SystemPowerLevel` was 0 in every row, so it is not a baseline. Check the thermal state first (iPhone: Settings ▸ Developer, or the
   `device-thermal-state-intervals` table of the finished trace; Mac: `pmset -g therm`, `powermetrics
   --samplers thermal -n 1`). A trace taken at thermal state Fair or worse is not a baseline. On the iPhone
   record wirelessly or use an on-device Performance Trace. Mac: `sudo powermetrics --samplers tasks
   --show-process-energy -i 1000 -n 60` for the same minute you record.
5. **Mac file recordings: pause ESET.** ESET takes about two cores during builds and may hook file metadata
   writes (`open`, `link`, `utimes`); how much of the Mac's file-syscall cost it is has not been measured.
   Pause it for File Activity recordings, or note that it ran, and write down the load average (`uptime`).
6. **Launch numbers come from the second launch after an install.** The first launch after an install runs
   once-a-day work (the cache walkers `stat` every cached file) that a same-day relaunch skips. Install,
   launch once, quit, then record the launch you compare; record two launches on the same day to see that
   work disappear.
7. **File Activity**: `xcrun xctrace record --template 'File Activity' --instrument os_signpost --time-limit 30s
   --output ~/traces/x.trace --attach <app>`; do the first and then the second open of the same sticker pack
   in the 30 s. On the Mac `sudo fs_usage -w -f filesys -f diskio <app>` counts the syscalls without a trace.

8. **One recorder at a time, and check for holes.** Two `xctrace` instances recording together (`pgrep -l xctrace`)
   share the kernel trace buffers. The Mac GPU recording of 2026-11-05 (`mac-gpu-152949`) has a 13.37 s "Severe
   Hang" at 25.34 s that is not the app: `SystemCPUUsage` is exactly 0 % for every process from 25.35 s to 38.7 s,
   `displayed-surfaces-per-second` is 0, no thread of any process has a sample, and `pmset -g log` shows no sleep.
   After every recording export `SystemCPUUsage` (`xcrun xctrace export --input x.trace --xpath
   '/trace-toc/run[1]/data/table[@schema="SystemCPUUsage"]'`) and look for stretches of 0.0 % longer than 1 s; a
   hang that coincides with one is a hole in the data, not a freeze. Thread states are not in a Time Profiler
   recording: for an off-CPU stall (a microhang whose main-thread CPU is well under 100 %) record System Trace
   together with Hangs, so the blocking reason is on the main thread's timeline.

## Profiling builds

### iPhone (over USB)

`tools/dev/tg device` builds `release_arm64` (`-c opt`, WMO, ThinLTO), signs it with the development
profile and installs it. The development profile grants `get-task-allow = true` (checked in
`bazel-out/ios_arm64-opt-*/bin/Telegram/Telegram_entitlements.entitlements`), and Make.py builds dSYMs
(`--apple_generate_dsym --output_groups=+dsyms`) next to the ipa in `bazel-bin/Telegram/`. That build is the
profiling build; nothing else is needed.

```sh
xcrun xctrace list devices                       # the iPhone's UDID, e.g. 00008150-…
codesign -d --entitlements - <unpacked>/Payload/Telegram.app | grep -A1 get-task-allow   # optional check
```

The next build overwrites `bazel-bin`, so copy the dSYMs you need next to the trace
(`cp -R bazel-bin/Telegram/*.dSYM ~/traces/<name>-dsyms/`). TestFlight builds cannot be attached to; use a
Performance Trace on the device instead (below).

### Mac

`tools/dev/tg build --release` builds the Release configuration (`-O`, WMO, ThinLTO, `-O3` C, dSYM) signed
with Apple Development and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES`, so Xcode adds `get-task-allow`. The
app is `~/.cache/nanogram-macos/DerivedData[-<checkout>]/Build/Products/Release/Nanogram.app`, its dSYM
beside it. Check before recording:

```sh
APP=~/.cache/nanogram-macos/DerivedData-<checkout>/Build/Products/Release/Nanogram.app
codesign -d --entitlements - "$APP" | grep -A1 get-task-allow     # must be true
dwarfdump --uuid "$APP/Contents/MacOS/Nanogram" "$APP.dSYM"         # UUIDs must match
```

A Release build costs ~11 GB of DerivedData and 20+ minutes; build it once and profile many things with it.
The installed `/Applications/Nanogram.app` (Developer ID, hardened, no `get-task-allow`) can only be sampled
with `--all-processes`, and only with Time Profiler, System Trace or Hangs.

PerfLab (`docs/perflab/README.md`, Mac only) runs in the Debug app today; its numbers are for A/B within one
configuration, not absolute.

## Which template for which complaint

| Complaint | Template (`--template`) | Add (`--instrument`) | Then |
|---|---|---|---|
| Chat opens slowly, any "tap → screen ready" latency | `Time Profiler` | `os_signpost` | `chatOpenToReady` / `navigationPushToReady` interval, main thread call tree in that range |
| UI freezes (hang, ≥250 ms; microhang ≥100 ms) | `Time Profiler` (has Hangs + Points of Interest) | `os_signpost` | `xctrace triage --style hangs`; if the main thread is idle during the hang, re-record with `System Trace` |
| Freeze with low CPU (blocked on lock, file, IPC) | `System Trace` | `os_signpost` | thread states, syscalls, off-core time in the Inspector |
| Scroll / animation stutter | `Animation Hitches` (device for iOS; simulator frame pacing is the Mac's) | `os_signpost` | hitch list, commit vs render phase; Mac: also WindowServer |
| Slow launch | `App Launch` (5 s profile, dyld, thread states) | | `tools/dev/orderfile.py` already drives this template |
| Swift Concurrency stalls, actor contention | `Swift Concurrency` (includes Time Profiler and Swift Executors) | | Main Actor lane, tasks waiting on actors |
| CPU heavy but no obvious hot spot | `CPU Profiler` (cycle-based, stable across P/E cores) or `Processor Trace` (every call, M4 Mac / iPhone 16+) | | Top Functions; `CPU Counters` for "why is this loop slow" |
| Disk writes (Organizer/MetricKit `logicalDiskWrites`, SSD wear) | `File Activity` | `os_signpost` | writes by path and stack; Mac also `sudo fs_usage -w -f diskio Nanogram` |
| Battery (iPhone) | `Power Profiler` (iOS/iPadOS 26+ only) | `CPU Profiler` or `Network Connections` | per-subsystem power impact lanes; record wirelessly or on device, cable charging shows system power 0 |
| Battery (Mac) | `Time Profiler` with context-switch sampling, `System Trace` for wakeups | | `sudo powermetrics --samplers tasks --show-process-energy -i 1000 -n 30`; Activity Monitor Energy |
| Memory growth | `Allocations` (launch it for full history) / `Leaks` | | mark generations around the action; Mac: `footprint Nanogram`, `vmmap --summary`, `leaks Nanogram --outputGraph=~/traces/x.memgraph` |
| GPU / compositing | `Metal System Trace` (call video, Metal views); `Animation Hitches` for Core Animation | | Mac: WindowServer and GPU columns |
| Network | `Network` | | connections and HTTP traffic per process |

Hang thresholds are recording options. Print a template's options as JSON, edit, pass them back:

```sh
xcrun xctrace record --template 'Time Profiler' --show-recording-options > ~/traces/tp-options.json
# set "Hangs": {"hangsThreshold": 100} for microhangs, "Time Profiler": {"highFrequencySampling": true} for short bursts
xcrun xctrace record --template 'Time Profiler' --recording-options ~/traces/tp-options.json …
```

## Recording

### Mac

```sh
mkdir -p ~/traces
# Attach to a running profiling build; reproduce during the 30 s.
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --time-limit 30s \
  --output ~/traces/mac-chatopen.trace --attach Nanogram

# Launch it (cold launch, or anything that needs the whole history, e.g. Allocations).
xcrun xctrace record --template 'App Launch' --time-limit 8s --output ~/traces/mac-launch.trace \
  --launch -- "$APP/Contents/MacOS/Nanogram"

# A hang that happens "sometimes": ring buffer, keep the last 60 s, stop with Ctrl-C right after it.
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --window 60s \
  --output ~/traces/mac-rare-hang.trace --attach Nanogram

# The shipped direct edition (no get-task-allow): sample everything, look at Nanogram afterwards.
xcrun xctrace record --template 'Time Profiler' --all-processes --time-limit 20s --output ~/traces/mac-shipped.trace
```

Quit any Xcode debug session of the app first. Leave the Mac alone while recording; a build next to it
(and ESET, which takes about two cores during builds) changes the numbers.

### iPhone over USB

```sh
DEV=00008150-001A2D1C34C1401C          # from `xcrun xctrace list devices`
xcrun xctrace record --device "$DEV" --template 'Time Profiler' --instrument os_signpost --time-limit 30s \
  --output ~/traces/ios-chatopen.trace --attach Telegram
xcrun xctrace record --device "$DEV" --template 'Animation Hitches' --time-limit 20s \
  --output ~/traces/ios-scroll.trace --attach Telegram
xcrun xctrace record --device "$DEV" --template 'Power Profiler' --time-limit 120s \
  --output ~/traces/ios-power.trace --attach Telegram
# Cold launch: launch by bundle id (verify the bundle id `tg device` printed).
xcrun xctrace record --device "$DEV" --template 'App Launch' --time-limit 8s \
  --output ~/traces/ios-launch.trace --launch -- <bundle id>
```

The iOS executable is `Telegram` whatever the display name. Unlock the phone and keep it awake.

### On the iPhone without a Mac (also works for testers on TestFlight)

Settings ▸ Developer ▸ Performance Trace (Developer Mode on): turn it on, pick the mode (Power Profiler for
battery), switch on our app, add the Performance Trace control to Control Center. Tap to start, reproduce, tap
to stop (up to 10 h). Share the trace from the same settings page; it arrives as an `.atrc`, which every
`xctrace` command below reads directly. On-device hang detection (Settings ▸ Developer) shows a notification
when a hang happens while you use the phone.

## Reading a trace without the Instruments window

Xcode 27's `xctrace` reads traces as text, which is what an agent should use:

```sh
xcrun xctrace toc ~/traces/mac-chatopen.trace                    # tracks and their details
xcrun xctrace triage ~/traces/mac-chatopen.trace --style hangs --format markdown --limit 10
xcrun xctrace show ~/traces/mac-chatopen.trace --track 'Time Profiler' --calltree 'Profile' \
  --time-start 2s --duration 800ms --function invert-calltree
xcrun xctrace list tracks --input ~/traces/mac-chatopen.trace --type 'Process/Thread'   # thread track paths
xcrun xctrace export --input ~/traces/mac-chatopen.trace --toc   # table schemas for --xpath export
```

`triage` needs Hangs and Time Profiler in the trace (the Time Profiler, System Trace and Animation Hitches
templates have both; CPU Profiler has Hangs but not Time Profiler) and reports, longest first, what the main thread did during each hang.
Use the signpost interval's start and duration from the `os_signpost` track for `--time-start`/`--duration`
so before/after traces cover the same work. In the Instruments window, Instruments 27 adds Top Functions
(merge a function across all call paths) and Run Comparisons (per-function deltas, baseline vs candidate,
filtered to the same signpost interval): record both builds with `--append-run --run-name before|after` into
one file to compare them there.

## Symbolication

Instruments finds dSYMs through Spotlight, which does not index Bazel's output or the build caches. Give them
explicitly:

```sh
# iPhone dev build: the dSYMs of the build that is on the phone
xcrun xctrace symbolicate --input ~/traces/ios-chatopen.trace --dsym ~/traces/ios-chatopen-dsyms
# TestFlight build N: tg testflight archived its dSYMs (zipped) by build number
mkdir -p ~/traces/dsyms-N && for z in ~/Library/Application\ Support/Nanogram/dsyms/N/*.dSYM.zip; do unzip -qo "$z" -d ~/traces/dsyms-N; done
xcrun xctrace import --input ~/traces/ios-tf.atrc --output ~/traces/ios-tf.trace
xcrun xctrace symbolicate --input ~/traces/ios-tf.trace --dsym ~/traces/dsyms-N
# Mac Release build / direct archive
xcrun xctrace symbolicate --input ~/traces/mac-shipped.trace --dsym build-output/direct/<build>/Nanogram.xcarchive/dSYMs
```

A dSYM only symbolicates the binary with the same UUID (`dwarfdump --uuid`). iOS has one per binary: the app,
`TelegramUIFramework`, `TelegramCoreFramework`, `PostboxFramework`, `SwiftSignalKitFramework`,
`MtProtoKitFramework` and each extension; pass the directory so all of them are found. In the window: File ▸ Symbols ▸ Add Folder of dSYMs.

## Signposts

Both apps use one set of signposts from the shared core (SwiftSignalKit: `NanogramSignposts`, `UserSignpost`,
`PerformanceSignpostName`, `LaunchTrace`). `PerformanceSignposts` in each app (iOS: `Display`, Mac: `TGUIKit`) is a
typealias of `NanogramSignposts`, so the call sites look the same and the names cannot drift. Subsystem = the
bundle id.

**User-level intervals** (at most 6; emitted in category `Performance` **and** in `.pointsOfInterest`, so they show
in every Instruments template and give Run Comparisons a range):

| Interval | Starts | Ends | iOS | Mac |
|---|---|---|---|---|
| `launchToChatListReady` | `LaunchTrace.begin()` first thing in `didFinishLaunching` | the main window shows the chat list (`LaunchPhase.firstFrame`) | AppDelegate (begin, "Launch to ready") | AppDelegate (begin), ChatListController first applied transition |
| `chatOpenToReady` | tap on a chat | first messages drawn | SharedAccountContext.navigateToChatController, ChatHistoryListNode first ready | ChatController init, `ready` |
| `navigationPushToReady` | a push is requested | iOS: the push completed; Mac: the pushed screen is ready | NavigationController.pushViewController | NavigationViewController.push |
| `chatListFirstFrame` | a chat list is created | its first rows are applied | ChatListControllerImpl.init, ChatListNode first ready | ChatListController init, first transition |
| `chatListFolderSwitch` | a folder is selected | its list is applied | ChatListContainerNode.switchToFilter | ChatListController (cached or live path) |
| `callConnect` | outgoing call tap / incoming answer | the call is connected | PresentationCallManager.requestCall, PresentationCall.answer, `.connected` | PCallSession init (outgoing) / acceptCallSession, `.connected` |

**Hot paths** (category `Performance` only; can run per frame or keystroke): `chatHistoryEntriesForView`,
`chatListPrepareEntries`, `composerKeystroke` (iOS) / `composerTextDidChange` (Mac), `tableMerge`,
`lottieRenderFrame`. Plus `WAL checkpoint` (its own log in Postbox, shared core). Added for the proofs of the
second performance wave: `chatControllerCreated` / `chatControllerDeinit` (events, Mac; unmatched creations show a
leak), `panelScrollTick`, `mouseMovedDispatch`, `modalOpenToVisible` (Mac), `launchToChatListUsable`,
`resumeToFirstFrame`, `vp9ResumeCatchUp` (the replay after a hardware VP9 decoder is set up again) and
`mediaBoxReopen` (event: a media file had to be opened again after its handle was evicted; Postbox also logs
the open and re-open counts once a minute). Chat open on iOS, three events in order: `chatListRowTap` (the chat list
row is tapped, `ChatListController` `peerSelected`), `navigationPush` (`NavigationController.pushViewController`)
and `historyFirstContent` (the first history transition with entries is applied, `ChatHistoryListNodeImpl`, once per
chat node). Events use `NanogramSignposts.event(name)`.

Category `Performance` is **not** shown by the Points of Interest instrument that the Time Profiler, System
Trace, CPU Profiler, Processor Trace and Allocations templates carry (Animation Hitches has none); add
`--instrument os_signpost` to see it, or look at the user-level intervals, which are in both.

API (identical on both apps): `PerformanceSignposts.interval(name) { }`, `begin(name)` / `end(name, state)`,
`OneShot(name)` (ended once from any thread), and for an interval whose start and end are in different modules
`beginPending(.userSignpost)` / `endPending(.userSignpost)` (one open interval per name; beginning again closes the
previous one; ending without a begin does nothing). Rules: names are `StaticString` constants from the core, never
literals at the call site; begin and end on the same signposter; one interval per user action, not per frame, in
Points of Interest; **no metadata at all** (the API has none: no ids, names or text; if one is ever added it is a
count or a hashed id, never a name or message text). When nothing records, an interval costs one enabled check per
signposter. To add a user-level interval, add it to `UserSignpost.all` (the test caps the list at 6) and to the
table above.

`XCTOSSignpostMetric(subsystem:category:name:)` measures the same intervals in UI tests (below).

## Tests that measure

XCTest performance tests (`measure(metrics:options:block:)`) take `XCTClockMetric`, `XCTCPUMetric`,
`XCTMemoryMetric`, `XCTStorageMetric` (bytes written), `XCTOSSignpostMetric` (one of our intervals), and in UI
tests `XCTApplicationLaunchMetric(waitUntilResponsive: true)` and `XCTHitchMetric(application:)` (Xcode 26+,
iOS and macOS). Xcode keeps baselines in `xcshareddata/xcbaselines` per machine, which neither Bazel nor
`swift test` reads, so ours are in the repo: `tools/dev/perf/baselines.json`, keyed by machine model
(`sysctl hw.model`), compared by `tools/dev/perfgate.py`. Run performance tests with code coverage and
sanitizers off, Release where the runner allows it, nothing else running.

### The tests

Pure, deterministic hot paths that need no app and no account. Each measures `XCTClockMetric`, `XCTCPUMetric`
and `XCTMemoryMetric` over 5 to 10 iterations, and is skipped unless `TG_PERF=1` (so normal test runs stay fast
and free of timing noise).

| Test | What | iOS / core target | Mac target |
|---|---|---|---|
| `PostboxReadPerformanceTests` | read the newest 2500 of 10000 messages of a chat from an in-memory database | `submodules/Postbox/Tests` (SwiftPM `swift test`, Bazel `PostboxTests`) | the same, through the core pin: `submodules/telegram-ios/submodules/Postbox` |
| `ChatListDiffPerformanceTests` | diff of a 10000-row chat list after an update (`mergeListsStableWithUpdates`) | `ChatListUITests` (Bazel) | `TGUIKitPerformanceTests.testDiffChatListAfterAnUpdate` (`swift test` in `packages/TGUIKit`) |
| `TextLayoutPerformanceTests` | layout of a 48,000-character message | `DisplayTests` (Bazel, `TextNode`) | `TGUIKitPerformanceTests.testLayoutLongMessage` (`TextViewLayout`) |
| `SyntaxHighlightPerformanceTests` | libprisma highlighting of a 2400-line Swift block | `TextFormatTests` (Bazel) | none: the Mac has no test target around libprisma yet (it compiles the same copy; see `CodeSyntax`) |

### Running them

- `tools/dev/tg perf run` runs the SwiftPM ones on this machine (iOS: Postbox; Mac: TGUIKit and the core's
  Postbox), then compares with the baselines. `--package DIR` picks other packages.
- The Bazel `ios_unit_test` ones (ChatListUITests, DisplayTests, TextFormatTests) run on the simulator, which
  reports the host Mac's `hw.model`; run them with `TG_PERF=1` in the test environment and give the log
  to `tools/dev/tg perf check --log bazel-testlogs/.../test.log --suite ios-sim`. On an iPhone, run the same
  tests from Xcode and give the result bundle: `tg perf check --xcresult X.xcresult --suite iphone --model iPhone18,2`.
- Nothing here is in `tg check` or the pre-push hook yet; a wall-clock gate would flake until the baselines
  have a few runs behind them.

### perfgate (`tools/dev/perfgate.py`, pure Python, tests in `tools/dev/tests/test_perfgate.py`)

- Input: the XCTest log lines (`Test Case '-[C t]' measured [Time, seconds] average: ..., values: [...]`, from
  `swift test`, `xcodebuild` and Bazel `test.log`), a result bundle (`--xcresult`, read with
  `xcrun xcresulttool get test-results metrics`), or JSON (that tool's output, or `{"measurements": [...]}`).
- Key: `<suite>/<Class.test>/<metric id>` under the machine model. `--suite` keeps the same test of different
  bundles apart (`swift-host` is the default of `tg perf run`).
- Baselines: `tools/dev/perf/baselines.json`, `owner_models` = `Mac16,1` (MacBook Pro M4) and `iPhone18,2`
  (iPhone 17 Pro Max). **Only owner devices get stored baselines.** Other machines are compared when a baseline
  for their model exists, otherwise skipped.
- A missing baseline is recorded (on an owner device, with a note to commit the file), never a failure.
- A regression is a measured average more than `--tolerance` percent (15) above the baseline and also more than
  the unit's absolute floor (0.5 ms, 256 kB, 500 kC/kI), so noise on tiny numbers cannot fail. A baseline entry can
  carry its own `tolerance_percent`. Improvements are reported, not stored (`record` rewrites baselines).
- Exit: 0 pass, 1 regression, 2 no measurements or unreadable input.
- Re-baselining after an intended change: `tg perf run`, then `tg perf record` with the same input on the owner
  device and commit `baselines.json` with the change that moved the numbers.

## Checkers while developing

Xcode turns on Main Thread Checker and Thread Performance Checker (priority inversions, I/O on the main
thread) for the Run action unless a scheme disables them (`disableMainThreadChecker`,
`disablePerformanceAntipatternChecker`); neither our Mac schemes nor rules_xcodeproj's iOS project do.
They do not run when the app is started outside Xcode (`tg run` on iOS, `open` on the Mac) or in `swift test`.
Main Thread Checker can be injected there: `DYLD_INSERT_LIBRARIES=$(xcode-select -p)/usr/lib/libMainThreadChecker.dylib`
(Mac; `MTC_CRASH_ON_REPORT=1` to stop at the first report). In test plans, Runtime API Checking can report
these as failures instead of warnings.

## Field data

- **MetricKit**: both apps collect reports locally (`MetricManager` on iOS/macOS 27, `MXMetricManager`
  before) and export them from Debug Settings; nothing is uploaded. macOS 26+ now gets daily metric reports,
  not only diagnostics. The direct Mac edition has no Organizer data, so MetricKit is its only field source.
- **Xcode Organizer** (App Store Connect builds): hang rate (iOS, macOS), hitches (iOS), disk writes, launch,
  memory, battery, storage; Xcode 27 adds metric goals and an insights overview, and "Generate
  Recommendations" on a hang/disk-write/launch report.
- **Launch tasks** (iOS/macOS 27 only, `if #available`): `LaunchTrace` in the shared core adopts
  `MetricManager.trackLaunchTask(id:onTrackingError:_:)`, which brackets an operation and extends the launch
  measurement until the tasks end. Three tasks open together in `didFinishLaunching` (the first must start
  there; the rest before the last one ends) and each ends where its phase finishes: `account-load` (the account
  context exists), `chat-list-first-data` (the chat list applied its first rows) and `first-frame` (the window
  shows the chat list; also ends the `launchToChatListReady` interval). They show up in the MetricKit launch
  metrics that both apps already store locally; nothing is sent anywhere. A tracking error (for example the task
  started past the deadline) is logged as the task id and the reason code only. Older systems do nothing.
- **Not used yet**: `StateReporting` (iOS/macOS 27: which screen/mode a metric came from; also shows in
  Points of Interest), `MetricManager.logHandle(category:)` (signposts that MetricKit aggregates per day).
- **Mac hang forensics**: `sudo spindump Nanogram 10 -o ~/traces/` samples every thread for 10 s; `tailspin`
  is off by default (`tailspin info`), and `sudo tailspin save -o ~/traces/x.tailspin` only has data while it
  is enabled.

## Known gaps (2026-11-05)

- Mac `Telegram` scheme: Profile action uses the Debug configuration and Run's `CA_DEBUG_TRANSACTIONS=1`
  (`shouldUseLaunchSchemeArgsEnv = YES`). Product ▸ Profile therefore measures `-Onone` with transaction
  backtraces.
- The performance tests exist (above) but no baselines are recorded yet: the first `tg perf run` on `Mac16,1`
  and the first iPhone 17 Pro Max run record them. No UI performance tests (they need a signed-in test account).
- Core signposts for Postbox transactions and account updates are not added.
- PerfLab runs Debug only.

## References

- WWDC26 268 "Profile, fix, and verify: Improve app responsiveness with Instruments" (Top Functions, Run
  Comparisons, Inspector, Swift Executors; profile Release; signpost the interval you compare).
- WWDC26 222 "Meet the new MetricKit" (`MetricManager`, `StateReporting`); WWDC26 258 "What's new in Xcode 27"
  (Organizer goals, insights, Generate Recommendations, Hitches metric).
- WWDC25 308 "Optimize CPU performance with Instruments" (CPU Profiler, Processor Trace, CPU Counters);
  WWDC25 226 "Profile and optimize power usage in your app" (Power Profiler); WWDC23 10248 "Analyze hangs with
  Instruments".
- developer.apple.com/documentation/xcode: improving-app-responsiveness, diagnosing-performance-issues-early,
  writing-and-running-performance-tests, analyzing-cpu-usage-with-processor-trace,
  measuring-your-app-s-power-use-with-power-profiler, reducing-disk-writes,
  analyzing-responsiveness-issues-in-your-shipping-app; documentation/metrickit/metricmanager;
  documentation/statereporting.
