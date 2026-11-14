# Mac stage A (W0.3, W2.I2, W3.5, W4.3, W5.4, W6, W7): what was compared before the Mac copies were deleted

Nothing here was built or run (no Xcode, SwiftPM, cargo or Bazel). Every item is a `cmp`, `diff`, blob or `git ls-tree` comparison, or a pure-Python test. The core checkout used for the comparisons is iOS `shared/w1` 7fa7bc80 (fetched locally into `submodules/telegram-ios`).

## W0.3: tooling copies

- `tools/dev/parity/parity.py` (804 lines) and the Mac `tests/test_parity.py` (693 lines) were the same code as `shared/parity.py` and `shared/tests/test_parity.py` of klaipher/nanogram-deps (the iOS lane moved it there at 6a07ce57); the Mac file is now a 29-line wrapper plus repository tests.
- `docs/feature-parity.md`, `docs/development-pipeline.md`, `tools/dev/cachegc/cache-policy.json` are byte-identical to `shared/feature-parity.md`, `shared/development-pipeline.md`, `shared/cache-policy.json` as of the iOS commit that deleted its own copies (the Mac copies were required to be identical to the iOS ones by the old sibling checks).
- `docs/mac-core-paths.txt` is `cmp`-identical to the iOS file at 7fa7bc80.
- `tools/dev/native/native-libs.json` = the iOS file at 7fa7bc80 with the Mac stage-A changes applied by `patch` (the diff c489f3fd..462d700e of the Mac file applied cleanly) plus the OpenH264 Mac probe moved to the core's `codec_ver.h`. The same file has to be copied into the iOS repository.

## libprisma glue (CodeSyntax)

- Deleted: `submodules/CodeSyntax/CodeSyntax/CodeSyntax/Syntaxer.h` and `Syntaxer.mm`. The fork's `apple/Syntaxer.{h,mm}` is the merged iOS and macOS glue. Every Mac hunk is in it: `diff` of the old Mac files against the fork files shows only (a) `SyntaxerColor`/`SyntaxerFont` typedefs replacing `NSColor`/`NSFont` under `TARGET_OS_OSX`, (b) `static` on the file-local helpers, (c) the Mac initializer `initWithDark:...themeKeys:` kept as is, plus the iOS initializer and `-init`, (d) `colors == nil` falls back to the built-in palette (iOS). The Mac API (`init:`, `initWithDark:textColor:textFont:italicFont:mediumFont:themeKeys:`, `syntax:language:theme:`) is unchanged.
- The pbxproj group now points at `third-party/libprisma/libprisma/libprisma` (the fork's C++ core, same eight files) and `libprisma/apple`; header search paths gain `boost_regex/regex/include` and `libprisma/libprisma/libprisma`; `BOOST_REGEX_MAX_BLOCKS=1536` is defined (the cap the iOS BUILD and Android use). `Telegram.xcodeproj` bundles `libprisma/libprisma/libprisma/grammars.dat`.
- `tools/dev/tests/test_libprisma_shared.py` compiles the pure C++ core with clang++ against the new paths and runs the iOS host test (`SyntaxHighlighterRecursionTests.cpp`): ALL PASS.

## OpenH264

- Old: `core-xprojects/OpenH264/OpenH264/build.sh` cloned pristine cisco/openh264 v2.7.0 (1bca6231) and asserted that sha.
- New: it rsyncs the core's `third-party/openh264/openh264` (klaipher/openh264 `nanogram` 3583f617 = v2.7.0 plus two commits) and asserts that the checkout equals the gitlink the core records. `git diff --stat 1bca6231 3583f617` is the 12 expected files (91 insertions, 11 deletions): H.264 level 6.0-6.2 and the subcodec sprite mode (off by default). Behaviour change for the Mac: it builds the fork instead of the pristine release; level 6.x encodes are possible, the sprite mode is not used.

## rnnoise and td headers

- `core-xprojects/rnnoise/` (an Xcode wrapper project) is deleted: nothing referenced it (`git grep rnnoise.xcodeproj` and `core-xprojects/rnnoise` have no hit), its group paths pointed at `third-party/rnnoise/{Sources,PublicHeaders}`, which no longer exist, and its file list (`rnn_reader.c`, `tansig_table.h`) named files that were not in the iOS tree even before. The Mac links rnnoise through the SwiftPM package `submodules/telegram-ios/third-party/rnnoise` (`rnoise`), which the iOS stage rewrote to read the fork (`rnnoise/src`, `rnnoise/include`).
- `scripts/configure_frameworks.sh` syncs the rnnoise header from `third-party/rnnoise/rnnoise/include` and no longer syncs td headers into `third-party/td/TdBinding/SharedHeaders/td` (the iOS stage made `td-headers` an in-package link; `shared-libraries.json` lists SharedHeaders under `dropped`).

## W3.5: twidget, widget-sandbox, QuickJS

- `.gitmodules`: `third-party/twidget` and `third-party/widget-sandbox` were TelegramMessenger/twidget and widget-sandbox (`main`, pinned cc044e7b and 015392fd). They are now klaipher/twidget and klaipher/widget-sandbox, branch `nanogram`, at the commits iOS pins (a4f5391c and 1b21a48e; `git ls-files -s` shows both gitlinks). The fork records (their `NANOGRAM-CHANGES.md` and `CHANGELOG.md`) hold the proof that the Mac commits cc044e7b/015392fd were carried, as the plan's W3.2 and W3.3 require; the widget-sandbox fork's own gitlink moves the nested QuickJS to klaipher/quickjs `nanogram` f6fc68b9.
- `WIDGET_QUICKJS_PATH`/`WIDGET_QUICKJS_COMMIT` and `pin_checkout` are deleted from `tools/dev/nanogram/localfixes.py` with their tests (the pin b526a817 is the base of klaipher/quickjs, which carries it plus the iOS changes); `release.LOCAL_PINS` is empty.
- The fork's SwiftPM packages keep the product names the Mac packages use (`LiteHTML`, `HTMLScript`, `HTML3D`, `TwidgetRenderer`, `TwidgetIcons`, `Twidget3DSandbox`; `WidgetSandbox`, `WidgetSandboxProtocol`): `git show a4f5391c:Package.swift` and `1b21a48e:Package.swift` list them, and `packages/{ChatUI,HTMLBubbles,WidgetEngineXPC,WalletUI}/Package.swift` need no edit (they still point at `../../third-party/{twidget,widget-sandbox}`). twidget's own manifest finds widget-sandbox as `../widget-sandbox`, which is the Mac layout.
- twidget moved its sources from `Sources/` to `apple/Sources/` between cc044e7b and a4f5391c: the only live Mac script that read them, `tools/tests/widget-v013/run.py`, now reads `third-party/twidget/apple/Sources/TwidgetRenderer/...` (both files exist in the fork at a4f5391c).
