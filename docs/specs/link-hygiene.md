# Link hygiene

One implementation for iOS and Mac: the iOS core's `NanogramFeatures` module (`submodules/telegram-ios/submodules/NanogramFeatures`),
compiled here through `packages/NanogramFeatures` (symlinks). The Mac keeps only the two switches and their defaults
(`packages/NanogramRuntime/Sources/NanogramRuntime/LinkHygieneOptions.swift`).

The list is `data/link-tracking-params.txt` in klaipher/nanogram-deps (`submodules/telegram-ios/shared/data/`), the one copy
for iOS, Mac and Android; the vectors are `data/link-hygiene-vectors.json` there. `LinkSearchOptionsTests` compares
`TrackingParameterList.standard` with the file and runs the vectors. The rules are in the iOS `docs/specs/search-operators.md`,
section "Link hygiene".

## Rules

- `http` and `https` links only, when a link is OPENED or COPIED. Outgoing message text is never rewritten.
- Only parameters in the list are removed (exact names, `prefix*`, and `host|name` entries that also match subdomains).
  Names are compared case-insensitively and percent-decoded. The other parameters keep their order and bytes; empty query
  items (`a&&b`) are kept; the fragment stays; a query that becomes empty loses its `?`.
- Optional, separate: ask before opening `t.me` / `telegram.me` / `telegram.dog` / `www.t.me` / `www.telegram.me` and `tg://`
  links. `telesco.pe` and a bare `tg:` are not Telegram links (iOS behaviour, owner decision 2026-11-15; the Mac used to
  count them).

Both switches are off by default (Nanogram Features > Links). Mercurygram's `MgUrlCleaner` (GPL-2.0) was the idea; the list is
the shared one, not Mercurygram's. Tests: the core's `LinkHygieneTests` (NanogramFeatures package) and `NanogramRuntimeTests/LinkSearchOptionsTests`.
