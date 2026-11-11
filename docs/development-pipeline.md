# Development pipeline

How work gets done in Nanogram (iOS and macOS, developed together by the owner with many parallel agents in git
worktrees). The short version is in `AGENTS.md`; this is the full text. Identical in both repositories.

## Roles and limits

- One owner. Agents work in their own worktree and branch, never in a main checkout.
- Few, well-scoped agents. Batch work into a handful of lanes rather than a large fan-out. Subagents run on Sonnet;
  reviewers that decide whether a finding is real run on Opus.
- Do not block on the owner. If a question has no answer when the work needs it, take the safe default, write the
  decision down, and move on (owner-dependent tests are skipped and listed as open questions).

## The stages

1. **Research and review in parallel lenses.** One agent per lens (for example correctness, security, performance,
   shared-code parity, docs). Each writes findings with evidence (file:line, command output, a measurement), not
   opinions. Findings go in the report, not in new markdown files in the repository.
2. **Adversarial verification.** A separate agent tries to disprove each finding: read the code path, find the
   caller that makes it impossible, or reproduce it with a test. Only CONFIRMED findings continue; PLAUSIBLE ones are
   listed as open questions.
3. **Fix every confirmed finding on a branch, tests first.** Branch name `night/<lane>` (or `fix/`, `perf/`, `sec/`
   by topic), one worktree per branch under `~/Projects/wt/`. Write the failing test, then the fix. Prefer tests that
   need no build of the app: pure Python (`tools/dev/tests`, `tools/dev/lint/tests`), host `cc_test`/`swift_test`
   targets on iOS, SwiftPM package tests on the Mac. A fix with no possible test says why in its commit message.
4. **Agents do not build.** No `tg build`, `xcodebuild`, `bazel build`, `swift build/test`, `tg check/test/warnings`
   and no app launches during stages 1-3. Compiling is the slowest and most disk-hungry step on this machine
   (antivirus costs about two cores while building), and a build per agent is the cause of most of our disk and CPU
   trouble.
5. **One combined build per platform, at the end.** Merge the lane branches into the integration branch
   (the iOS repository's integration branch, the Mac's `nanogram/integration`), then build the iOS and
   the Mac app once each. Shared fixes must be in both builds (see "Shared code" below).
6. **Fix what the build shows.** Compile errors, warnings over the baseline, failing package tests. These fixes
   are small commits on the integration branch; if a fix needs a design change, it goes back to stage 3.
7. **Push through the hooks.** `git push` runs the pre-push hook (`tools/dev/lint/tglint.py`: lint of the pushed
   lines, parity checks, tests of the touched modules, and the change-record reminder). Never `--no-verify`. If a
   hook is wrong, fix the hook in the same push series and say so in the report.
8. **Report.** What was found, what was fixed, what was not (and why), decisions taken and their trade-offs, and
   questions for the owner. Findings carry their evidence. Releases and TestFlight builds also get their changelog
   (see "Change records").

## Shared code

The two apps share the Telegram core, the tgcalls/WebRTC stack and libprisma. A fix in shared code lands
in both repositories in the same round: the iOS repo owns the core (`docs/mac-core-paths.txt` lists the shared paths,
`tools/dev/parity/parity.py` checks them), and the Mac consumes it through `submodules/telegram-ios` (`tg core-bump`).
tgcalls fixes also go through `tools/dev/tgcalls-port`. A push that touches shared paths prints a reminder; do not
dismiss it.

## Rules that never bend

- Marketing version follows upstream (iOS 13.1.2 at the time of writing). Only the build number changes.
- Never fetch upstream tags or branches into our repositories by hand; `tg sync-upstream` is the only way upstream
  code enters, and only released code.
- No scheduled or background jobs (no launchd, cron, daily tasks). Cleanup runs inline after build commands.
- Never read signing secrets, keychains or `~/.config/telegram-ios`; credentials are read by the tools only.
- Never `--no-verify`, never force-push shared branches.
- Comments in code: the Mac repo allows none except task markers; the iOS repo documents public APIs only.

## Change records

Every repository we maintain (the two apps and each fork) keeps two files at its root, written as part of the
change, not afterwards:

- `CHANGELOG.md`: newest first. Per entry: date, build number/version if any, commit, what changed and how.
  Apps keep an `## Unreleased` section that integrators fill while merging branches.
- `NANOGRAM-CHANGES.md`: how this repository differs from upstream, area by area: what differs, why, where
  (paths), whether it could go upstream, and notes for syncing with upstream. Updated whenever a change adds,
  removes or moves a difference.

See `docs/fork-records.md` for the format and the list of repositories. The pre-push hook warns when a push changes
product code and the pushed range touches neither file (`TG_CHANGELOG_STRICT=1` makes it block). Public places
(klaipher/nanogram-releases, GitHub release bodies, the Sparkle appcast) get short, high-level notes only: which
part got better, never how. TestFlight builds get a "What to Test" changelog written after upload.

## Disk and worktree hygiene

The machine has 460 GB; each Bazel output base is 8-29 GB, each Mac DerivedData 6-14 GB, each SwiftPM scratch
directory up to 3.8 GB. All of it is per checkout, so worktrees are expensive.

- Make a worktree only when a branch needs one. Keep them under `~/Projects/wt/`. Prefer a few long-lived lane
  worktrees over one per small fix; a doc or tooling change needs no build output at all.
- Before removing a worktree: stop its Bazel server (`bazel shutdown` run inside it; a live server keeps its output
  base from being cleaned), then `git worktree remove`. Never `rm -rf` a worktree directory.
- After removing worktrees, run `tools/dev/tg cache-cleanup` (see `docs/cache-cleanup.md`): it removes output
  bases, DerivedData and SwiftPM scratch whose checkout is gone. It also runs by itself, throttled, after build
  commands; nothing is scheduled.
- Check space with `tools/dev/tg disk` and `tools/dev/tg cache-cleanup report`. The caps live in
  `tools/dev/cachegc/cache-policy.json` (Bazel disk cache 20 GB, Xcode compilation cache 10 GB, SwiftPM scratch
  20 GB). Do not edit `.bazelrc` or the xcconfig caps without editing the policy; `tg cache-cleanup verify` fails
  when they disagree.
- Below 50 GB free: stop starting builds, clean up first.
