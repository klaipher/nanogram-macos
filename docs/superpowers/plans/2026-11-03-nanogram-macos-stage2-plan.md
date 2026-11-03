# Nanogram for macOS — Stage 2 Implementation Plan (build time and disk)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Day-to-day builds that spend their time compiling, not re-planning; native libraries that are built once per content
and reused by every clone and worktree; and build files on disk that stay bounded and can be listed and cleaned with one command.

**Architecture:** Two independent work packages. **cache+disk** adds a content-addressed native-library cache
(`~/.cache/nanogram-macos/frameworks/<key>/`, restored with APFS clones) in front of upstream's unchanged
`scripts/configure_frameworks.sh`, one DerivedData directory per checkout under the cache root, and `tg clean` /
`tg prune`. **overhead+config** makes `tg build` call xcodebuild the same way every time (fixed argument set, fixed
environment) so Xcode's cached build description and SwiftPM's manifest cache stay valid, skips post-build checks of a
product that did not change, and adds Debug-only settings to `nanogram/Nanogram.xcconfig`; Release keeps every stage 1
optimization. Upstream files (`scripts/*.sh`, `*.pbxproj`, `Package.swift`) are not edited in stage 2.

**Tech Stack:** Xcode 27.2 (27B52) `xcodebuild`, Swift Build (`SWBBuildService`), bash + Python 3 stdlib (`unittest`,
`fcntl`, `hashlib`), APFS `clonefile` through `cp -c`, rustup (toolchain pinned by
`submodules/telegram-ios/third-party/mtproto-engine/rust-toolchain.toml`, 1.96.1 today).

**Spec:** `docs/superpowers/specs/2026-11-02-nanogram-macos-design.md`, section "Stage 2 — build time and disk" and
the baseline table.

---

## Measured starting point (2026-11-03, this checkout, `nanogram/stage2` at `1690eb66`)

All logs: `build-output/stage2-baseline/` (`*.log` raw xcodebuild, `*.ts.log` the same lines with seconds since start,
`*.steps.tsv` the tg-side steps, `cpu.run.txt` user+sys CPU). The Mac was heavily loaded by other workflows the whole
time (load average 47–131 on 10 cores) and ESET Endpoint Security (`scand`) was among the top CPU users, so **wall
times are inflated and noisy; compare CPU seconds and task counts first.** The tg-side steps were run one by one, exactly
as `tg build` runs them (same xcodebuild arguments, DerivedData `~/.cache/nanogram-macos/DerivedData-stage2`).

| What | Upstream baseline (unloaded) | Now (load during run) |
|---|---|---|
| Native libraries | 22 min universal; stage 1 arm64: 777 s, 2.0 GB | 10 C libs reused by stamp; Rust libs rebuilt: wallet-engine 525 s, mtproto-engine 62 s, tlottie 54 s (load 60–90); build dirs 1.67 GB, of which 0.8 GB cargo targets |
| Clean debug, xcodebuild | 401 s, 6.1 GB | 792 s (load 88→96), 6.1 GB (Build 4.1, ModuleCache 1.5, SDK explicit modules 0.5) |
| Clean debug, tg checks after the build | — | buildcheck 37 s, editions 15 s |
| No-change rebuild | 34 s | 29–44 s when the cached build description is reused (36–39 CPU s); 147–251 s when it is recreated (77 CPU s); 269 s / 542 CPU s on the first build in a different environment |
| ChatUI body edit (trailing comment) | 35 s | 88–101 s (load 55–90): 65–81 s planning, ~21 s work (SwiftEmitModule 11.4 s, SwiftDriver 4.0 s, SwiftCompile 0.8 s). The object file is identical, so nothing relinks: this method never measures link + sign. |

**Where a no-change build goes** (best reused-description runs `nochange-noresolve` 29 s and `nochange-flags` 38 s; ranges
from all 6 reused runs):

| Phase (xcodebuild log marker) | Seconds | Notes |
|---|---|---|
| xcodebuild launch, workspace load | 3–4.5 | |
| Resolve Package Graph (≈190 local packages + `swift-argument-parser`) | 6–12 | 54–145 s in runs that also recreated the description; manifests come from `~/Library/Caches/org.swift.swiftpm/manifests` |
| ComputePackagePrebuildTargetDependencyGraph | 7–9 | 18–35 s at load ≥ 90 (single-threaded in SWBBuildService) |
| CreateBuildOperation + ComputeTargetDependencyGraph | 5–10 | up to 25 s under load |
| GatherProvisioningInputs | 0.6–1 | |
| CreateBuildDescription | 0.5–0.7 reused | **20–31 s when recreated** (6 of 13 measured incremental builds); 88 MB per description, only 3 kept (`XCBuildData/prior-build-descriptions.txt`) |
| Tasks | 3–9 | VerifyModule (Sparkle, CodeSyntax) 2.2–8.4 s **on every build**; 6 run-script phases 1.2–1.4 s; CodeSign/ValidateEmbeddedBinary/CopySwiftLibs 1.4–4 s when anything was re-signed |
| tg before xcodebuild (localfixes, credentials, editions `--before-build`) | 0.3 | |
| tg after xcodebuild: buildcheck / editions check | 0.8–1.7 / 4.4–8.6 | the editions check runs `codesign`, `nm -u` and a full-bundle endpoint scan every time |

What did **not** matter: `-skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution` give the
same steady-state CPU (64.9 vs 64.5 user s with a recreated description; 32.6 vs 30.0 with a reused one). They stay in
the canonical argument set because they keep the build offline and deterministic, not as a speedup. Debug already uses
`DEBUG_INFORMATION_FORMAT = dwarf` (0 `GenerateDSYMFile` tasks), explicit modules are already on
(`-explicit-module-build`), index-while-building is already off in `tg build`, and the scheme pre-action
"Prepare TelegramApi Sources" costs 0.8 s.

Defects found while measuring, each fixed below:
1. The framework stamp's `rust=` line records whatever `cargo` is first on `PATH` (`stable` = 1.91.1 here; the source
   checkout recorded 1.99.1), not the pinned 1.96.1 the libraries are built with. Two checkouts disagree, and the
   stamp would not notice a toolchain bump. → Task 1.
2. tlottie has no stamp: `configure_frameworks.sh` re-runs `core-xprojects/tlottie/build.sh` every time (8–54 s). → Tasks 1, 3.
3. The cached build description is thrown away whenever the build request or the environment differs (session
   variables such as `AI_AGENT` reach xcodebuild; the first build from a new environment cost 542 CPU s). → Task 7.
