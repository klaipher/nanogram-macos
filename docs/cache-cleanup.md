# Cache cleanup (iOS and Mac)

One implementation, `tools/dev/cachegc/cachegc.py`, and one configuration, `tools/dev/cachegc/cache-policy.json`, identical in both repos (`tg cache-cleanup verify` fails when they differ, or when `.bazelrc` / `Nanogram.xcconfig` disagree with the policy). Stale build caches clean themselves up; nothing runs on a schedule (no launchd agent, no cron, no daily job).

## When it runs

- Automatically after `tg build`, `test`, `check`, `warnings`, `frameworks`, `testflight`, `release-direct`, `core-bump` (Mac) and `tg build`, `test`, `run`, `device`, `testflight`, `watch`, `project` (iOS). It is throttled (at most once per 30 minutes), time-boxed (25 s) and never changes the exit status of the command.
- By hand: `tg cache-cleanup [--dry-run] [--only a,b]`, `tg cache-cleanup report` (sizes), `tg cache-cleanup verify`. The Mac `tg prune` runs it too.
- Log: `~/.cache/nanogram-macos/cachegc.log` (what was removed, why, how much); throttle state in `cachegc-state.json`.

## What it handles

| Category | Removed when |
|---|---|
| `bazel-output-base` | `~/Library/Caches/bazel/_bazel_$USER/<hash>` whose workspace path no longer exists (deleted worktree or clone), no Bazel server for it, not touched in 2 hours, volume mounted |
| `derived-data` | `~/Library/Developer/Xcode/DerivedData/<Name>-<hash>`: its checkout is gone, or unused 14 days (age rule waits while xcodebuild or Xcode runs) |
| `module-cache` | `DerivedData/ModuleCache.noindex` over 3 GB, no build tool running |
| `compilation-cache` | the Xcode CAS (`~/.cache/nanogram-macos/CompilationCache`) over 10 GB, removed as a whole, no build running, no build lock held |
| `spm-build` | `.build` next to a `Package.swift` inside either repo or one of its worktrees, unused 7 days, no process working inside it. `tg test` now builds under `--scratch-path` in the cache root, so new ones do not appear |
| `spm-scratch` | `~/.cache/nanogram-macos/spm-*` unused 7 days, then least recently used down to 20 GB |
| `instruments` | `$TMPDIR/instruments*.ktrace` older than 1 hour with no open handle |
| `build-output` | Mac `build-output/{testflight,direct}/<build>`: released builds are never touched; the newest 3 unreleased per edition stay. Loose logs older than 14 days |
| `simulator` | `xcrun simctl delete unavailable` (at most daily) |
| `worktree` | git worktrees of both repos whose branch is merged into the base branch, clean, unlocked, unused 14 days, nobody working in them; dangling records are pruned |
| `tool-tmp` | `nanogram-*`, `tg-*`, `frameworks-*`, `casprobe*` in the cache root `tmp` and `$TMPDIR`, older than 2 days and not mentioned by a running process |

A build counts as released when its folder has a `.released` marker (written when `tg testflight` uploads), a git tag ends with `-<build>`, or `CHANGELOG.md` mentions the build number. Released archives and dSYMs are kept forever; the iOS dSYM archive (`~/Library/Application Support/Nanogram/dsyms`) is never touched and `tg testflight` no longer prunes it (`TG_DSYM_KEEP=0` is the default).

The Bazel disk cache is not touched by hand: Bazel trims it itself (`--experimental_disk_cache_gc_max_size=30G`, `--experimental_disk_cache_gc_max_age=14d` in `.bazelrc`, equal to the policy).

## Hard safety rules

- Only paths inside the known roots (cache root, Bazel user root, Xcode DerivedData, `$TMPDIR`, the two repos and their worktrees) are removed, never a root itself; worktrees only under the repos' parent directory or `/tmp`.
- Never `launch-home` (the signed-in test profile), the Sparkle keys, `~/Library/Application Support/Nanogram`, or any ancestor of them.
- Nothing in use: build locks, running bazel/xcodebuild/swift processes, open handles, working directories of processes.
- Every removal is checked a second time right before it runs, and `--dry-run` lists what would go.
- Tests for the selection logic: `tools/dev/tests/test_cachegc.py`.

## Compilation cache (Xcode 27)

Debug builds use compilation caching with one CAS for every checkout. `tg build` creates the CAS directory before a Debug build, so it exists even before the first cached compile. `COMPILATION_CACHE_LIMIT_SIZE` is set in bytes; `xcodebuild -showBuildSettings` reports `0` for the target whenever caching is on (observed 2026-11-04 with Xcode 27.2; whether the compiler then applies the value is not verified), so the 10 GB cap is also enforced by the `compilation-cache` category above.
