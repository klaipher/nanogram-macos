# NanogramFeatures

Pure logic of Settings > Nanogram Features that both apps share: in-chat search operators (`SearchOperators.parse`) and
link hygiene (`LinkHygiene.strippingTracking`, `isTelegramLink`, the tracking-parameter list).

`Sources` and `Tests` are symlinks into the iOS core: `submodules/telegram-ios/submodules/NanogramFeatures/{Sources,Tests}`.
There is no copy here; a fix lands once in the iOS repository and reaches the Mac with the next core bump. The behaviour is
the iOS behaviour on both apps: `www.t.me` is a Telegram link, `telesco.pe` and a bare `tg:` are not, empty query items
are kept, and a query without operators comes back whitespace-normalized.

What stays on the Mac lives in `NanogramRuntime` (`LinkHygieneOptions.swift`, `SearchOperatorOptions.swift`): the
`NanogramDebugOption` switches, their defaults, and the Mac's supported operator types. The shared tracking list and the
shared test vectors are `data/link-tracking-params.txt`, `data/link-hygiene-vectors.json` and
`data/search-operator-vectors.json` in klaipher/nanogram-deps (`submodules/telegram-ios/shared/data/`);
`NanogramRuntimeTests/SharedLinkSearchDataTests.swift` runs the Mac against them.