4. Copying build directories with a trailing slash puts their contents one level too high. This checkout's setup copy
   did exactly that on 2026-11-03 (every `core-xprojects/*/build`, `.swiftpm` and `SharedHeaders` landed in its parent;
   on case-insensitive APFS `build/openh264` even merged into the tracked `OpenH264/` folder). → Review Focus 1.

---

## Global Constraints

- Apple Silicon only: `ARCHS = arm64`, `ONLY_ACTIVE_ARCH = YES`; minimum macOS `15.0`; Xcode 27.x (measured on 27.2, 27B52).
- Release keeps every stage 1 optimization, unchanged: `SWIFT_OPTIMIZATION_LEVEL[config=Release] = -O`,
  `SWIFT_COMPILATION_MODE[config=Release] = wholemodule`, `GCC_OPTIMIZATION_LEVEL[config=Release] = 3`,
  `LLVM_LTO[config=Release] = YES_THIN`, `DEAD_CODE_STRIPPING[config=Release] = YES`. Every setting added in stage 2
  is `[config=Debug]`-scoped.
- Upstream files are not edited in stage 2: `scripts/configure_frameworks.sh`, `scripts/framework-inputs.sh`,
  `core-xprojects/**`, `Telegram.xcodeproj/project.pbxproj`, submodules, `Package.swift` files.
- Cache root: `config.CACHE_DIR` (`~/.cache/nanogram-macos`, overridable with `NANOGRAM_CACHE_DIR`). Native-library cache:
  `CACHE_DIR/frameworks/<key>/`. DerivedData: `CACHE_DIR/DerivedData` for the checkout named `nanogram-macos`,
  `CACHE_DIR/DerivedData-<suffix>` for `nanogram-macos-<suffix>` (this checkout: `DerivedData-stage2`).
- Defaults: native-library cache cap **3 GB** (`NANOGRAM_FRAMEWORK_CACHE_MAX_GB`); whole cache root cap **40 GB**
  (`NANOGRAM_CACHE_MAX_GB`); stale = unused for **7 days**.
- Deleting is allowed only inside `CACHE_DIR` and the checkout's build products (`build-output/`, `core-xprojects/*/build`,
  generated `SharedHeaders`, the two Rust xcframeworks). Never user data, never another checkout's sources, never
  anything a running build holds (`~/.cache/nanogram-macos/build-<checkout-dir-name>.lock`, the lock `buildlock` takes).
- Full builds (xcodebuild of the app, `tg build`, `tg frameworks`) run only via `~/.cache/nanogram-macos/bin/buildlock <command>`.
  Check `df -h /System/Volumes/Data` first; do not start a clean build below 30 GB free.
- Every measurement records: wall seconds, `uptime` load before and after, CPU (`/usr/bin/time -l` user+sys) and the
  `-showBuildTimingSummary` table. Logs go to `build-output/stage2/<task>/`.
