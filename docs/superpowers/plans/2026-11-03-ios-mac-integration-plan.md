# Nanogram iOS + macOS: one core, shared caches, one optimization profile

Plan written 2026-11-03 from three read-only investigations (core convergence, cache inventory, release-flag parity).
Nothing was built or changed to write it. Line numbers and sizes are from 2026-11-03; re-check them before starting a task.

- iOS repo: `/Users/klaipher/Projects/Telegram-iOS` (klaipher/nanogram, `main`; upstream import release-13.1.2).
- Mac repo: `/Users/klaipher/Projects/nanogram-macos` (klaipher/nanogram-macos; branches `nanogram/stage1`, `nanogram/runtime`, `nanogram/stage2`).
- Owner goal: "integrate our iOS branches and macOS as closely as possible, so they use the same caches and maximum build optimizations."

---

## 1. Summary for the owner

**What will be shared**

1. **One Telegram core.** Today the Mac carries its own copy of the Telegram core, and it has three different versions of it (one per branch). None of them is the iOS core. About 20 of the Mac's 41 core commits re-do fixes that iOS already has. After this plan, the Mac's `submodules/telegram-ios` *is* the iOS repo (`klaipher/nanogram`, branch `main`):
   - A core fix is written once and both apps get it.
   - The Mac immediately gains about 17 iOS core fixes it lacks today: VACUUM self-heal, lazy Postbox open, server-value clamps, faster uploads and downloads, media-reader handle reuse, MPEG-4 Part 2 GIFs, the Network.framework keepalive, the FFmpeg VideoToolbox colour patch, FlatBuffers 25.12.19, rnnoise 0.2, ogg 1.3.6 and others.
   - iOS gains about 8 Mac-originated fixes: ThreadPool QoS, the history-preload fix, VUI and colour fixes, Ogg Opus continuity, and the translation fallback.
2. **One Git object store.** All checkouts of the core share one local object store: iOS, the Mac main checkout and every Mac worktree.
3. **One Xcode compile cache** for every Mac checkout. It is path-independent, so a new worktree or a branch switch reuses compiled work. The Mac's Rust build directories are also shared between Mac checkouts.
4. **One version list and one flag profile** for the native libraries (FFmpeg, opus, libvpx, libwebp, dav1d, jpeg, Rust engines, WebRTC flags). A check fails if either app drifts from it. Where it is technically possible, the Mac builds its native libraries with the **same Bazel scripts and the same Bazel disk cache** as iOS. This is a spike with a clear go/no-go rule.
5. **One disk budget and one cleanup command** that sees both apps' caches.

**What cannot be shared, and why** (details in section 5)

