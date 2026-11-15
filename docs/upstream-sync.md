# Upstream sync dry run

`tg upstream-sync --tag <upstream tag>` answers, before any merge: which files conflict (grouped by area), and which pinned dependencies upstream bumped (tgcalls, webrtc, tlottie, mtproto-engine, ...) and whether upstream's new commits are already in our fork branches.

The real merge is `tg sync-upstream`; this is the read-only preview of it. The tool works in a scratch bare repository (it borrows this repo's objects through alternates): it fetches the tag shallowly, makes a synthetic commit of the release we are based on (config `base_commit`, 24295527, the 13.1 merge) and one of the new tag, and runs `git merge-tree --write-tree --merge-base=<old> main <new>` - a real three-way merge in memory. Nothing is checked out, pushed or fetched into this repository.

- Script: `shared/tools/upstream-sync/sync.py` (klaipher/nanogram-deps, one copy for iOS and Mac; `tg upstream-sync` calls it).
- Config: `tools/dev/upstream-sync/upstream-sync.json` (base commit and label, branch, areas, pins with upstream and fork URLs, `moved_libraries`: OpenSSL (BoringSSL now) and tg_owt (webrtc fork now)).
- Options: `--ours <branch>`, `--offline` (skip the fork checks), `--json`, `--fail-on-conflict`.
- After a release is merged, move `base_commit` to the commit that holds the new release tree.
- `tg setup` turns on `rerere`, so a conflict resolved once (DebugController, branding) is replayed on the next merge.
- Tests: `tests/test_upstream_sync.py` in klaipher/nanogram-deps (local repositories only) and `tools/dev/tests/test_shared_tools.py` (this repository's config loads).
