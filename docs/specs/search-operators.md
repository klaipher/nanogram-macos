# Search operators (in-chat search)

The grammar is shared by iOS, Mac and Android. The iOS repository owns it: `docs/specs/search-operators.md` in
klaipher/nanogram, with the test vectors that every app ports. This file is only a pointer plus the Mac's own choices.
Parser: the iOS core's `NanogramFeatures` module, compiled here through `packages/NanogramFeatures` (symlinks; one implementation).
The Mac keeps the switch and the type list in `NanogramRuntime/SearchOperatorOptions.swift`. Tests: the core's `SearchOperatorsTests`
(NanogramFeatures package) and `NanogramRuntimeTests/LinkSearchOptionsTests` (the shared vectors, `data/search-operator-vectors.json`
in klaipher/nanogram-deps). A query without operators comes back whitespace-normalized (iOS behaviour).

## Mac choices inside the shared grammar

- Types: photo, video, file, link, voice, music, gif, round, poll, pinned. `contact`, `geo` and `mention` stay plain text
  (no `MessageTags` mapping used here).
- `from:` resolves `me` to the signed-in account and a username-shaped name (5-32 letters, digits, `_`, first a letter) with
  `resolvePeerByName`. A quoted display name, a numeric id or a name that does not resolve leaves the whole token in the
  search text, so the search never gets wider than the words typed. The search runs again once the lookup answers.
- Secret chats search locally and have no server filters: operators are not applied there.
- An empty range (`min >= max`, for example `date:` before `after:`) returns no results.