Compiled output cannot cross between the apps. iOS builds for `arm64-apple-ios` with Bazel; the Mac builds for `arm64-apple-macos` with Xcode/SwiftPM. Their objects, Swift modules, LTO bitcode and cache formats (Bazel REAPI vs Xcode's LLVM CAS) are incompatible, even when the source is identical. Sharing therefore happens at the level of **source, versions, flags, git objects and tools**, plus the Bazel disk cache *if* the Mac's native libraries go through Bazel.

**Expected gains** (estimates unless marked "measured")

| Area | Today | After |
|---|---|---|
| Free disk | 16 GiB (97% full; measured) | about +50 GB from cleanup, then a steady budget of about 80 GB for both apps instead of about 150 GB |
| Git storage for the core | ≈6.1 GB (4 full-history clones) + 3.0 GB `tgios-work` | ≈0.4 GB |
| Mac native-lib rebuilds | once per worktree (worktrees have different FFmpeg pins) | once per core bump. A cold build is 777 s idle / 1,522 s loaded (measured). If the Bazel spike passes, about 724 s of that becomes shared-cache hits |
| Mac clean Debug build in a 2nd worktree or after a branch switch | 401 s idle / 792 s loaded (measured) | about 100–150 s with the shared Xcode CAS (to be measured; adopted only if it wins) |
| iOS builds after cache GC | can fail with `REMOTE_CACHE_EVICTED` | an evicted blob becomes a cache miss, never a failure |
| iOS repeat release links | full ThinLTO backend every time | incremental LTO cache, as the Mac already has |
| Core porting work | 41 Mac core commits re-port iOS work | about 15 commits + 3 extras land once; no more ports |
| App speed (Mac) | opus fixed-point C, libwebp `-Os`, no VideoToolbox colour patch, WebRTC without LTO | iOS parity: opus float + NEON, libwebp `-O3`, VT patch, ThinLTO on WebRTC, tde2e and OpenSSL |

---

## 2. Target end state

```
GitHub (private, no Telegram history anywhere — owner rule)
  klaipher/nanogram                      <- THE core (iOS app + shared Telegram core)
    main ..................... iOS app + all core fixes from both apps; Mac-only code under #if os(macOS);
                               Mac SwiftPM manifests/test targets/SharedHeaders live here too (iOS Bazel ignores them)
    upstream ................. history-free Telegram-iOS release imports (as today)
    mac/core-legacy .......... archive: old Mac core commits re-parented onto b46f1ec6 (read-only after Phase 2)
  klaipher/nanogram-macos               <- Mac app
    main ..................... merged stage1+runtime+stage2
    .gitmodules: submodules/telegram-ios -> https://github.com/klaipher/nanogram.git, branch = main
                 pin = a verified commit on nanogram main's first-parent history
  klaipher/tgcalls, klaipher/rlottie     one fork each; iOS branch telegram-ios-dev is an ancestor of nanogram-mac
                                         -> keep merging telegram-ios-dev into nanogram-mac

Local disk (one APFS volume)
  ~/.cache/nanogram/                         NEW shared root
    git/github.com/klaipher/<repo>.git       bare "lender" mirrors (gc.pruneExpire=never, gc.auto=0)
                                             borrowers via objects/info/alternates: Telegram-iOS/.git,
                                             every Mac .git/modules/... and .git/worktrees/*/modules/...
    xcode-cas/                               COMPILATION_CACHE_CAS_PATH for all Mac checkouts (+ iOS watch xcodebuild), cap 10G
    cargo-target/<lib>/<rustc -V>-aarch64-apple-darwin/   shared CARGO_TARGET_DIR for Mac checkouts
  ~/.cache/telegram-ios/bazel-disk-cache     unchanged path; iOS Bazel + (if spike passes) Mac native libs; cap 30G
  ~/Library/Caches/bazel                     iOS output base + repo cache, unchanged path
  ~/.cache/nanogram-macos/{DerivedData*,frameworks,spm-*}   unchanged paths (stage2 caps/rules)
  Budget: Bazel disk 30G, Bazel output base ~25G, Xcode CAS 10G, Mac DerivedData per stage2 rules,
          fwcache 3G, SwiftPM scratch 10G, cargo targets ~1G  -> ~80 GB total
  One inventory: Mac `tools/dev/tg prune --dry-run` reports every item above (iOS items read-only)

Versions and flags
  klaipher/nanogram: build-system/nanogram-deps.toml
    per dependency: version, source (commit / tarball sha256), local patches,
    configure profile = common + ios + macos overrides
  checked by `tools/dev/tg check` (Mac) and `tools/dev/tg lint` (iOS) and both pre-push hooks

Release optimization profile (both apps)
  Swift: -O, WMO, default CMO              C/ObjC/C++: ThinLTO everywhere (incl. Mac tg_owt, tde2e, OpenSSL)
  dead strip + symbol strip + dSYM          ThinLTO incremental cache on both (iOS: -cache_path_lto)
  Rust: opt3 (wallet opt-z), cgu1, panic=abort, same LTO mode on both, one std copy per binary (verified)
  opus float + intrinsics, libwebp -O3, libvpx realtime-only + runtime CPU detect, one FFmpeg configure list
  exclusivity: one measured rule for both apps
```

---

## 3. Phases

**Gates**
- **(a)** the Mac merge of stage1 + runtime + stage2 is done;
- **(b)** the round-2 fix phase is done (`2026-11-03-macos-round2-specs.md`);
- **(c)** the .dmg is built from the merged Mac.

**Lanes for parallel work**
- Owner preference: parallel agents in one checkout, few worktrees.
- Agents may run in parallel in one checkout when they edit **disjoint files**.
- Only one agent per checkout runs `git commit`, `git rebase` and `git merge`: the "integrator". The others hand it their edits.
- **Only one heavy build runs on the machine at a time.** Use stage2's build lock, and never start a build while another workflow is building.
- Lane tags: `[iOS]` = Telegram-iOS checkout, `[MAC]` = nanogram-macos main checkout, `[MACHINE]` = caches and config outside both repos.

### Phase 0 — now, independent of (a)/(b)/(c)

| Task | Lane | Parallel? |
|---|---|---|
| 0.1 Disk reclaim | MACHINE | yes |
| 0.2 iOS downloads all outputs | iOS | yes, with 0.3 (different file) |
| 0.3 iOS ThinLTO link cache | iOS | yes, with 0.2 |
| 0.4 Fix the stale iOS submodule config | iOS | yes |
| 0.5 Round-2 commit rule | process | — |

**0.1 Reclaim disk (needs owner OK).**
- Delete:
  - `~/Projects/nanogram-macos-recon/dd-debug` and `dd-release`. Keep `src/` and the logs: they are the baseline.
  - `~/.cache/nanogram-macos/DerivedData-runtime-12`.
  - The `~/.cache/nanogram-macos/spm-*` scratch dirs that `tools/dev/tg prune --dry-run` (stage2 checkout) marks over the cap.
  - Old `java.log.*` files in the Bazel output base.
- Steps:
  1. `tools/dev/tg prune --dry-run` in `~/Projects/nanogram-macos-stage2`.
  2. Delete only whole units that no build lock holds: `lsof +D <dir>` must be empty.
  3. Never touch anything inside `bazel-disk-cache`.
- Verify: `df -h ~` shows at least +45 GB free. Expected: 17 + 6.7 + about 22 + 0.25 ≈ 46 GB.
- Rollback: none needed. These are rebuildable outputs.
- **Prerequisite for 4.2 (needs at least 30 GB free).**

**0.2 iOS: every Bazel build downloads all outputs; Bazel's GC is the only thing that deletes cache entries.**
- Files:
  - `/Users/klaipher/Projects/Telegram-iOS/.bazelrc`: lines 41–42. Add `common --remote_download_outputs=all` and set `--experimental_disk_cache_gc_max_size=30G`.
  - `tools/dev/tg`: lines 24, 151 and 440. Remove `DEVICE_DOWNLOAD_OUTPUTS`; it is now redundant.
  - Doc line in CLAUDE.md: "nothing but Bazel deletes inside the disk cache".
- Verify:
  1. `tools/dev/tg build` twice (simulator): the second run is a no-op.
  2. Switch to a commit 20 back and run `tools/dev/tg build`: no `Missing digest` / `REMOTE_CACHE_EVICTED`.
  3. `du -sh ~/.cache/telegram-ios/bazel-disk-cache` settles at ≤30G after the idle GC (5 min).
- Expected: the simulator output base grows by a few GB; the disk cache shrinks by about 15 GB.
- Rollback: revert the commit.
- Run when no iOS Bazel build is active.

**0.3 iOS: ThinLTO incremental cache for release links.**
- File: `build-system/Make/Make.py` (`common_release_args`, lines 93–116). Add:
  - `--linkopt=-Wl,-cache_path_lto,<HOME>/.cache/telegram-ios/lto-cache`
  - `--linkopt=-Wl,-prune_after_lto,1209600`
  - `--linkopt=-Wl,-prune_interval_lto,3600`

  Expand `<HOME>` in Python; Bazel does not expand `~`.
- Verify:
  1. Run `tools/dev/tg build --release --device` twice, with a one-line Swift change in between.
  2. Compare the `ObjcLink`/`AppleLink` action times in `--profile`. Expected: the second link is clearly shorter. Not measured yet; reject if under 20%.
- Rollback: revert the commit and `rm -rf ~/.cache/telegram-ios/lto-cache`.
- Run when no other build is active (release builds are heavy).

**0.4 iOS: fix the stale submodule config** before any alternates work.
- Problem: `.git/modules/third-party/wallet-engine` has `core.worktree` pointing at the deleted `../nanogram-release/...`.
- Fix: `git config -f .git/modules/third-party/wallet-engine/config core.worktree ../../../../third-party/wallet-engine/wallet-engine`. Verify the relative depth first.
- Verify: `git -C third-party/wallet-engine/wallet-engine status` works.

**0.5 Rule for round 2 (gate b), so its core work lands once.**
- Every round-2 fix under `submodules/telegram-ios` (db, MediaPlayer and FFmpeg specs) is its own commit. It touches only core paths and its subject starts `core:`.
- If iOS main already has the fix, cherry-pick the iOS commit instead of re-writing it (the round-2 spec already says so).
- If a round-2 fix is cross-platform and iOS lacks it, commit it **first on iOS main** (`[iOS]` lane, `tools/dev/tg test` for that module), then cherry-pick it to the Mac core branch. This stops the residual from growing.

### Phase 1 — after (a): archive the Mac core in klaipher/nanogram `[iOS]`

**1.1 One Mac core branch.**
- Gate (a) must leave the merged Mac on **one** core pin, with FFmpeg 9.0.2 and without the ffmpeg-8.1.2 hunk.
- If the merge left `nanogram-mac` (96fe36b2) and `nanogram-mac-runtime` (b504f7ed) separate, merge them on the Mac core branch: take 9.0.2, drop the `ffmpeg-8.1.2/` videotoolbox hunk, keep both branches' other commits.
- Verify: `tools/dev/tg frameworks && tools/dev/tg build` in the merged Mac checkout. This is part of gate (a) anyway.

**1.2 Re-parent onto the history-free root and push.**
1. In the iOS repo, fetch the merged Mac core tip from the Mac submodule gitdir into a local ref.
2. Confirm `git rev-parse fb0e62ba^{tree}` equals `git rev-parse b46f1ec6^{tree}` (expected `b148f027`).
3. Run `git rebase --onto b46f1ec6 fb0e62ba <ref>`. With identical trees this has zero conflicts.
4. Push as `mac/core-legacy`.

Verify:
- `git merge-base --is-ancestor b46f1ec6 mac/core-legacy`
- `git diff <old Mac tip> mac/core-legacy` is empty
- `git log --format=%H mac/core-legacy | wc -l` = 1 + (number of Mac core commits). This shows that no Telegram history was pushed.

Rollback: delete the remote branch. Effort: S. It can run in parallel with round 2, because it touches only refs.

### Phase 2 — after (b): land the Mac residual on iOS main `[iOS]`

Branch `mac/core-on-main` from iOS `main`.

**2.1 Check the dropped ports for hidden extras** before dropping them. This task only reads.
- For each of M1 20b106b5, M2 8d359ea9, M3 3ec2f146, M4 3bb3fb4c, M5 d985e78b, M9 0319e83c, M10 10e47fed, M16 09ee786e, Q1 2955fe5b, M25 5320676c, H2 1e9c875e, M21 1140dbe9, M28 0ff43154, M24 57511883, M8 867d5c5a, H14 b504f7ed and the 6 stage1 cherry-picks: diff its files on `mac/core-legacy` against iOS `main`.
- Anything that is not on main becomes an "extra" commit. Watch M2 and M9 in particular.
- Output: a list in the PR description.

**2.2 Replay the keep list**, oldest first, with `git cherry-pick -x` from `mac/core-legacy`.
- Apply cleanly:
  - H13 df65bdef (ThreadPool QoS)
  - M26 19875d3b (preload stops replaying)
  - Q13 3afe194f (passthrough VUI colour)
  - H18 b0266028 (translation falls back to the server)
  - Q2 b23b0048 + be35974f (Ogg Opus continuity + tests)
  - 3a11ddd9 (M3 tests)
  - H20 0b40f538 (48 kHz, `#if os(macOS)`)
  - cc304dc1, 4801963b, 806e4b0b (Package.swift part only), the M16 SwiftPM test target and RangeSetBenchmarkTests
  - b19bfe92 (MetalEngine Package.swift shader fix)
  - the TdBinding SharedHeaders regenerated for 1.8.69
- Need manual merges (about 7):
  - H22 be32188c (SoftwareVideoSource vs 13.1.2)
  - Q7 0a053b60 (MediaDataReader vs 13.1.2)
  - H5 extras from 1aef8d8e: `GifTileHardwareDecoding`/`HardwareDecoderSlot` on top of iOS `HardwareDecoderBudget`
  - 54151f18 (depends on H5)
  - H7 extra `isExpensive`
  - M27 extra `HardwareColorAttachments.swift` plus the cached description
  - H3 a001272d (see 2.4)
- Plus any round-2 `core:` commits that are not yet on main (rule 0.5).
- Parallel split, one checkout, disjoint directories:
  - Agent A: Postbox, TelegramCore, MtProtoKit, SSignalKit, Utils.
  - Agent B: MediaPlayer, FFMpegBinding, YuvConversion, OpusBinding, TelegramAudio, MetalEngine, td.
  - The integrator commits.

**2.3 Keep Mac-only tests out of iOS Bazel.**
- The iOS BUILD files of Postbox, TelegramCore, MediaPlayer and MtProtoKit glob `Tests/**`.
- Wrap Mac-only tests (MediaPlayerAudioFormatTests 48 kHz and any test using AppKit or macOS-only API) in `#if os(macOS)`.
- Add `ChunkMediaPlayerV2BackgroundTests.swift` to the MediaPlayer test-target `exclude:` in `submodules/MediaPlayer/Package.swift`.

**2.4 One network-availability implementation.**
- Make H3's `nw_path_monitor` the implementation on both platforms. It replaces the shared 5 s SCNetworkReachability poll from iOS 3d30de4c.
- Keep the poll path as a fallback, behind one flag, for one release.
- Verify on an iPhone: Wi-Fi ↔ cellular, VPN on/off, Low Data Mode, airplane mode. Run `MTNetworkAvailabilityPollTests` plus the iOS reachability tests.
- Default chosen: cross-platform (see section 4).

**2.5 Guardrail: declared core paths.**
- Agent C, in parallel with 2.2 (different files).
- Add `docs/mac-core-paths.txt` to klaipher/nanogram: the 42-package closure, generated from the Mac `Package.swift` `path:` graph. A script regenerates it in the Mac repo, `tools/dev/nanogram/corepaths.py`, and fails if the committed list differs.
- Add a `tglint.py` rule (`tools/dev/tg lint`): a staged change under those paths that adds `import UIKit`, `UIApplication`, `UIScreen` or `UIDevice` outside `#if os(iOS)`/`canImport(UIKit)` and outside a file the Mac `Package.swift` excludes produces a **warning** that names the file.

**2.6 Verify and land.**
1. iOS:
   - `tools/dev/tg lint`
   - `tools/dev/tg build` (simulator)
   - `tools/dev/tg test <target>` for the Postbox, TelegramCore, MediaPlayer, MtProtoKit and SSignalKit test targets (list them with `build-input/bazel query 'kind(".*_test", //submodules/...)'`)
   - one `tools/dev/tg device` build on a phone: chat list, media playback, a voice message and a call.
2. Mac (in a scratch worktree of the merged Mac, submodule temporarily at `mac/core-on-main`):
   - `swift test` for the core test targets (Postbox, TelegramCore, MediaPlayer, MtProtoKit, OpusBinding, YuvConversion, RangeSet, SwiftSignalKitTesting).
   - Builds wait for Phase 3.
3. Fast-forward iOS `main` to `mac/core-on-main` and push.

Expected: about 15 commits + 3 extras instead of 41.

Rollback: `main` is only fast-forwarded after tests pass. Revert the merge range if a device regression appears.

Effort: M.

### Phase 3 — after (c): point the Mac at the shared core `[MAC]`

The .dmg from gate (c) ships on the old core, and this phase produces the next one. 3.1 and 3.3 touch disjoint files and can run in parallel. 3.2 is serial.

**3.1 Mac build adjustments.** These are the concrete breakages found between iOS main and the current Mac build inputs.
- `scripts/flatc`: 24.12.23 → **25.12.19**.
  - Verify: run `scripts/prepare-flat-serialization.py`, then diff the generated `submodules/telegram-ios/submodules/TelegramCore/FlatSerialization/Sources` against the Bazel-generated copy in the iOS output base (`bazel-bin/submodules/TelegramCore/FlatSerialization/...`). It must be identical.
- `scripts/framework-inputs.sh:21`: drop `submodules/telegram-ios/submodules/openssl` (iOS deleted the directory in 64fc8c95). Also drop the same path from the build-script argument in `core-xprojects/openssl/*.xcodeproj/project.pbxproj`.
- `tools/dev/nanogram/localfixes.py`: remove the MetalEngine patch (b19bfe92 is in main now).
- Call sites of `MediaBox.vacuum()` (it now returns `Bool`): use `_ =` or log the result.
- `*SubmoduleCompatibilityTests` and `tools/tests/no-paid-messages-token`: update them for the 40 rebranded `en.lproj` strings.

**3.2 Repoint the submodule.**
1. `.gitmodules`: set `url = https://github.com/klaipher/nanogram.git` and `branch = main`.
2. Run `git submodule sync --recursive`.
3. Run `git -C submodules/telegram-ios fetch origin main`.
4. Check out the main commit that 2.6 verified.

Pin rule:
- Patch releases: pin the tip of main that a Mac build verified.
- When telegram-macos is still on an older *minor* release than our import: pin the first parent of the `Merge upstream … release-X` commit. For 13.1.2 that is `ac52438a`; not needed for 13.1.2, because its 16 core files changed only internal API.

Commit message: `mac-core: <sha> (upstream release-13.1.2 + N ours)`.

**3.3 New sync model.**
- `tools/dev/nanogram/sync.py`: "bump core" = fetch klaipher/nanogram main → build → test → update the pin.
- `sync-upstream` (telegram-macos):
  - The submodule-pointer conflict always resolves to our pin.
  - If telegram-macos pins a Telegram-iOS release newer than our import, stop and print "import release-X on iOS first (`tools/dev/tg sync-upstream` in Telegram-iOS)".
- Document both in the Mac `CLAUDE.md` and the iOS `CLAUDE.md`.

**3.4 Verify.** Run these in order, one heavy build at a time:
1. `tools/dev/tg frameworks`. FFmpeg, dav1d and td rebuild once because the core tree changed. Expected about 777 s idle / about 1,500 s loaded.
2. `tools/dev/tg build`.
3. `tools/dev/tg test`.
4. `tools/dev/tg check`.
5. `tools/dev/tg build --release`. buildcheck must pass.
6. Launch the app: login screen, then (if an account is available) chat list, media and calls.

Rollback: revert the `.gitmodules` and pin commit. The old pin stays reachable on `mac/core-legacy`.

Effort: S–M.

### Phase 4 — caches (after Phase 3 unless noted)

All Phase 4 tasks touch disjoint files or configs:
- 4.1 is `[MACHINE]` plus git config.
- 4.2 is the Mac xcconfig.
- 4.3 is the Mac build scripts.
- 4.4 is Mac `disk.py`.

They can run as parallel agents. Their measurements cannot overlap: one build at a time.

**4.1 One git object store; skip unused nested submodules.**
1. Create the lender:
   ```
   git clone --bare https://github.com/klaipher/nanogram.git ~/.cache/nanogram/git/github.com/klaipher/nanogram.git
   git -C ~/.cache/nanogram/git/github.com/klaipher/nanogram.git config gc.pruneExpire never
   git -C ~/.cache/nanogram/git/github.com/klaipher/nanogram.git config gc.auto 0
   git -C ~/.cache/nanogram/git/github.com/klaipher/nanogram.git config remote.origin.fetch '+refs/heads/*:refs/heads/*'
   ```
   Do the same for tg_owt, tgcalls, rlottie, td, dav1d, mtproto-engine and wallet-engine.
2. Add borrowers: append `<lender>/objects` to `objects/info/alternates` in:
   - `Telegram-iOS/.git`
   - `nanogram-macos/.git/modules/submodules/telegram-ios`
   - each `nanogram-macos/.git/worktrees/*/modules/submodules/telegram-ios`
   - recon `src/.git/modules/...`

   Then run `git repack -a -d -l` and `git prune` in each borrower.
3. Skip nested submodules the Mac does not use. Set `update=none` in the **Mac's** telegram-ios submodule config (local config, not `.gitmodules`) for:
   - `third-party/webrtc/webrtc`
   - `third-party/libvpx/libvpx`
   - `build-system/bazel-rules/*`

   First confirm they are unused with `grep -r "third-party/webrtc\|third-party/libvpx\|bazel-rules" packages/ Telegram-Mac.xcodeproj core-xprojects scripts`. Fetch the remaining nested submodules with `--depth 1`.
4. Bake steps 1–3 into Mac `tools/dev/tg setup`. Add a `tools/dev/tg doctor` check that every alternates path exists.
5. Delete `~/.cache/nanogram-macos/tgios-work` (3.0 GB).
- Verify:
  - `git fsck --connectivity-only` in every borrower
  - `du -sh` of each gitdir: expected ≈6.1 GB → ≈0.4 GB total
  - `git -C <checkout>/submodules/telegram-ios status` is clean.
- Rollback: in a borrower, `git repack -a -d` (without `-l`) re-inlines the objects; then remove the alternates line.
- Rule: the lender is never pruned or deleted while borrowers exist.

**4.2 One Xcode compilation cache for all Mac checkouts.** This is stage2 Task 10, extended.
- Needs gate (a) and at least 30 GB free (0.1).
- In `nanogram/Nanogram.xcconfig`, add:
  ```
  COMPILATION_CACHE_ENABLE_CACHING[config=Debug] = YES
  COMPILATION_CACHE_CAS_PATH = $(HOME)/.cache/nanogram/xcode-cas
  COMPILATION_CACHE_LIMIT_SIZE = 10G
  CLANG_ENABLE_PREFIX_MAPPING = YES
  SWIFT_ENABLE_PREFIX_MAPPING = YES
  ```
  plus the `*_ENABLE_PROJECT_PREFIX_MAPPING` pair.
- Measure:
  1. A cold `tools/dev/tg build --clean` in checkout A.
  2. `tools/dev/tg build --clean` in checkout B, a different path.
  3. A branch switch in A.
  4. Check that lldb breakpoints in a package file still resolve.
- Adopt if the clean build in B drops by at least 40% from 401 s idle (expected about 100–150 s) **and** `du -sh xcode-cas` stays ≤10G after 5 builds. Otherwise reject: revert and delete the CAS dir.
- If adopted, point the iOS watch xcodebuild (`tools/dev/tg watch`) at the same CAS path.

**4.3 Shared cargo target dirs on the Mac.**
- In the Mac `core-xprojects` build scripts for mtproto-engine, wallet-engine and tlottie, set `CARGO_TARGET_DIR=~/.cache/nanogram/cargo-target/<lib>/<rustc -V hash>-aarch64-apple-darwin`.
- Copy the `.a` into `BUILD_DIR` as today, so fwcache keys and outputs are unchanged.
- Verify: build mtproto-engine in checkout A, then in B. B compiles only the engine crate (`cargo` prints `Fresh` for the dependencies).
- Expected: about 1.6 GB less disk; a second-checkout engine build of about 30–60 s instead of 60–525 s.

**4.4 One inventory and budget.**
- Extend stage2's `tools/dev/nanogram/disk.py` (Mac `tools/dev/tg prune`) with read-only kinds:
  - `bazel-disk-cache`, `bazel-output-base`, `bazel-repo-cache` (iOS)
  - `xcode-cas`, `git-lender`, `cargo-target`
- Rules:
  - Report everything.
  - Delete only whole units: a DerivedData dir, a scratch dir, a fwcache entry, a cargo-target dir whose rustc version no checkout pins.
  - Never delete inside the Bazel disk cache, the Xcode CAS or a git lender. Their own caps handle them.
  - Delete a Bazel output base only after `bazel shutdown`, and never while a build lock is held.
- iOS `tools/dev/tg disk`: print the same budget lines.
- Bazel paths stay where they are. Moving the output base would force a full rebuild for no gain.
- Verify: `tools/dev/tg prune --dry-run` lists every directory from section 2 with its size and cap. The total stays at or under about 80 GB.

### Phase 5 — one optimization profile (after Phase 3; 5.4 and 5.5 can start right after (a))

**5.1 Shared dependency manifest.**
- Add `build-system/nanogram-deps.toml` to klaipher/nanogram. Each entry has:
  - name, version, source (commit or tarball sha256), local patches
  - configure profile `{common, ios, macos}`
- Entries: FFmpeg 9.0.2 (+ the VideoToolbox patch from 019e8379), libvpx 1.17.0, opus 1.6.1, dav1d 1.5.4, libwebp 1.6.0, libjpeg-turbo 3.2.1, OpenH264 2.7.0, TDLib 1.8.69, SQLCipher 4.20.0, Boost 1.92, Rust 1.99.1, mtproto-engine da4b2170, wallet-engine e59e0d89, tlottie 92df98dc, the rlottie/tgcalls fork branches, and OpenSSL 3.5.9 (Mac only).
- Generalize the Mac `tools/dev/tests/test_versions.py` (stage1) into a checker that reads each library's version from its source on either platform.
- Run the checker from Mac `tools/dev/tg check` and iOS `tools/dev/tg lint`, and in both pre-push hooks.
- Verify: change a version in the TOML; both checks fail.
- Effort: M.
- Parallel with 5.3 by lib; the manifest file is owned by one agent.

**5.2 Spike (timebox: ½ day): build the Mac native libraries with the iOS Bazel scripts and the shared disk cache.**
- Background: the iOS BUILD files already branch on `$(TARGET_CPU)=="darwin_arm64"` → `BUILD_ARCH=macos_arm64` (`submodules/ffmpeg/BUILD:275`, `third-party/{dav1d,opus,webp,libvpx,libjpeg-turbo,td}/BUILD`).
- Try:
  1. In the core checkout, run `build-input/bazel build --disk_cache=~/.cache/telegram-ios/bazel-disk-cache --platforms=<macos arm64> //third-party/dav1d:dav1d`. If that config is not selectable, use `--cpu=darwin_arm64` with `--noincompatible_target_cpu_from_platform`.
  2. Then do the same for opus, webp, libvpx, libjpeg-turbo and ffmpeg.
  3. Make the hardcoded `-mmacosx-version-min=14.0` in `build-{opus,webp,dav1d}-bazel.sh` a variable (15.0 for the Mac).
- **Go** if:
  - all six build for macOS arm64 with that one script change;
  - the headers match what the Mac `SharedHeaders` expect;
  - the Mac app links and plays media.

  Then Mac `tools/dev/tg frameworks` calls Bazel for those libraries and copies the outputs into `core-xprojects/*/build`, with fwcache as the outer layer. The forked Mac `build.sh` files for those libraries are deleted.
- **No-go** if any of these fails. Then do the flag parity in the Mac `build.sh` files (5.3) and record why.
- Gain if go: about 724 s of the 1,522 s cold native build become shared Bazel actions, the build flags are the same by construction, and fewer scripts need maintenance.

**5.3 Flag parity for the native libraries.**
- If 5.2 is go, the Bazel scripts already cover opus, webp, libvpx and FFmpeg. Otherwise each change below goes into the Mac `core-xprojects/<lib>/build.sh`.
- Each item is its own commit and its own parallel agent. Each one rebuilds once, under the build lock, through `tools/dev/tg frameworks`.
- **opus**: float + `--enable-intrinsics` (drop `--enable-fixed-point`), as in `third-party/opus/build-opus-bazel.sh`. Verify: Mac `OpusBinding` tests; record a voice message and play it back. Expected: NEON paths and deep PLC available; opus CPU about −10–30% (not measured).
- **libwebp**: use iOS's CMake invocation (Release, `-O3`) instead of autotools `-Os`. Verify: sticker grid renders. Expected: WebP decode about 10–20% faster (not measured).
- **libvpx**: one flag set: `--enable-realtime-only --disable-webm-io --disable-vp9-highbitdepth --disable-postproc --disable-vp9-postproc --disable-vp9-temporal-denoising --enable-multi-res-encoding --enable-runtime-cpu-detect --size-limit=8192x8192`.
  - The Mac drops its vendored `core-xprojects/libvpx/source` and uses the core submodule.
  - On iOS, check `vpx_config.h` for `CONFIG_RUNTIME_CPU_DETECT 1` and `HAVE_NEON_DOTPROD`/`HAVE_NEON_I8MM` (in the iOS repo; `[iOS]` lane).
  - Verify: the Mac video-sticker (VP9) encode and decode tests pass in realtime-only mode.
- **FFmpeg**: one decoder/demuxer/muxer list, stored in the manifest. It is the union: iOS gains the software `aac` and `vorbis` decoders, the Mac gains the `ogg` muxer. The VideoToolbox patch comes with the shared core automatically. Verify: run `FFMpegVideoToolboxAttachmentTests` on both platforms.
- **OpenSSL (Mac)**: actually pass the `no-*` arrays that `core-xprojects/openssl/OpenSSLEncryption/build.sh` defines but never passes to `./Configure` (all except `no-asm`). Replace the `git clone` with the pinned 3.5.9 tarball and its sha256. Verify: the app links (link errors show anything that is still needed). Expected: the 270 s OpenSSL build drops by about 40–60%.
- **tg_owt (Mac)**: `-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0` and `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` (ThinLTO). Use the same LTO flag for the tde2e CMake build and `-flto=thin` in the OpenSSL CFLAGS. Verify: release build plus a test call. Expect a longer release link.
- **Rust on the Mac**:
  - tlottie: `-Cpanic=abort`, matching iOS.
  - mtproto-engine and wallet-engine: `CARGO_PROFILE_RELEASE_LTO` set to the same mode iOS uses once 5.4 has settled it.
  - wallet stays `opt-z` on both.

**5.4 Rust std duplication: verify, then fix whichever side is wrong** `[iOS]`.
- The conflict: `build-system/Make/Make.py` passes `--@rules_rust//rust/settings:lto=fat`, which becomes `-Clto=fat` on every Rust staticlib. iOS `CLAUDE.md:1215` says LTO internalizes std and duplicates it.
- Check: run `third-party/mtproto-engine/scripts/verify-ios-link.sh` on an unstripped `release_arm64` binary, and count std copies with `nm`.
- If std is duplicated, remove the `lto=fat` flag (or limit it to one crate) and use the same mode on the Mac. If not, fix the CLAUDE.md note and use fat LTO on the Mac too.
- Expected: one std copy per binary, which can save a few hundred KB per extra copy.

**5.5 Exclusivity checking: one measured rule for both apps.**
- Today the Mac release (M17, `tools/dev/nanogram/release.py:110-115`, required by `buildcheck.py:141-149`) uses `unchecked`, while iOS `tglint` forbids it.
- Measure on the Mac:
  - count `swift_beginAccess` with `otool -tV`;
  - run a paired `swift test -c release` benchmark on SwiftSignalKit and Postbox, checked vs unchecked.
- **Default chosen:** if the gain is under 2%, drop M17 on the Mac and remove the buildcheck requirement. If it is 2% or more, add `--@build_bazel_rules_swift//swift:copt=-enforce-exclusivity=unchecked` to iOS `common_release_args`, and allow it in both `tglint` copies for release configs only.

---

## 4. Risks and owner decisions

**Decisions. The default shown is what the plan does unless the owner says otherwise.**
1. **Disk cleanup list in 0.1** (≈46 GB of build outputs: recon DerivedData, a stale DerivedData, SwiftPM scratch). This is the only item that needs an explicit yes, because other workflows are running.
2. **Network availability on iOS (2.4):** default is one cross-platform `nw_path_monitor` implementation, verified on an iPhone, with the poll fallback kept for one release.
3. **Exclusivity (5.5):** default is to measure first and keep runtime checks on both apps unless the gain is at least 2%.
4. **opus fixed-point → float (5.3):** default is float on both. Mac output is no longer bit-identical to old Mac builds, which was the only reason fixed point was kept.
5. **Mac core ahead of telegram-macos (3.2):** default is that the Mac follows our iOS `main`. For a new *minor* upstream release, the Mac pins the commit before the merge until a Mac build passes.

**Risks**
- **An iOS-first core edit breaks the Mac build** (UIKit in a shared file). Mitigation: the lint warning in 2.5 and the swift test recipe for each pin bump. The Mac pin moves only after a Mac build passes.
- **A Mac-added test breaks iOS Bazel** (`Tests/**` globs). Mitigation: the `#if os(macOS)` rule in 2.3, and iOS `tools/dev/tg test` runs before main moves.
- **Alternates corruption** if a lender loses objects. Mitigation: lenders never prune, `tools/dev/tg doctor` checks them, and `repack -a -d` is the escape hatch.
- **Xcode CAS exceeds its cap or breaks debugging.** Mitigation: Debug only, an adopt-or-reject rule, and the CAS dir is never deleted while a build is running.
- **Release link time grows** from ThinLTO on tg_owt, tde2e and OpenSSL. Mitigation: the incremental LTO cache. Only release links are affected.
- **The machine is loaded:** every heavy step takes the build lock, and measurements are recorded together with the machine load.

---

## 5. Deliberately not done

- **Sharing compiled objects, Swift modules, LTO bitcode or DerivedData between iOS and the Mac.** The target triples, SDKs and build systems differ, so there can never be a cache hit.
- **One store for the Bazel disk cache and the Xcode CAS.** Bazel uses REAPI; Xcode uses the LLVM CAS. Neither can read the other's store.
- **A separate "core-only" branch split out of iOS main.** 54 commits mix core and UI changes. The Mac ignores paths outside its closure anyway.
- **Using the iOS working tree as the Mac submodule checkout.** The Mac build writes generated files into the core tree. Only the object store is shared (4.1).
- **Moving the Bazel output base or disk cache to the new root.** It would force a full rebuild for no gain. The new root holds only new shared items.
- **sccache/ccache.** fwcache and the cargo target sharing already cover the misses that matter.
- **One umbrella Rust staticlib, BoringSSL on the Mac, one WebRTC codebase.** Each is large work with an unmeasured gain. Revisit after 5.4, and BoringSSL only if OpenSSL trimming is not enough.
- **Aggressive cross-module optimization, `-Osize`, PGO, `-O3` for all of iOS.** These are speculative. `-Osize` was already rejected on iOS (it crashed swift-frontend and gave a tiny gain).
- **A Mac launch order file.** With no account on this Mac, only the login screen can be recorded, so the gain is negligible. Revisit when a test account exists.
- **`swift.internalize_at_link` on iOS and a raised `-mcpu` on iOS.** iOS uses dynamic frameworks and a minimum of iOS 15 (A9).
- **Letting rules_rust use rustup.** It would break Bazel hermeticity. Each side keeps about 0.5 GB per toolchain.

---

## 7. Critic review (2026-11-03)

Read-only review by a skeptical build engineer. Facts below were checked on disk on 2026-11-03 (git, du, grep); nothing was built or changed. Each item: **problem**, **section**, **fix**. Ordered by severity.

1. **Telegram history can still be pushed to klaipher/nanogram.** *(§3.2, §3.3, §5.1)*
   - Problem: the Mac core gitdir (`nanogram-macos/.git/modules/submodules/telegram-ios`, 1.6 GB) holds Telegram's full history. Its local branches `master`, `nanogram-mac`, `nanogram-mac-runtime` and `nanogram-mac-integration` all descend from `fb0e62ba`. Step 3.2 runs `git submodule sync`, which makes `origin` = klaipher/nanogram. After that, any `git push` from that gitdir (by hand or from `sync.py`) uploads Telegram's history. The iOS repo also has a `telegram` remote. **Neither repo has a pre-push hook**: `core.hooksPath` is unset and there are no non-sample hooks in either `.git/hooks`. So "both pre-push hooks" (5.1) do not exist.
   - Fix: before 1.2 and before 3.2, install a pre-push hook in the iOS repo and in every Mac telegram-ios gitdir (main checkout and worktrees). The hook rejects any pushed sha whose `git rev-list --max-parents=0 <sha>` is not `b46f1ec6`; allow-list the history-free `upstream` imports if they have other roots. In the Mac submodule gitdirs, also set `remote.origin.pushurl=DISABLED`, because core commits are pushed only from the iOS repo. Once `mac/core-legacy` is verified, move the fb0e62ba-based local branches out of `refs/heads` (for example to `refs/archive/`).

2. **1.2 verifies after it pushes, and its "zero conflicts" claim is wrong.** *(§3 Phase 1.2)*
   - Problem: the verify block comes after "Push as `mac/core-legacy`".
   - Problem: the Mac core tip is now `179bd8d3` "Merge nanogram-mac-runtime into nanogram-mac-integration": 42 commits after `fb0e62ba`, 1 of them a merge, 8 on the first-parent line. A plain `git rebase --onto` linearizes the history. The merge's conflict resolution (the FFmpeg 8.1.2 vs 9.0.2 hunk) is then replayed as conflicts or silently lost. Identical *root* trees do not make the replay conflict-free.
   - Problem: a default `git fetch <Mac gitdir> <branch>` also follows tags. That would bring Telegram's release tags into the iOS repo, and a later `--tags`/`--follow-tags` push would leak them. The iOS repo is also shallow (grafts at `fb0e62ba` and `279f89e4`).
   - Fix, step by step:
     1. `git fetch --no-tags <gitdir> nanogram-mac-integration:refs/mac/legacy-src`.
     2. Re-create the commits without a rebase, using a `git commit-tree` loop over `git rev-list --reverse --topo-order --parents fb0e62ba..refs/mac/legacy-src`. Map `fb0e62ba` to `b46f1ec6`, keep each original tree, and copy the author and committer env. This keeps the merge, cannot conflict, and leaves the trees byte-identical.
     3. Before pushing, check all of these:
        - `git rev-list --max-parents=0 <new>` prints only `b46f1ec6`;
        - `git rev-list --count b46f1ec6..<new>` is 42;
        - `git diff 179bd8d3 <new>` is empty.
     4. Push only then, with an explicit refspec: `git push origin <new>:refs/heads/mac/core-legacy`. Never use `--all`, `--tags` or `--mirror`.

3. **The 3.2 rollback is wrong.** *(§3 Phase 3.2 rollback)*
   - Problem: "The old pin stays reachable on `mac/core-legacy`" is false, because the re-created commits have new SHAs. Old Mac pins live only on the current `.gitmodules` URL, `https://github.com/klaipher/Telegram-iOS` (branch `nanogram-mac*`), and in the local gitdir. The gate (c) .dmg pin must stay buildable.
   - Fix: before 3.2, run `git ls-remote https://github.com/klaipher/Telegram-iOS` and confirm that a branch there contains the .dmg pin and `179bd8d3`. Keep that repo read-only and never delete it. The rollback is: revert the URL in `.gitmodules`, then `git submodule sync`, then `git submodule update`.

4. **There is no machine-wide build lock.** *(§3 Lanes, §4.4, Risks)*
   - Problem: "use stage2's build lock" does not serialize anything across checkouts. stage2 `disk.py:88` locks `build-{checkout.name}.lock` (the files `build-nanogram-macos.lock`, `-runtime` and `-stage2` all exist), so the lock is per checkout. iOS `tools/dev/tg` takes no lock at all. A stage2 measurement is running right now, so any 0.2/0.3 verify build would corrupt it.
   - Fix: add one flock, `~/.cache/nanogram/heavy-build.lock`, taken by both `tg` scripts around Bazel, xcodebuild, `swift build/test`, `frameworks` and cargo. Until it exists, check `pgrep -fl 'bazel|xcodebuild|swift-(build|test)|cargo'` before every heavy step. Run no Phase 0 build until the stage2 run has finished.

5. **0.2 ordering and verification do not prove the eviction fix.** *(§3 Phase 0.2)*
   - Problem: the current cap is **40G** (`.bazelrc:41`), and the cache is 41G. Lowering it to 30G triggers a large eviction, which is exactly what broke today. Output-base entries recorded under `toplevel` mode stay digest-only until the action runs again. Verify step 2 ("a commit 20 back") does not reproduce eviction. It also moves a shared checkout that other agents are editing.
   - Fix, in this order:
     1. Land `common --remote_download_outputs=all` with the cap unchanged.
     2. Run one full sim build and one `release_arm64` build, so every output is materialized.
     3. Test eviction: set `--experimental_disk_cache_gc_max_size=2G` in `user.bazelrc`, wait for the idle GC (~5 min), then rebuild sim and `release_arm64` **without clean**. Expect no `Missing digest` or `REMOTE_CACHE_EVICTED`.
     4. Restore the cap, then lower it to 30G.

     Keep `DEVICE_DOWNLOAD_OUTPUTS` from 5f99a986 (redundant but harmless), or confirm with `--announce_rc` that the testflight path reads `.bazelrc`. Add a `tg testflight` build without the upload step as a verify step.

6. **The Bazel cache-sharing gain is overstated.** *(§1 table row "Mac native-lib rebuilds", §5.2 "Gain if go", §2 xcode-cas line)*
   - Problem: iOS actions are `ios_arm64` and the Mac's would be `darwin_arm64`, so their action keys differ and iOS work never gives the Mac a hit. The first Mac Bazel build is fully cold. Later hits only replace what fwcache already gives. Mac entries also compete for iOS's disk-cache cap and evict iOS blobs.
   - Problem: §2 suggests the iOS watch xcodebuild "shares" the Xcode CAS. It gets no cross hits; it only uses up the Mac's 10G cap.
   - Problem: 5.2 runs Bazel in a new workspace path. That creates a second output base (several GB) and a second JVM server, and none of this is in the disk math.
   - Fix: restate the 5.2 gain as "flags identical by construction, fewer scripts", with no cache-time claim. Give Mac Bazel its own `--disk_cache` (or raise the cap knowingly), and add its output base to 4.4. Give the watch build its own CAS path, or drop that line.

7. **4.1 skips submodules that Phase 5 needs, and its savings estimate is wrong.** *(§4.1, §5.2, §5.3)*
   - Problem: step 3 sets `update=none` on `third-party/libvpx/libvpx`, but 5.3 has the Mac "use the core submodule" for libvpx. `build-system/bazel-rules/*` is not a submodule on iOS main: `.gitmodules` has no such path, so that entry is stale.
   - Problem: savings. The iOS `.git` is only 273 MB, because it is shallow. The Mac core gitdir is 1.6 GB of Telegram history that the history-free lender does not have, so alternates cannot dedupe it. "≈6.1 → ≈0.4 GB" cannot be reached without dropping old history, which item 3 needs.
   - Fix: keep libvpx if 5.3 adopts it, drop the bazel-rules line, and re-run the grep after Phase 5. Re-measure with `git count-objects -vH` in each gitdir. The realistic gain is `tgios-work` (3.0 GB) plus duplicate worktree gitdirs. Consider skipping the lender entirely and using `git worktree` / `--reference` for new checkouts.

8. **Lender placement could leave dangling references.** *(§4.1, §4.4)*
   - Problem: the lender sits under `~/.cache`, which cleanup tools and people treat as disposable. If it is deleted or re-cloned (which drops objects of force-pushed branches), every borrower breaks at once. This is the same failure class as today's Bazel incident.
   - Fix: put lenders outside `~/.cache` (for example `~/Projects/.git-objects/`), and set `maintenance.auto=false` along with `gc.auto=0` and `gc.pruneExpire=never`. The recovery path is `git fetch` into the borrower; never re-clone the lender. `disk.py` refuses the lender path by design, and `tg doctor` checks it.
   - Fix: write alternates with real paths (`/Users/klaipher/Projects/nanogram-ios/...`). `Telegram-iOS` is a symlink.

9. **The 4.2 Xcode CAS settings leak into Release and lack Xcode version keying.** *(§4.2)*
   - Problem: `CLANG/SWIFT_ENABLE_PREFIX_MAPPING` are unconditional. They change Release debug-info paths and dSYMs, which matters for buildcheck and the .dmg.
   - Problem: "Needs gate (a)" contradicts the Phase 4 header ("after Phase 3").
   - Problem: the CAS format can change between Xcode builds. The current build is 27B52.
   - Fix: scope every line to `[config=Debug]`, land it after (c), and use `COMPILATION_CACHE_CAS_PATH = $(HOME)/.cache/nanogram/xcode-cas/$(XCODE_PRODUCT_BUILD_VERSION)`. Confirm the setting names with `xcodebuild -showBuildSettings | grep COMPILATION_CACHE`. In verify, also check `dwarfdump --debug-info` paths in a Release dSYM: they must be unchanged.

10. **The 0.3 LTO cache can break the TestFlight link.** *(§3 Phase 0.3)*
    - Problem: the default `--spawn_strategy=standalone` is fine, but `Make.py --sandbox` makes link actions sandboxed. A sandboxed link cannot write `~/.cache/telegram-ios/lto-cache`, so it fails. The cache is also outside every inventory.
    - Fix: either add `--sandbox_writable_path=<lto-cache>` when sandboxed or skip the flag there. First confirm that ld-prime accepts `-cache_path_lto`. Add the cache to 4.4. Verify with a `tg testflight` build without upload, plus `codesign --verify --deep` on the .ipa app.

11. **Changes to the iOS release path have no TestFlight check.** *(§0.2, §0.3, §2.6, §5.4, §5.5)*
    - Problem: 2.6 verifies only a sim build and a `tg device` build. Phase 2 puts Mac-originated core code into the app that ships to TestFlight. 5.4 changes Rust LTO for the release build.
    - Fix: for every task that touches iOS release args or core code, add `tools/dev/tg build --release --device` plus a `tg testflight` build without upload (or `xcrun altool --validate-app`) before main moves.

12. **The gate ordering puts the .dmg at risk.** *(§3 Phase 5 header, §5.5)*
    - Problem: "5.4 and 5.5 can start right after (a)". 5.5 edits Mac `release.py` and `buildcheck.py`, which changes the .dmg build before (c).
    - Fix: between (a) and (c), measure only. All Mac release-config changes (5.5, 5.3 opus/OpenSSL/tg_owt, 4.2) land after (c).
    - Also: rule 0.5 must be in force before round 2 starts. If round-2 commits already exist, audit them for the `core:` split before Phase 2.

13. **1.1 and 0.4 are already mostly done.** *(§3 Phase 1.1, §0.4)*
    - Problem (1.1): the merged Mac is already on one core pin, `179bd8d3`.
    - Fix (1.1): reduce 1.1 to a check. `git -C submodules/telegram-ios grep -l ffmpeg-8.1.2 HEAD` must be empty, and FFmpeg must be 9.0.2.
    - Problem (0.4): `wallet-engine` `core.worktree` is already `../../../../third-party/wallet-engine/wallet-engine`, and `status` works. But `.git/config` `submodule.third-party/wallet-engine.url` points at the module's *own gitdir* through the `Telegram-iOS` symlink, so fetches are a no-op.
    - Fix (0.4): reset that URL to the real private remote.

14. **The disk math is stale and misses new consumers.** *(§1 table, §0.1, §2 budget)*
    - Problem: the plan's numbers (16 GiB free, 46 GB reclaim) are out of date. Measured now:
      - free space: 67 GiB;
      - Bazel disk cache: 41G (cap 40G);
      - Bazel output base: 9.8G;
      - `~/.cache/nanogram-macos`: 56G. That is DerivedData 9.1 + stage2 11 + runtime 6.8 + integration-tests 1.4; **`spm-integrate` 16G + `spm-integration` 7.6G**, two scratch dirs with drifting names, together 2.4× the 10G budget; and `tgios-work` 3.0G;
      - `nanogram-macos-runtime` worktree: 18G;
      - Mac main checkout: 13G;
      - recon `src`: 6.5G.

      The Mac caches alone already exceed the 80 GB budget.
    - Problem: the budget leaves out the 5.2 output base, the 4.1 lender clones (peak use before repack), and the "scratch worktree" in 2.6 (about 13 GB checkout plus SwiftPM scratch).
    - Fix: rewrite 0.1 as what remains:
      - after (a): one of the `spm-*` dirs, `DerivedData-runtime` and the runtime worktree;
      - `tgios-work`.

      In 2.6, reuse an existing checkout instead of a new worktree. Restate the budget from measured numbers, and keep a 20 GB free floor check before each heavy step.

15. **The Sparkle signing key is stored in a cache dir.** *(§4.4)*
    - Problem: `~/.cache/nanogram-macos/sparkle-ed25519` sits next to prunable units. If it is lost, the shipped .dmg can never receive updates.
    - Fix: move it to the Keychain or a non-cache path. `disk.py` must never list it.

16. **Some defaults are risky.** *(§4 decisions 2–5, §5.3, §5.5)*
    - **opus float.** Problem: "deep PLC available" is false. The iOS script uses `--disable-asm --enable-intrinsics`, with no `--enable-deep-plc`, DRED or OSCE. Fix: land it after (c) as its own commit. Verify with OpusBinding tests, the Q2 Ogg continuity tests, a voice-message round trip and a call. Report measured CPU, not "10–30%".
    - **Exclusivity off.** Problem: a 2% threshold from Mac `swift test -c release` microbenchmarks on a loaded machine is within noise. Unchecked also turns violations into silent memory corruption in a TestFlight app. Fix: keep checks on both apps. Drop M17 on the Mac. Revisit only on a real workload (≥5 paired runs, ≥5%) and after a Debug run with zero exclusivity traps.
    - **Mac follows iOS main.** Problem: with `branch = main` in `.gitmodules`, any `git submodule update --remote` moves the pin to unverified iOS commits. Fix: `sync.py` never uses `--remote`. `tg check` fails unless the pin is on nanogram main's first-parent line and has a recorded passing Mac build.
    - **2.4 network availability.** Problem: the default swaps the reachability path in the shipping iOS app. Fix: iOS keeps the poll by default, with `nw_path_monitor` behind a flag. Flip it only after a TestFlight soak.

17. **The 5.1 checker crosses repos.** *(§5.1)*
    - Problem: iOS `tg lint` cannot read the Mac's `core-xprojects/*/build.sh`.
    - Fix: each side checks only its own sources against the TOML. Create the pre-push hooks from item 1 first.
