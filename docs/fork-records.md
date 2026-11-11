# Fork change records

Every repository we maintain keeps two files at its root. Identical text in both app repositories.

| Repository | Upstream | Our branch | CHANGELOG.md | NANOGRAM-CHANGES.md |
|---|---|---|---|---|
| klaipher/nanogram (iOS + shared core) | Telegram-iOS `release-*` tags | `main` (imports on `upstream`) | exists, private | new |
| klaipher/nanogram-macos | telegram-macos (released code only) | `nanogram/integration` | exists, private | `NANOGRAM.md` stays the overview, new `NANOGRAM-CHANGES.md` has the detail |
| klaipher/tgcalls | TelegramMessenger/tgcalls (`development`) | `nanogram-shared` (iOS + Mac) | new | new |
| klaipher/webrtc | ali-fareed/webrtc `M123` (the WebRTC tree Telegram-iOS builds) | `nanogram-security-fixes` | new | new |
| klaipher/tg_owt | macosswift/tg_owt `master`, with desktop-app/tg_owt `master` merged in | `nanogram-mac` | new | new |
| klaipher/rlottie | TelegramMessenger/rlottie | none: neither app builds it since 2026-11-11 (upstream 13.2 dropped it; the Watch app vendors its own copy) | kept for history | kept for history |
| klaipher/nanogram-releases | none (downloads and Sparkle feed) | `main` | public notes only | not needed |

klaipher/mperf and the other repositories under klaipher are not part of Nanogram.

## NANOGRAM-CHANGES.md

What differs from upstream, grouped by area, newest areas last. One entry per difference:

```
### <Area: a short name>
- What: the behaviour or code that differs.
- Why: the reason (security, battery, disk, build time, Mac support, branding).
- Where: paths, targets, commits (hashes of the introducing commits).
- Upstream: yes (could be sent as is) / partly / no (Nanogram-specific), and why.
- Sync: what to check when upstream moves (conflict-prone files, patches to re-apply, tests that pin it).
```

Header of the file: upstream URL, the upstream commit or tag the repository is currently based on, the branch that
carries our changes, and the date the file was last checked against `git diff <upstream>..<ours> --stat`.
Rules: describe the difference, not the history; delete an entry when the difference is gone; every Sync section
names a test or a command where one exists.

## CHANGELOG.md

Newest first. One heading per release or pinned state:

```
## <version> (<build number>) - <date> - <commit>
Source: branch @ commit; submodule pins (core, tgcalls, tg_owt, ...) with their previous values.
- <what changed and how>, with the commit hash.
```

Apps keep `## Unreleased` on top, filled by the integrator while merging branches (one bullet group per branch).
Forks without versions use the date and the commit of the head. Public repositories get short, high-level notes
instead (which part got better, never how).

## Keeping them current

1. The development pipeline (`docs/development-pipeline.md`) makes writing both files part of the fix, and the
   report of every round lists which entries were added.
2. `tools/dev/lint/changelog_reminder.py`, run by the pre-push hook of both app repositories, warns when a push
   changes product code and touches neither file. Forks have no hook; their `AGENTS.md` carries the same rule.
3. A submodule pin bump in an app repository is written up in that app's CHANGELOG.md with the old and new fork
   commit, and the fork's own CHANGELOG.md has the matching entry.
