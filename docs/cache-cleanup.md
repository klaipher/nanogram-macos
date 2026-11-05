# Cache cleanup (iOS and Mac)

One implementation, `tools/dev/cachegc/cachegc.py`, and one configuration, `tools/dev/cachegc/cache-policy.json`, identical in both repos (`tg cache-cleanup verify` fails when they differ, or when `.bazelrc` / `Nanogram.xcconfig` disagree with the policy). Stale build caches clean themselves up; nothing runs on a schedule (no launchd agent, no cron, no daily job).

## When it runs

- **Before** every build command, `cachegc guard` (also `tg cache-cleanup guard`): `tg build`, `test`, `run`, `device`, `testflight`, `watch build|test` (iOS) and `tg build`, `test`, `check`, `warnings`, `testflight`, `release-direct` (Mac). It is not throttled and has a 60 s budget. It enforces the hard caps (stale and unused Bazel output bases and their servers, the Bazel disk cache, SwiftPM scratch, the cache root total) and the leftovers of deleted checkouts. Below `free_space_gb.soft` (50 GB free) it runs every rule with a 180 s budget. Below `free_space_gb.hard` (20 GB free) it prints what uses the space and exits 1, so the build does not start; `TG_ALLOW_LOW_DISK=1` overrides that. A broken cleanup never stops a build that has room.
- Automatically after `tg build`, `test`, `check`, `warnings`, `frameworks`, `testflight`, `release-direct`, `core-bump` (Mac) and `tg build`, `test`, `run`, `device`, `testflight`, `watch`, `project` (iOS). It is throttled (at most once per 30 minutes), time-boxed (25 s) and never changes the exit status of the command.
- By hand: `tg cache-cleanup [--dry-run] [--only a,b]`, `tg cache-cleanup report` (sizes), `tg cache-cleanup verify`. The Mac `tg prune` runs it too.
- Log: `~/.cache/nanogram-macos/cachegc.log` (what was removed, why, how much); throttle state in `cachegc-state.json`.

## What it handles