- No publishing (releases, uploads, notarization, upstream PRs, new repos), no Telegram login, no secrets in logs or commits.
- Commit messages end with exactly:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Csjp35PNHMsEZhxmevCEC7
  ```
- Tooling tests: `tools/dev/tests/run.sh` (unittest + shellcheck) must pass at every commit.

## Review Focus

1. **Restore writes files one directory level off** (the trailing-slash copy that broke this checkout's setup) →
   Task 2 `test_restore_layout_is_exact`: after a round trip every file sits at its original relative path and the
   parent directories hold no extra entries.
2. **Two checkouts use the cache at once**: two `tg frameworks` store the same key, or one prunes while another restores →
   Task 2 `test_concurrent_store_same_key` and `test_prune_skips_entry_being_restored`.
3. **A cache entry reused across a toolchain change** (Xcode update, pinned Rust bump, `ARCHS` or deployment change) →
   Task 1 `test_key_changes_with_pinned_rust`, `test_key_changes_with_xcode_archs_deployment`.
4. **Fast Debug settings leaking into Release, the mas edition or an archive** → Task 9
   `test_stage2_settings_are_debug_only` and `test_release_lines_unchanged`, plus the Release log check in Task 12.
5. **`tg prune` / `tg clean` deleting something in use or not ours** (a running build in another checkout, the current
   checkout's DerivedData, an unknown folder, a path outside the cache root) → Task 5 `test_locked_item_kept`,
   `test_current_checkout_kept`, `test_other_never_removed`, `test_refuses_paths_outside_cache`,
   `test_clean_refuses_while_locked`.

---

## Decisions

| Topic | Decision | Why (measurement) |
|---|---|---|
| Native-library cache key | sha256 of upstream's stamp text with the `rust=` line replaced by the pinned toolchain's `rustc -V`, plus `nanogram-fwcache=1`; tlottie gets its own stamp built the same way | Stamps already hold Xcode build, `deployment=`, `archs=`, checkout-relative input fingerprints and dependency hashes; only the Rust line was wrong (defect 1) |
| What a cache entry holds | Only what the app build reads: `framework_required_outputs`, the `*.h` files `sync-headers.sh` copies out of the library's build dir, and the two Rust xcframeworks | Build dirs are 1.67 GB; 0.8 GB of that is cargo `lib/`/`xtask/` targets, the rest is mostly unpacked sources and per-arch objects |
| How it is restored | `cp -c -R -p` (APFS clone) of each top-level entry into its exact parent, then the checkout's own stamp is written so `configure_frameworks.sh` skips the library | Clones cost no extra disk; writing the local stamp keeps upstream's script unchanged |
| When `configure_frameworks.sh` runs | Only if at least one library is neither current nor in the cache; otherwise tg runs the header sync itself | Upstream's script always rebuilds tlottie (defect 2) |
| Throwaway per-library DerivedData | `TMPDIR=CACHE_DIR/tmp/frameworks-<pid>` for `configure_frameworks.sh`; its `mktemp -d` dirs land there and `tg prune` removes ones older than 6 hours | Upstream deletes them on exit but not when killed; this keeps them findable and bounded without editing the script |
| DerivedData | One directory per checkout under the cache root, named by the checkout folder (existing `DerivedData`, `DerivedData-runtime`, `DerivedData-stage2` keep working) | Sharing one directory between checkouts would recompile everything on every switch and race between concurrent builds |
| Build description reuse | `tg build` runs xcodebuild with a fixed argument set and an allow-listed environment, and reports `build description: reused` or `recreated` | Recreated = +20–31 s and ~40 CPU s per build; first build in a new environment = 542 CPU s |
| Package flags | Always pass `-skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution`, except `--clean` builds, which resolve | No CPU difference in steady state; offline and deterministic; a stale `Package.resolved` gets fixed by the clean build `tg sync-upstream` already runs |
| Post-build checks | buildcheck stays on every build (0.8–1.7 s incremental); the editions check is skipped when the app's executables, Info.plist and code signatures are byte-for-byte the files it last passed | Editions check costs 4.4–8.6 s on builds that changed nothing |
| Debug settings | `ENABLE_MODULE_VERIFIER = NO`, `LM_SKIP_METADATA_EXTRACTION = YES`, `DEBUG_INFORMATION_FORMAT = dwarf`, `SWIFT_COMPILATION_MODE = singlefile`, `GCC_OPTIMIZATION_LEVEL = 0`, all `[config=Debug]` | VerifyModule 2.2–8.4 s every build; ExtractAppIntentsMetadata 170 tasks / 49 s in a clean build (the app has no App Intents); the other three pin today's values against upstream drift |
| Compilation caching | Go/no-go experiment (Task 10): Debug only, CAS shared by all checkouts at `CACHE_DIR/CompilationCache`, capped at 10 GB | Upstream offers it only as `TELEGRAM_COMPILATION_CACHE`; Apple says it helps clean builds and branch switches; it costs disk we lack (≈39–60 GB free) |
| Rejected: run-script phases with outputs | Not done | 6 phases cost 1.2–1.4 s per build in total; adding outputs means editing upstream's pbxproj and Sparkle's project (a conflict on every sync) |
| Rejected: mergeable libraries, eager linking | Not done | Both target dynamic frameworks; the ~170 package modules link statically into one binary; Sparkle/CodeSyntax/RLottie frameworks do not change day to day |
| Rejected: `-jobs`, `ONLY_ACTIVE_ARCH`, explicit modules, index store, dSYM | Leave as is | Already optimal or already on (see measured section); the Mac is shared, so a lower `-jobs` would only slow us |
| Not ours to fix | Owner action: exclude `~/.cache/nanogram-macos` and the checkouts from ESET on-access scanning | `scand` was among the top CPU users during every build |

## Work packages and shared files

The two packages can be implemented in parallel, in either order, on top of `nanogram/stage2`. Task 12 runs after both
are merged.

| | Package 1 "cache+disk" (A, D): Tasks 1–6 | Package 2 "overhead+config" (B, C): Tasks 7–11 |
|---|---|---|
| Owns (only this package edits) | `tools/dev/nanogram/{fwcache,disk,frameworks,config,doctor}.py`, `tools/dev/tests/{test_fwcache,test_disk,test_frameworks,test_config,test_doctor}.py` | `tools/dev/nanogram/{xcbuild,editions,buildcheck}.py`, `nanogram/Nanogram.xcconfig`, `tools/dev/tests/{test_xcbuild,test_editions,test_buildcheck}.py`, `tools/dev/tests/fixtures/stage2-*.log` |
| `tools/dev/tg` | adds `cmd_clean` and `cmd_prune` right after `cmd_frameworks`; adds `clean) cmd_clean "$@" ;;` and `prune) cmd_prune "$@" ;;` right after the `frameworks)` line in `main`; appends two lines at the end of `usage` (after `release-direct`) | edits only inside `cmd_build` and `cmd_warnings`, and the `build` line of `usage` |
| `docs/local-development.md` | edits "## Native libraries"; adds "## Disk and caches" right after it | adds "## Day-to-day build speed" right after "### Building from Xcode" |

Contracts between the packages: Package 2 keeps reading `config.DERIVED_DATA` (same name; Package 1 changes only its
value). Package 1's `disk.inventory` reports `CACHE_DIR/CompilationCache` as kind `"compilation-cache"` and removes it
only when `tg prune --max-gb` must evict, last (Package 2 may create it in Task 10).

## File Structure

| Path | Responsibility |
|---|---|
| `tools/dev/nanogram/fwcache.py` (new) | Cache keys, cacheable files, store, restore, LRU prune of `CACHE_DIR/frameworks` |
| `tools/dev/nanogram/frameworks.py` | `tg frameworks`: decide current / restore / build per library, run upstream's script only for misses, sync headers, verify |
| `tools/dev/nanogram/config.py` | `derived_data_dir()`; `DERIVED_DATA` per checkout |
| `tools/dev/nanogram/disk.py` (new) | Inventory of the cache root, `tg clean`, `tg prune` |
| `tools/dev/nanogram/doctor.py` | One non-required finding: cache root size vs cap |
| `tools/dev/nanogram/xcbuild.py` (new) | The canonical xcodebuild argument list and environment; build-description reuse detection |
| `tools/dev/nanogram/editions.py` | Product fingerprint; skip the check when unchanged |
| `tools/dev/nanogram/buildcheck.py` | Debug log must have no VerifyModule / GenerateDSYMFile / ExtractAppIntentsMetadata tasks |
| `nanogram/Nanogram.xcconfig` | Debug-only build settings |
| `tools/dev/tg` | Argument parsing for `clean`, `prune`, the new `build` options |

---

## Package 1 — cache+disk

### Task 1: Cache keys and cacheable files

**Files:**
- Create: `tools/dev/nanogram/fwcache.py`
- Create: `tools/dev/tests/test_fwcache.py`

**Interfaces:**
- Consumes: `frameworks.libraries() -> list[str]`, `frameworks.build_environment(timing_log, base) -> dict`,
  `config.ROOT`, `config.CACHE_DIR`.
- Produces:
  - `UNITS: tuple[str, ...]` = `tuple(frameworks.libraries()) + ("tlottie",)`
  - `EXTRA_OUTPUTS: dict[str, str]` = `{"wallet-engine": "packages/WalletEngine/wallet_engineFFI.xcframework", "mtproto-engine": "submodules/telegram-ios/submodules/MTProtoRustEngine/MTProtoEngineFFI.xcframework"}`
  - `pinned_rust(root: Path) -> str`: `rustc -V` output of `rustup run <channel> rustc -V` (channel = `channel` in
    `submodules/telegram-ios/third-party/mtproto-engine/rust-toolchain.toml`), or `"missing"`.
  - `local_stamps(root: Path, env: Mapping[str, str]) -> dict[str, str]`: one bash run that sources
    `scripts/framework-inputs.sh` and calls `framework_stamp "$root" "$lib" "$STAMPS"` for every library in
    `libraries()` order (writing each into `$STAMPS/$lib` before the next, as `configure_frameworks.sh` does, so
    `dependency:` lines resolve), plus a tlottie stamp: `schema=1`, `lib=tlottie`, the same `xcode=`/`deployment=`/`archs=`
    lines, `input:submodules/tlottie=<framework_path_fingerprint>`, `input:core-xprojects/tlottie/build.sh=<sha256>`.
    `env` supplies `MACOSX_DEPLOYMENT_TARGET`, `ARCHS` (from `frameworks.build_environment`) and `FRAMEWORK_XCODE_VERSION`
    (computed exactly as `configure_frameworks.sh` does: `xcodebuild -version | tr '\n' ' '`), so the stamps equal the ones the
    script writes.
  - `cache_key(stamp: str, rust: str) -> str`: sha256 hex of `"nanogram-fwcache=1\n"` + the stamp with every line
    starting `rust=` replaced by `rust=<rust>`.
  - `header_sources(root: Path) -> list[Path]`: source directories of `DIRECTORY_PAIRS` in `scripts/configure_frameworks.sh`
    (parsed, `${SCRIPT_DIR}/..` → `root`).
  - `cached_files(root: Path, unit: str) -> list[Path]` (checkout-relative, sorted): `framework_required_outputs` of the
    unit (tlottie: `core-xprojects/tlottie/build/libtlottie.a`) + every `*.h` below each `header_sources` dir that lies inside
    the unit's build dir + every file below `EXTRA_OUTPUTS[unit]`.

- [ ] **Step 1: Write the failing tests** in `test_fwcache.py`:
  - `test_key_ignores_cargo_on_path`: two stamps that differ only in `rust=cargo 1.91.1 …` vs `rust=cargo 1.99.1 …` give
    the same `cache_key(stamp, "rustc 1.96.1 (abc 2026-01-01)")`.
  - `test_key_changes_with_pinned_rust`: same stamp, rust `1.96.1` vs `1.97.0` → different keys.
  - `test_key_changes_with_xcode_archs_deployment`: changing any of the `xcode=`, `archs=`, `deployment=` lines changes the key.
  - `test_stamps_have_no_absolute_paths`: `local_stamps(config.ROOT, env)` has an entry for every unit in `UNITS` and no
    stamp contains `str(config.ROOT)` or `str(Path.home())`.
  - `test_extra_outputs_match_upstream_reset`: the `rm -rf` targets in `framework_reset_outputs` of
    `scripts/framework-inputs.sh` (with `$1/` stripped) equal `set(EXTRA_OUTPUTS.values())`.
  - `test_cached_files_skip_scratch`: in a temp root with `core-xprojects/wallet-engine/build/{libwallet_engine.a,WalletEngineFFI.swift,lib/x.rlib,xtask/y}`
    and the xcframework files, `cached_files(root, "wallet-engine")` contains the `.a`, the `.swift` and the xcframework files and
    nothing under `build/lib` or `build/xtask`.
  - `test_cached_files_take_only_synced_headers`: temp root with `core-xprojects/webrtc/build/src/api/a.h` and `.../a.cc`:
    `a.h` is listed, `a.cc` is not.
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_fwcache.py -v` → FAIL (`No module named nanogram.fwcache`).
- [ ] **Step 3: Implement** the interfaces above in `fwcache.py`. Required outputs per unit come from one bash call to
  `framework_required_outputs` (as `frameworks.required_outputs` does today).
