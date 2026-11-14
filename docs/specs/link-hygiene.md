# Link hygiene

The list is shared by iOS, Mac and Android: `docs/specs/link-tracking-params.txt` (the iOS repo's file, copied here; the
rules are in the iOS `docs/specs/search-operators.md`, section "Link hygiene"). `LinkHygieneTests.testStandardListMatchesTheSharedDataFile`
compares `LinkHygiene.standardList` in `packages/NanogramRuntime/Sources/NanogramRuntime/LinkHygiene.swift` with the file.
When the iOS file changes, copy it here and mirror it into the Swift list.

## Rules

- `http` and `https` links only, when a link is OPENED or COPIED. Outgoing message text is never rewritten.
- Only parameters in the list are removed (exact names, `prefix*`, and `host|name` entries that also match subdomains).
  Names are compared case-insensitively and percent-decoded. The other parameters keep their order and bytes; the
  fragment stays; a query that becomes empty loses its `?`.
- Optional, separate: ask before opening `t.me` / `telegram.me` / `telegram.dog` / `telesco.pe` and `tg:` links.

Both switches are off by default (Nanogram Features > Links). Mercurygram's `MgUrlCleaner` (GPL-2.0) was the idea; the list is
the shared one, not Mercurygram's. Tests: `NanogramRuntimeTests/LinkHygieneTests`.
