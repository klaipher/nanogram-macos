# Search operators (in-chat search)

Status: the iOS repository did not have `docs/specs/search-operators.md` when the Mac was written (2026-11-14). The Mac
parser was written to the grammar in the owner's spec section 7 (`forks/specs/diagnostics-and-debug-round2.md`) and to
Mercurygram's behaviour (Android `MgSearchQuery`, desktop `mg_search_query`, reimplemented, not copied). If the iOS spec
appears with a different grammar, change the parser and this file together. Parser: `packages/NanogramRuntime/Sources/NanogramRuntime/SearchOperators.swift`.

## Grammar

The query is split on whitespace. A token `key:value` with a known key and a valid value is an operator and is removed
from the text; every other token (unknown key, invalid value, URLs, plain words) stays in the text. A query without any
valid operator is passed on unchanged, byte for byte. Keys are case-insensitive. A repeated operator: the last one wins.

| Operator | Value | Maps to |
|---|---|---|
| `from:` | `@username`, `username` (5-32 letters, digits, `_`, starts with a letter) or a numeric user id | `from_id` (a username is resolved first; if it does not resolve, the search returns nothing instead of widening) |
| `after:` | `YYYY-MM-DD`, `today`, `yesterday` | `min_date` = start of that day (inclusive) |
| `before:` | same | `max_date` = start of that day minus 1 s (exclusive) |
| `date:` | same | `min_date` = start of day, `max_date` = end of day |
| `type:` | see below | `MessagesFilter` (`MessageTags` on Apple) |

Dates are in the device time zone. Dates before 1970 or after 2038 are not operators. Several date operators intersect;
an empty range returns nothing.

`type:` values: `photo`, `video`, `file`, `link`, `voice`, `music`, `gif`, `round`, `poll`, `pinned`. Aliases: `photos`,
`image(s)`, `videos`, `files`, `doc`, `document(s)`, `links`, `url(s)`, `voicemessage`, `audio`, `gifs`, `roundvideo`,
`circle`, `polls`. Filters: photo, video, document, url, round_voice, music, gif, round_video, poll, pinned.

## Mac mapping

`ChatController` `searchRequest` parses the query when `search.operators` is on (default on; Nanogram Features > Search) and calls
`searchMessages(location: .peer(... fromId, tags, minDate, maxDate))` with the remaining text. `type:` replaces the
chat mode's tag mask; in a topic, it is the only tag. Tests: `NanogramRuntimeTests/SearchOperatorsTests`.