- [ ] **Step 4: Run** the same command → PASS; then `tools/dev/tests/run.sh` → PASS.
- [ ] **Step 5: Commit** `fwcache: stable cache keys and cacheable files for native libraries`.

### Task 2: Store, restore with APFS clones, cap and prune

**Files:**
- Modify: `tools/dev/nanogram/fwcache.py`
- Modify: `tools/dev/tests/test_fwcache.py`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `cache_root() -> Path` = `config.CACHE_DIR / "frameworks"` (read at call time so tests can patch `config.CACHE_DIR`).
  - `@dataclass(frozen=True) class Entry: key: str; unit: str; path: Path; size: int; last_used: float`
  - `lookup(key: str) -> Entry | None`
  - `store(root: Path, unit: str, key: str, stamp: str) -> Entry`: under `fcntl.flock(cache_root()/".lock", LOCK_EX)`;
    clone files into `<key>.partial-<pid>/tree/<relative path>` with `cp -c -p`, write `meta.json`
    (`{"schema": 1, "unit", "key", "stamp", "created", "size"}`), `os.rename` to `<key>`; if `<key>` already exists,
    delete the partial dir and return the existing entry.
  - `restore(root: Path, unit: str, entry: Entry, local_stamp: str) -> None`: under `LOCK_SH`; remove the unit's build dir
    and its `EXTRA_OUTPUTS` path; for each top-level directory `d` in `entry.path/"tree"`, run
    `cp -c -R -p <entry>/tree/<d> <root>/` (source **without** trailing slash, destination = the parent);
    write `local_stamp` to `<build dir>/.framework-stamp` (tlottie: `core-xprojects/tlottie/build/.nanogram-stamp`);
    `os.utime(entry.path / "meta.json")`.
  - `max_bytes() -> int`: `NANOGRAM_FRAMEWORK_CACHE_MAX_GB` (default 3) × 1024³.
  - `prune(limit: int, keep: set[str]) -> list[Entry]`: under `LOCK_EX`; delete `*.partial-*` older than 1 h and entries
    without `meta.json`; then evict by oldest `meta.json` mtime, never a key in `keep`, until the total is ≤ `limit`.
    Returns the evicted entries.