| Category | Removed when |
|---|---|
| `bazel-output-base` | `~/Library/Caches/bazel/_bazel_$USER/<hash>` whose workspace path no longer exists (deleted worktree or clone) and whose volume is mounted: removed at once, and a Bazel server still running for it is stopped first (SIGTERM, only after checking that the pid's command line is `bazel(` with this output base). Also a base whose worktree exists but that no Bazel command touched for `bazel_output_base_unused_days` (3) with no server running; it is rebuilt on demand, the disk cache keeps the work. The checkout the command runs in is never removed |
| `bazel-disk-cache` | `~/.cache/telegram-ios/bazel-disk-cache` over `caps_gb.bazel_disk_cache` (20 GB): the least recently used blobs under `ac/` and `cas/` go, down to 90% of the cap; blobs touched in the last 2 hours stay; nothing happens while Bazel's own garbage collection holds its lock. A missing blob is only a cache miss to Bazel. Bazel's own collection runs only after 5 idle minutes, so with builds back to back it never kept the cap |
| `derived-data` | `~/Library/Developer/Xcode/DerivedData/<Name>-<hash>` of our projects only (`derived_data_projects` in the policy: Telegram-Mac, Telegram, Nanogram, NanogramKit, TelegramShare; other Xcode projects are never touched): its checkout is gone, or unused 14 days (a directory named by a running command stays) |
| `module-cache` | `DerivedData/ModuleCache.noindex` over 3 GB, no build tool running |
| `compilation-cache` | the Xcode CAS (`~/.cache/nanogram-macos/CompilationCache`) over 12 GB (`caps_gb.compilation_cache`), removed as a whole, no build running, no build lock held. The LLVM store keeps two generations and so reaches about twice its limit; `COMPILATION_CACHE_LIMIT_SIZE` is therefore half the cap (6 GB), and `tg cache-cleanup verify` checks that rule |
| `spm-build` | `.build` next to a `Package.swift` inside either repo or one of its worktrees, unused 7 days, no process working inside it and no running command naming it. `tg test` now builds under `--scratch-path` in the cache root, so new ones do not appear |
| `spm-scratch` | `~/.cache/nanogram-macos/spm-<checkout>-<package>`: at once when its checkout no longer exists (a worktree of either repo, or a directory with a `.git` beside the repos or in `~/Projects/wt`), then unused 7 days, then least recently used down to 20 GB. The current checkout's scratch is kept |
| `cache-root` | `~/.cache/nanogram-macos/DerivedData-<suffix>` (tg's own, one per checkout; the name is the checkout's directory name without a `nanogram-macos` prefix) whose checkout is gone (Xcode's `info.plist` WorkspacePath is checked too) or unused 14 days; then, while the whole cache root is over `caps_gb.cache_root_total` (40 GB), the least recently used scratch, then DerivedData. Frameworks, the compilation cache, locks and tools count towards the total but have their own caps. If the list of checkouts cannot be read, the "checkout is gone" rules do nothing. `tg prune` (Mac) stays as the manual, older equivalent |
| `instruments` | `$TMPDIR/instruments*.ktrace` older than 1 hour with no open handle |
| `build-output` | Mac `build-output/{testflight,direct}/<build>`: released builds are never touched; the newest 3 unreleased per edition stay. Loose logs older than 14 days |
| `simulator` | `xcrun simctl delete unavailable` (at most daily) |
| `worktree` | git worktrees of both repos whose branch is merged into the base branch, clean, unlocked, unused 14 days, nobody working in them, and holding no `build-output/{testflight,direct}/<build>` (git ignores those, and `git worktree remove` would delete archives and dSYMs with the tree); dangling records are pruned |
| `tool-tmp` | `nanogram-*`, `tg-*`, `frameworks-*`, `casprobe*` in the cache root `tmp` and `$TMPDIR`, older than 2 days and not mentioned by a running process |

### In use is decided per directory

A directory is skipped when its path appears in a running command line, a process has its working directory inside it, or one of its locks is held: SwiftPM's `.lock` in a scratch directory, or the checkout's `build-<checkout>.lock` (which `tg build` holds shared). A running `xcodebuild` or `swift` somewhere else no longer blocks the rules; only the compilation cache and `ModuleCache.noindex` keep the machine-wide check. Sizes are not measured while planning: they are remembered between runs in `cachegc-sizes.json` (valid for 6 hours while the directory's newest top-level mtime is unchanged) and `du` runs only when a cap needs a number. Instruments traces the system will not release are reported once as refused and not tried again.

A build counts as released when its folder has a `.released` marker (written when `tg testflight` uploads), a git tag ends with `-<build>`, or `CHANGELOG.md` mentions the build number. Builds numbered before `released_unknown_before_build` (202611050000)
were made before the marker existed, so whether they were uploaded is unknown: they count as released and are kept. Released archives and dSYMs are kept forever; the iOS dSYM archive (`~/Library/Application Support/Nanogram/dsyms`) is never touched and `tg testflight` no longer prunes it (`TG_DSYM_KEEP=0` is the default).

Bazel also trims the disk cache itself when its server has been idle for 5 minutes (`--experimental_disk_cache_gc_max_size=20G`, `--experimental_disk_cache_gc_max_age=14d` in the iOS `.bazelrc`, equal to the policy). The iOS `.bazelrc` also sets `startup --max_idle_secs=1800` and `--shutdown_on_low_sys_mem` (the default keeps an idle server, and with it the output base, alive for 3 hours); `tg cache-cleanup verify` checks the number against `bazel_max_idle_secs`. Changing a startup option restarts each server once.

## Policy keys added for the guard

`free_space_gb` (`soft` 50, `hard` 20), `guard` (`time_budget_seconds` 60, `low_disk_budget_seconds` 180), `bazel_output_base_unused_days` (3), `bazel_max_idle_secs` (1800); `caps_gb.compilation_cache` is 12 (see above). The two repositories share the file, `verify` compares them.

## Worktrees: `tg worktree add` and `remove`

One module, `tools/dev/worktree/worktree.py`, the same in both repos. Nothing is built.

- `tg worktree add <name> [--branch B] [--from REF]` makes `~/Projects/wt/<ios|mac>-<name>` on branch `night/<name>` (or B, from REF). iOS: shallow submodules, symlinks to the main checkout's `build-system/dev-configuration.json` and `user.bazelrc`. Mac: submodules initialised with `--reference` to the main checkout's submodule clones (those clones get `extensions.preciousObjects`, so git never prunes the objects the worktrees borrow; this saves 0.5-0.9 GB per worktree), then `tg credentials`, `tg localfixes` and `tg frameworks` (the content-addressed native-library cache restores the libraries in seconds; no native rebuild). It prints the DerivedData, scratch and output-base paths the worktree will use.
- `tg worktree remove <name> [--force]` refuses a dirty worktree and commits that are on no remote (`--force` overrides these two), a worktree whose `build-output/{testflight,direct}/<build>` holds archives (move them out first; never overridden), a worktree a process is working in, and a checkout whose build lock is held. Then it deletes what the checkout made: iOS stops the Bazel server and deletes the output base (found by its `DO_NOT_BUILD_HERE` marker); Mac deletes `DerivedData-<suffix>`, `spm-<name>-*` (not those of a longer-named checkout such as `mac-integ` when removing `mac`) and Xcode's own `DerivedData/*` whose WorkspacePath is inside. It ends with `git worktree remove` and `prune`; the branch stays.
- A worktree removed by hand leaves the same things behind; the guard's orphan rules remove them on the next build.

## Hard safety rules

- Only paths inside the known roots (cache root, Bazel user root, Xcode DerivedData, `$TMPDIR`, the two repos and their worktrees) are removed, never a root itself; worktrees only under the repos' parent directory or `/tmp`.
- Never `launch-home` (the signed-in test profile), the Sparkle keys, `~/Library/Application Support/Nanogram`, or any ancestor of them.
- Nothing in use: build locks, running bazel/xcodebuild/swift processes, open handles, working directories of processes.
- Every removal is checked a second time right before it runs, and `--dry-run` lists what would go.
- Tests for the selection logic: `tools/dev/tests/test_cachegc.py`.

## Compilation cache (Xcode 27)

Debug builds use compilation caching with one CAS for every checkout. `tg build` creates the CAS directory before a Debug build, so it exists even before the first cached compile. `COMPILATION_CACHE_LIMIT_SIZE` is set in bytes; `xcodebuild -showBuildSettings` reports `0` for the target whenever caching is on (observed 2026-11-04 with Xcode 27.2; whether the compiler then applies the value is not verified), so the 10 GB cap is also enforced by the `compilation-cache` category above.