- [ ] **Step 1: Write the failing tests** (temp `config.CACHE_DIR` and temp checkout roots):
  - `test_restore_layout_is_exact`: store `wallet-engine` from root A (files under `core-xprojects/wallet-engine/build/` and the
    xcframework), restore into empty root B: the set of files in B equals the stored relative paths, contents equal, and
    `core-xprojects/wallet-engine/` contains only `build`, `packages/WalletEngine/` contains only the xcframework.
  - `test_restore_writes_local_stamp`: `.framework-stamp` in B equals the `local_stamp` argument.
  - `test_store_existing_key_is_noop`: second `store` returns the same path, leaves no `*.partial-*`.
  - `test_concurrent_store_same_key`: two `multiprocessing` processes store the same key → one entry, no partial dirs, both return it.
  - `test_prune_evicts_lru_but_keeps_current`: three entries, limit fits two, oldest is in `keep` → the second-oldest goes.
  - `test_prune_removes_stale_partials`: a `x.partial-1` dir with mtime 2 h ago is removed, a fresh one is kept.
  - `test_prune_skips_entry_being_restored`: a child process holds `LOCK_SH` (as `restore` does); `prune` called with
    `limit=0` from the parent waits until the child releases, and the restore in the child completes with all files present.
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_fwcache.py -v` → the new tests FAIL.
- [ ] **Step 3: Implement** `cache_root`, `Entry`, `lookup`, `store`, `restore`, `max_bytes`, `prune`.
- [ ] **Step 4: Run** → PASS; `tools/dev/tests/run.sh` → PASS.
- [ ] **Step 5: Commit** `fwcache: store and restore native libraries with APFS clones, LRU cap`.

### Task 3: `tg frameworks` and `tg setup` go through the cache

**Files:**
- Modify: `tools/dev/nanogram/frameworks.py`
- Modify: `tools/dev/tests/test_frameworks.py`
- Modify: `docs/local-development.md` ("## Native libraries")

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `Status = Literal["current", "restore", "build"]`
  - `plan(stamps: dict[str, str], is_current: Callable[[str, str], bool], find: Callable[[str], Entry | None], rust: str, use_cache: bool) -> dict[str, Status]`
  - `run(root: Path, use_cache: bool, runner: Runner) -> Summary` where `Runner` bundles the side effects
    (`configure()`, `sync_headers()`, `build_tlottie()`, `restore()`, `store()`) so tests can fake them;
    `Summary` = counts of current / restored / built units, seconds, cache size.
  - `build_environment(...)` additionally sets `TMPDIR = str(config.CACHE_DIR / "tmp" / f"frameworks-{os.getpid()}")` (created first).
  - CLI: `tg frameworks [--no-cache] [--verify-only]`; `NANOGRAM_FRAMEWORK_CACHE=0` = `--no-cache`.
    `tg setup` needs no change: it ends with `cmd_frameworks`, so a fresh clone restores from the cache.
- Order inside `run`: `python3 scripts/prepare-telegram-api.py` and `python3 scripts/prepare-flat-serialization.py`
  (what `configure_frameworks.sh` runs first) → restore every `restore` unit (C libraries in `libraries()` order) →
  if any C/Rust library is `build`: `sh scripts/configure_frameworks.sh` (it skips current and restored ones, rebuilds the
  rest, syncs headers, runs tlottie) → else `sync_headers()` (each `DIRECTORY_PAIRS` pair plus the td pair through
  `scripts/sync-headers.sh`) and, only if tlottie is `build`, `core-xprojects/tlottie/build.sh` → recompute stamps and
  `store` every unit whose key is not in the cache (this also seeds the cache from an existing checkout) →
  `fwcache.prune(max_bytes(), keep=<this checkout's keys>)` → `verify_outputs()`.
  A unit is `current` when its stamp file equals the local stamp and `verify_outputs` finds nothing missing for it.
- Output line: `==> native libraries: 13 current, 0 restored, 0 built in 4s; cache 0.4 GB (cap 3 GB)`.

- [ ] **Step 1: Write the failing tests** with a fake `Runner`:
  `test_all_current_skips_configure` (configure, sync and tlottie never called),
  `test_hits_restore_and_skip_configure` (restore called for each hit, then `sync_headers`, never `configure`),
  `test_miss_runs_configure_then_stores` (configure once, store for the missed unit),
  `test_current_units_seed_the_cache` (current unit with no entry → `store` called),
  `test_no_cache_builds_even_with_hit` (`use_cache=False` → status `build`, `restore` never called),
  `test_tmpdir_points_into_cache` (`build_environment(...)["TMPDIR"]` starts with `str(config.CACHE_DIR / "tmp")`).
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_frameworks.py -v` → new tests FAIL.
- [ ] **Step 3: Implement** `plan`, `run`, the `Runner` with real side effects, and the CLI flags in `main`.
- [ ] **Step 4: Run** → PASS; `tools/dev/tests/run.sh` → PASS.
- [ ] **Step 5: Acceptance on this checkout** (record wall, `uptime`, CPU into `build-output/stage2/task3/`):
  1. `~/.cache/nanogram-macos/bin/buildlock /usr/bin/time -l tools/dev/tg frameworks` → `13 current`, cache seeded;
     `du -sh ~/.cache/nanogram-macos/frameworks` (one full set; expected well under 1 GB).
  2. Second run → `13 current, 0 restored, 0 built`, under 10 s wall at load < 20 (it was ≥ 54 s because of tlottie).
  3. Delete this checkout's `core-xprojects/*/build`, the two `EXTRA_OUTPUTS` and the generated `SharedHeaders` dirs
     (`submodules/{tgcalls,Mozjpeg,libwebp}/SharedHeaders`, `submodules/telegram-ios/submodules/{FFMpegBinding,OpusBinding,OpenSSLEncryptionProvider}/SharedHeaders`)
     → `tg frameworks` → `0 current, 13 restored, 0 built` in under 60 s; `tg frameworks --verify-only` → ok;
     `git status --short` → empty; `buildlock tools/dev/tg build` → succeeds (app links against restored libraries).
- [ ] **Step 6: Docs**: in "## Native libraries" say what is cached, where, the key, `--no-cache`, and the measured times.
- [ ] **Step 7: Commit** `tg frameworks: restore native libraries from the shared cache, build only misses`.

### Task 4: One DerivedData directory per checkout

**Files:**
- Modify: `tools/dev/nanogram/config.py`
- Create: `tools/dev/tests/test_config.py`

**Interfaces:**
- Produces: `derived_data_dir(root: Path, cache_dir: Path, env: Mapping[str, str]) -> Path` and
  `DERIVED_DATA = derived_data_dir(ROOT, CACHE_DIR, os.environ)`. `NANOGRAM_DERIVED_DATA` wins; otherwise suffix =
  `root.name.removeprefix("nanogram-macos").lstrip("-")`, giving `cache_dir/"DerivedData"` for an empty suffix and
  `cache_dir/f"DerivedData-{suffix}"` otherwise.

- [ ] **Step 1: Write the failing tests**: `test_main_checkout` (`nanogram-macos` → `DerivedData`),
  `test_worktree_suffix` (`nanogram-macos-stage2` → `DerivedData-stage2`, `nanogram-macos-runtime` → `DerivedData-runtime`),
  `test_other_folder_name` (`nanogram` → `DerivedData-nanogram`), `test_env_override`.
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_config.py -v` → FAIL.
- [ ] **Step 3: Implement.** `tools/dev/tg` keeps `config_value DERIVED_DATA` unchanged.
- [ ] **Step 4: Run** → PASS; `tools/dev/tg build` in this checkout prints and uses `~/.cache/nanogram-macos/DerivedData-stage2`.
- [ ] **Step 5: Commit** `config: one DerivedData directory per checkout`.

### Task 5: `tg clean`, `tg prune`, doctor's disk line

**Files:**
- Create: `tools/dev/nanogram/disk.py`, `tools/dev/tests/test_disk.py`
- Modify: `tools/dev/tg` (only the places listed under "Work packages"), `tools/dev/nanogram/doctor.py`, `tools/dev/tests/test_doctor.py`

**Interfaces:**
- Consumes: `config.CACHE_DIR`, `config.DERIVED_DATA`, `config.ROOT`, `fwcache.prune`, `fwcache.max_bytes`.
- Produces:
  - `Kind = Literal["derived-data", "swiftpm-scratch", "frameworks", "compilation-cache", "tmp", "other"]`
  - `@dataclass(frozen=True) class Item: path: Path; kind: Kind; owner: Path | None; size: int; last_used: float; orphan: bool; locked: bool; current: bool`
  - `inventory(cache_dir: Path, current_derived: Path) -> list[Item]`: each top-level entry of `cache_dir`.
    `DerivedData*` → `derived-data`, owner = parent of `WorkspacePath` in its `info.plist`, orphan = owner missing;
    `spm-*` and `swiftpm` → `swiftpm-scratch`; `frameworks`; `CompilationCache` → `compilation-cache`; `tmp`; everything else
    (`bin`, `*.lock`, `tools`, `sparkle-ed25519`, `launch-home`, …) → `other`. `locked` = `build-<owner.name>.lock` cannot be
    taken with `LOCK_EX | LOCK_NB`. `last_used` = newest mtime of the entry and its direct children. `size` from `du -sk`.
  - `clean(root: Path, everything: bool) -> int`: refuses (raises `config.ConfigError`) while this checkout's lock is held;
    removes `DERIVED_DATA/"Build"` (or all of `DERIVED_DATA` with `everything`) and `build-output/apps`; returns bytes freed.
  - `prune(items: list[Item], max_total: int, stale_days: int = 7, dry_run: bool = False) -> list[Item]`: removes orphan
    `derived-data`; removes unlocked, non-current `derived-data` / `swiftpm-scratch` / `tmp` unused for `stale_days`
    (`tmp/frameworks-*` after 6 hours); calls `fwcache.prune`; then, while the total exceeds `max_total`, removes the
    least recently used unlocked, non-current item of kind `swiftpm-scratch`, then `derived-data`, then `compilation-cache`.
    Never removes `other`; asserts every removed path is inside `config.CACHE_DIR`.
  - CLI: `tg clean [--all]` prints sizes before and after. `tg prune [--dry-run] [--max-gb N]` (default
    `NANOGRAM_CACHE_MAX_GB` or 40) prints one row per item: kind, path, owner, size, last used, action, then the totals.
  - `doctor.check_caches() -> Finding` (not required): `ok` when the cache root is under the cap; hint `run tg prune`.

- [ ] **Step 1: Write the failing tests** (temp cache dir with fake `info.plist` files and lock files):
  `test_inventory_classifies`, `test_orphan_derived_data_removed`, `test_locked_item_kept` (a child process holds the owner's lock),
  `test_current_checkout_kept` (current and stale and over cap → kept), `test_stale_scratch_removed`,
  `test_over_cap_evicts_lru_in_kind_order`, `test_other_never_removed`, `test_dry_run_removes_nothing`,
  `test_refuses_paths_outside_cache` (an `Item` whose path is outside `config.CACHE_DIR` → `ConfigError`, nothing deleted),
  `test_clean_refuses_while_locked`, `test_clean_all_removes_derived_data_and_apps`;
  in `test_doctor.py`: `test_caches_over_cap_warns`.
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_disk.py tools/dev/tests/test_doctor.py -v` → FAIL.
- [ ] **Step 3: Implement** `disk.py`, `doctor.check_caches`, and in `tg`: `cmd_clean() { py disk clean "$@"; }`,
  `cmd_prune() { py disk prune "$@"; }`, the two `main` lines and the two `usage` lines
  (`clean            remove this checkout's build products [--all]`, `prune            list caches and build files, remove stale ones [--dry-run] [--max-gb N]`).
- [ ] **Step 4: Run** → PASS; `tools/dev/tests/run.sh` (includes shellcheck of `tg`) → PASS.
- [ ] **Step 5: Real run**: `tools/dev/tg prune --dry-run > build-output/stage2/task5/prune-dry-run.txt`; check that it lists
  `DerivedData`, `DerivedData-runtime*`, `DerivedData-stage2`, the `spm-*` scratch dirs (≈32 GB on 2026-11-03) and
  `frameworks`, and that nothing locked or current is marked for removal. Do **not** run a non-dry `tg prune` that would
  touch other checkouts' directories while their workflows run; show the owner the dry-run table instead.
- [ ] **Step 6: Commit** `tg clean and tg prune: bounded build files under one cache root`.

### Task 6: Package 1 docs and measurements

**Files:**
- Modify: `docs/local-development.md` (add "## Disk and caches" after "## Native libraries")

- [ ] **Step 1: Measure** (via buildlock, wall + `uptime` + CPU, logs in `build-output/stage2/task6/`):
  native libraries from an empty checkout state with a warm cache (Task 3 acceptance step 3), with `--no-cache`
  (full arm64 build: compare with stage 1's 777 s), size of one cache set, `DerivedData-stage2` size after a clean debug build,
  `tg prune --dry-run` totals.
- [ ] **Step 2: Write "## Disk and caches"**: a table of every location (cache root, frameworks cache, DerivedData per checkout,
  `tmp`, SwiftPM scratch dirs, CompilationCache if present), what creates it, its cap, and which command cleans it; the
  measured numbers; the owner action about ESET exclusions.
- [ ] **Step 3: Commit** `docs: native-library cache and disk layout, measured`.

---

## Package 2 — overhead+config

### Task 7: One canonical xcodebuild invocation

**Files:**
- Create: `tools/dev/nanogram/xcbuild.py`, `tools/dev/tests/test_xcbuild.py`,
  `tools/dev/tests/fixtures/stage2-description-reused.log`, `tools/dev/tests/fixtures/stage2-description-recreated.log`
  (20-line excerpts around `CreateBuildDescription` from `build-output/stage2-baseline/nochange-flags.log` and `nochange-2.log`)
- Modify: `tools/dev/tg` (`cmd_build` only)

**Interfaces:**
- Produces:
  - `ENV_ALLOWLIST = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "DEVELOPER_DIR")`
  - `FIXED_PATH = f"{config.RUSTUP_BIN}:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"`
  - `build_env(base: Mapping[str, str]) -> dict[str, str]`: the allow-listed keys present in `base`, `PATH = FIXED_PATH`,
    `LANG` defaulting to `en_US.UTF-8`, nothing else.
  - `PACKAGE_FLAGS = ("-skipPackagePluginValidation", "-skipMacroValidation", "-disableAutomaticPackageResolution")`
  - `xcodebuild_args(*, configuration: str, scheme: str, derived: Path, xcconfig: Path, conditions: str, clean: bool, extra: Sequence[str]) -> list[str]`:
    exactly today's `cmd_build` arguments (workspace, scheme, configuration, `-destination 'platform=macOS,arch=arm64'`,
    `-derivedDataPath`, `-xcconfig`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS=<conditions>`, `COMPILER_INDEX_STORE_ENABLE=NO`,
    `-showBuildTimingSummary`) plus `PACKAGE_FLAGS`, minus `-disableAutomaticPackageResolution` when `clean`, then `extra`.
  - `description_reused(log: str) -> bool`: `False` when the log contains `Build description signature:`.
  - CLI `python3 -m nanogram.xcbuild run --configuration … --scheme … --derived … --xcconfig … --conditions … --log … [--clean] [-- extra]`:
    runs xcodebuild with `build_env(os.environ)`, writes the log, prints
    `build description: reused` or `build description: recreated (costs 20–30 s; happens after setting or environment changes)`,
    exits with xcodebuild's status. When the log contains `Package.resolved` / `resolved file` errors, it prints
    `hint: run tg build --clean to re-resolve packages`.
  - `tg build` gains `--resolve-packages` (drops `-disableAutomaticPackageResolution` without cleaning); `cmd_build`
    calls `py xcbuild run …` instead of xcodebuild directly; everything else in `cmd_build` stays.

- [ ] **Step 1: Write the failing tests**: `test_env_drops_session_variables` (`AI_AGENT`, `PYTHONPATH`, `OLDPWD`, `SHLVL`
  absent), `test_env_is_stable_across_shells` (two bases with different `PATH`/`PWD`/extra vars but the same allow-listed
  values → equal dicts), `test_args_include_package_flags`, `test_clean_build_resolves_packages`,
  `test_args_match_stage1_build` (all stage 1 arguments present, in order, for Debug and Release),
  `test_description_reused_detection` (both fixtures).
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_xcbuild.py -v` → FAIL.
- [ ] **Step 3: Implement** `xcbuild.py` and switch `cmd_build` to it; add `--resolve-packages` to the option parser and
  the `build` usage line (`build the app [--release] [--clean] [--resolve-packages] [--edition mas|direct]`).
- [ ] **Step 4: Run** → PASS; `tools/dev/tests/run.sh` → PASS.
- [ ] **Step 5: Measure** (via buildlock, `build-output/stage2/task7/`): `tg build` twice from this shell, then once from
  a shell with extra exported variables (`env FOO=1 AI_AGENT=other tools/dev/tg build`): all three after the first print
  `build description: reused`; record `/usr/bin/time -l` CPU (target: xcodebuild ≤ 40 CPU s, measured 36–39 reused vs
  77 recreated) with `uptime`.
- [ ] **Step 6: Commit** `tg build: one canonical xcodebuild invocation that keeps Xcode's build description`.

### Task 8: Skip the editions check when the product did not change

**Files:**
- Modify: `tools/dev/nanogram/editions.py`, `tools/dev/tests/test_editions.py`

**Interfaces:**
- Produces:
  - `product_fingerprint(app: Path) -> str`: sha256 over sorted `(relative path, size, st_mtime_ns)` of
    `Contents/Info.plist`, every Mach-O file in `Contents/MacOS`, `Contents/PlugIns/*.appex/Contents/MacOS`,
    `Contents/Frameworks/*.framework/Versions/A/<name>`, and every `_CodeSignature/CodeResources` in the bundle.
  - `fingerprint_file(configuration: str, edition: str) -> Path` = `APPS_DIR / f"{configuration}-{edition}.fingerprint"`.
  - `main`: with `--products`, compute the fingerprint of the **built** app first; if it equals the stored one and
    `stashed_app(configuration, edition)` exists → print `editions: <edition> ok (unchanged since the last check)`, return 0
    without stashing or inspecting. Otherwise stash, check, and write the fingerprint only when the check passed.

- [ ] **Step 1: Write the failing tests**: `test_unchanged_product_skips_check` (patch `inspect_app` to raise if called),
  `test_relinked_binary_rechecks` (touch the main executable → `inspect_app` called),
  `test_failed_check_does_not_write_fingerprint`, `test_edition_switch_rechecks` (mas fingerprint does not satisfy direct).
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_editions.py -v` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; a no-change `tg build` prints the "unchanged" line and the editions step takes < 0.5 s
  (was 4.4–8.6 s).
- [ ] **Step 5: Commit** `editions: skip the bundle check when the built app did not change`.

### Task 9: Fast Debug configuration, Release untouched

**Files:**
- Modify: `nanogram/Nanogram.xcconfig`, `tools/dev/nanogram/buildcheck.py`, `tools/dev/tests/test_buildcheck.py`

**Interfaces:**
- Adds to `Nanogram.xcconfig`, after the existing Debug lines:
  ```
  DEBUG_INFORMATION_FORMAT[config=Debug] = dwarf
  SWIFT_COMPILATION_MODE[config=Debug] = singlefile
  GCC_OPTIMIZATION_LEVEL[config=Debug] = 0
  ENABLE_MODULE_VERIFIER[config=Debug] = NO
  LM_SKIP_METADATA_EXTRACTION[config=Debug] = YES
  ```
- `buildcheck.DEBUG_FORBIDDEN_TASKS = ("VerifyModule", "GenerateDSYMFile", "ExtractAppIntentsMetadata")`;
  `check_log(log, release=False)` reports `"<task> ran in a Debug build"` for each forbidden task line in a Debug log.

- [ ] **Step 1: Write the failing tests** in `test_buildcheck.py`: `test_debug_log_with_verify_module_rejected`,
  `test_debug_log_with_app_intents_extraction_rejected`, `test_release_log_may_verify_modules`,
  `test_stage2_settings_are_debug_only` (every line added by stage 2 to `nanogram/Nanogram.xcconfig` that sets one of the
  five keys above carries `[config=Debug]`), `test_release_lines_unchanged` (the five Release lines from Global
  Constraints are present verbatim).
- [ ] **Step 2: Run** `python3 -m unittest tools/dev/tests/test_buildcheck.py -v` → FAIL.
- [ ] **Step 3: Implement** the xcconfig lines and the buildcheck rule.
- [ ] **Step 4: Verify on a real build** (via buildlock, `build-output/stage2/task9/`): `tg build --clean` (Debug) and
  then a no-change `tg build`: `VerifyModule`, `GenerateDSYMFile`, `ExtractAppIntentsMetadata` counts are 0 in both
  timing summaries. If `LM_SKIP_METADATA_EXTRACTION` does not remove the `ExtractAppIntentsMetadata` tasks, delete that
  line and that task name from `DEBUG_FORBIDDEN_TASKS` and record the finding in the docs; do not search for other
  settings. Launch the Debug app (`open` the stashed `Nanogram.app`), confirm the process is alive after 15 s and the
  window shows the login screen, quit it. Do not log in.
- [ ] **Step 5: Release check**: `tg build --release` succeeds and buildcheck's Release rules (`-O3`, ThinLTO) still pass;
  `grep -c VerifyModule` in the Release log is unchanged from before this task.
- [ ] **Step 6: Commit** `xcconfig: fast Debug settings (no module verifier, no App Intents extraction)`.

### Task 10: Compilation caching — measure, then adopt or reject

**Files:**
- Modify (only if adopted): `nanogram/Nanogram.xcconfig`
- Create: `build-output/stage2/task10/result.md` (not committed; its numbers go into the docs in Task 11)

**Interfaces:**
- If adopted, these lines (Debug only, CAS shared by all checkouts):
  ```
  COMPILATION_CACHE_ENABLE_CACHING[config=Debug] = YES
  COMPILATION_CACHE_CAS_PATH[config=Debug] = $(HOME)/.cache/nanogram-macos/CompilationCache
  COMPILATION_CACHE_LIMIT_SIZE[config=Debug] = 10G
  ```

- [ ] **Step 1**: Check `df -h /System/Volumes/Data` ≥ 30 GB free, otherwise stop and report.
- [ ] **Step 2: Cold**: pass the three settings on the command line (`tg build --clean -- COMPILATION_CACHE_ENABLE_CACHING=YES …`),
  record wall, `uptime`, `/usr/bin/time -l` CPU, the timing summary, `du -sh` of the CAS.
- [ ] **Step 3: Warm**: `tg clean`, the same build again; record the same numbers. Then a no-change build with the settings.
- [ ] **Step 4: Decide**: adopt only if warm clean CPU (timing-summary SwiftCompile + CompileC + SwiftEmitModule seconds)
  is ≤ 50 % of cold, the no-change build costs ≤ 3 CPU s more than without caching, and the CAS stays ≤ 10 GB.
  If `COMPILATION_CACHE_LIMIT_SIZE` is not honoured (CAS above the cap), reject.
- [ ] **Step 5**: If adopted, add the lines, extend `test_stage2_settings_are_debug_only` to them, run
  `tools/dev/tests/run.sh`, and commit `xcconfig: shared compilation cache for Debug builds (measured)`. If rejected,
  delete `~/.cache/nanogram-macos/CompilationCache` and commit nothing; the numbers go into Task 11's docs.

### Task 11: Package 2 docs and measurements

**Files:**
- Modify: `docs/local-development.md` (add "## Day-to-day build speed" after "### Building from Xcode")

- [ ] **Step 1: Measure** (via buildlock, `build-output/stage2/task11/`, three runs each, wall + `uptime` + CPU + timing
  summary): no-change `tg build`; ChatUI body edit by trailing comment (comparable with the baseline) **and** by changing a
  string literal in `packages/ChatUI/Sources/ChatUI/BigEmojiMessage.swift` (exercises link + sign), each followed by the
  restoring build; record per-phase seconds with the timestamped log method of `build-output/stage2-baseline/*.ts.log`.
- [ ] **Step 2: Write "## Day-to-day build speed"**: why `tg build` fixes its arguments and environment (and that Xcode UI
  builds and raw `xcodebuild` keep their own descriptions), what `build description: recreated` means, the Debug settings
  and why, the compilation-cache verdict, the rejected options from the Decisions table, and the measured numbers.
- [ ] **Step 3: Commit** `docs: day-to-day build speed, measured`.

---

## Task 12 (after both packages are merged): Re-measure the full baseline table

**Files:**
- Modify: `docs/local-development.md` (one table in "## Day-to-day build speed": baseline vs stage 2)
- Modify: `docs/superpowers/specs/2026-11-02-nanogram-macos-design.md` (append "Stage 2 result" under the baseline table)

- [ ] **Step 1**: `df -h /System/Volumes/Data` ≥ 30 GB, otherwise `tg prune` (with the owner's OK for other checkouts) or stop.
- [ ] **Step 2: Measure, each via buildlock, recording wall, `uptime` before/after, CPU and the timing summary**, logs in
  `build-output/stage2/after/`:
  1. Native libraries: warm cache into an empty state (Task 3 step 3) and `tg frameworks --no-cache` (full arm64 build).
  2. Clean debug: `tg clean --all && tg build` — wall, CPU, DerivedData size.
  3. No-change `tg build` (×3).
  4. ChatUI body edit (comment and string literal) + restore (×2 each).
  5. TGUIKit public API edit: add `public func nanogramStage2Probe() {}` to a TGUIKit source file, build, remove, build
     (baseline 222 s, 2,845 files).
  6. Clean release: `tg clean && tg build --release` — wall, CPU, DerivedData size.
  7. App size: `du -sh` of the Release app, its main binary and the share extension (baseline 610 MB universal).
  8. Disk for one checkout: sources, native libraries (build dirs + cache set), Debug and Release DerivedData; `tg prune --dry-run`.
- [ ] **Step 3**: Write the table (rows as in the spec's baseline table; columns: upstream baseline, stage 2, load during
  the run) into both documents. Where load was ≥ 20, mark the wall time as loaded and lead with CPU seconds.
- [ ] **Step 4**: Check free space; if below 30 GB, delete this checkout's DerivedData (`tg clean --all`).
- [ ] **Step 5: Commit** `docs: stage 2 build time and disk, re-measured against the baseline`.
