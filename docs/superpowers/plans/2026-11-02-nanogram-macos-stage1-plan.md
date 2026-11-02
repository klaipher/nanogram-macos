# Nanogram for macOS — Stage 1 Implementation Plan (fork, update, modernize, strict)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A private fork `klaipher/nanogram-macos` that builds Nanogram for macOS (Apple Silicon, macOS 15+, Xcode 27) from a fresh clone with one command, with current dependencies, a strict-by-default layer for our code, a tracked warning baseline for upstream code, two signed editions (TestFlight and direct), and a repeatable upstream sync.

**Architecture:** Upstream files stay as close to pristine as possible. Our settings live in one xcconfig passed from outside (`-xcconfig` / `XCODE_XCCONFIG_FILE`) plus command-line build settings, so they reach the app, the workspace subprojects and every SwiftPM package without editing their manifests. Our Swift code lives in new strict packages wired in through upstream's hook pattern. A thin bash `tools/dev/tg` dispatches to tested Python modules in `tools/dev/nanogram/`.

**Tech Stack:** Xcode 27.2 / Swift 6.x, SwiftPM local packages, bash + Python 3 (stdlib, `unittest`), SwiftLint 0.65.1 (via tglint), cargo/rustup (toolchain 1.96.1 pinned upstream), App Store Connect API key with `xcodebuild -exportArchive`, `xcrun altool`, `xcrun notarytool`.

**Spec:** `docs/superpowers/specs/2026-11-02-nanogram-macos-design.md`

**Reference material:** `~/Projects/nanogram-macos-recon/src` (upstream checkout with baseline logs in its parent folder); recon maps in the session scratchpad (`map-*.md`) are summarized where tasks need them. iOS fork tooling to port: `~/Projects/Telegram-iOS/tools/dev/{tg,device_signing.py,lint/}` at commit `5ac4d079`.

## Global Constraints

- Upstream: `https://github.com/TelegramMessenger/telegram-macos.git`, branch `master`. Remote name `telegram`; snapshot branch `upstream`; our branch `main`.
- Repo `klaipher/nanogram-macos`, private. GPL-2.0 stays.
- Bundle ID `org.klaipher.Nanogram` (same App Store Connect app 6829268176, universal purchase). Share extension `org.klaipher.Nanogram.MacShare`. Team `YGTMYL879P`. App group `YGTMYL879P.org.klaipher.Nanogram` (one group, shared by both editions).
- App name "Nanogram"; icon = Nanogram dark Comet (fill `srgb(0.06667, 0.09020, 0.13333)`, mark `#508FFF`).
- Architectures: `arm64` only. Minimum macOS: `15.0`. Xcode: 27.x only.
- Editions: `mas` (sandboxed, TestFlight/App Store, no Sparkle) and `direct` (Developer ID, hardened runtime, notarized, Sparkle with EdDSA). Neither defines `APP_STORE`. Both define `NANOGRAM`; `mas` also defines `NANOGRAM_MAS`.
- Release builds: Swift `-O` + whole-module, C/C++/ObjC `-O3`, `LLVM_LTO = YES_THIN`, dead stripping. Debug builds: `-Onone`, no LTO.
- Strictness A: our packages = Swift 6 language mode, complete concurrency, warnings as errors. Upstream code = warnings only, counted per package in `nanogram/warnings-baseline.json`; a count may only go down, except the baseline update made by `tg sync-upstream`.
- Secrets never enter the repo or logs: api_id/api_hash come from `~/.config/telegram-ios/api-credentials.json`; ASC key from `~/.config/telegram-ios/asc/`; Sparkle EdDSA private key and the measurement account live in `~/.config/nanogram-macos/`. Generated files holding secrets are gitignored. Never print `api_hash`.
- Nothing is published (GitHub release, appcast, upstream PR) without the owner's explicit OK for that item.
- Upstream code style rule from its AGENTS.md (no comments in upstream-style code) applies to edits inside upstream files; our own files may carry short comments.

## Review Focus

1. **Fresh clone on a clean machine state:** `git clone --recurse-submodules` of our repo must succeed (no private submodules) and `tg setup && tg build` must work with only the documented prerequisites → Task 1 and Task 4 add `tests/test_fresh_clone.sh` run in a temp dir.
2. **Upstream sync touching the same files we touched** (pbxproj, `Config.swift`, entitlements, build scripts): the sync must stop with a clear conflict list, never auto-resolve silently → Task 13 test `test_sync_reports_conflicts`.
3. **Two editions installed on one Mac at once (same bundle ID, shared group):** only one may run at a time and data must not be corrupted → Task 7 test `test_single_instance_across_editions` (launch direct, launch mas, assert the second exits and activates the first).
4. **Missing secrets/config** (no api-credentials.json, no ASC key, no Developer ID cert): every command fails early with one actionable line, never a half-built or wrongly signed app → Task 2 `test_doctor_missing_config`, Task 6 `test_credentials_missing_fails`.
5. **Settings layer silently not reaching packages** (deployment target, arm64, conditions): a build that looks green but ships x86_64 slices or `macos12.0` objects → Task 3 `buildcheck` asserts on real build logs and on the final binary, and runs inside `tg check`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `nanogram/Nanogram.xcconfig` | Our build settings for every target (deployment, arch, optimization, conditions) |
| `nanogram/editions/{mas,direct}.xcconfig` | Edition-specific settings (entitlements, signing, Sparkle feed/key), each `#include "../Nanogram.xcconfig"` |
| `nanogram/entitlements/{Nanogram-MAS,Nanogram-Direct,NanogramShare}.entitlements` | Our entitlements |
| `nanogram/warnings-baseline.json` | Warning counts per upstream package |
| `nanogram/ffi-patches/` | Patches we must keep on upstream build scripts, each with a one-line reason (none expected at first) |
| `packages/NanogramKit/` | Our strict Swift package: branding hook, endpoint overrides, single-instance guard, credentials accessor |
| `tools/dev/tg` | Bash dispatcher (`cmd_*`), no logic beyond argument parsing |
| `tools/dev/nanogram/*.py` | Logic: `config.py`, `doctor.py`, `frameworks.py`, `buildcheck.py`, `warnings.py`, `credentials.py`, `release.py`, `sync.py` |
| `tools/dev/lint/` | tglint port (`tglint.py`, `swiftlint.yml`, `pre-push`) |
| `tools/dev/tests/` | `unittest` suites for all of the above (+ fixtures) |
| `docs/local-development.md` | How to build, run, sync, release |
| `docs/superpowers/{specs,plans}/` | Design and plans |

---

### Task 1: Create the fork repository

**Files:**
- Modify: `.gitmodules` (remove `third-party/twidget`, `third-party/widget-sandbox`, `submodules/libtgvoip`)
- Delete: gitlinks `third-party/twidget`, `third-party/widget-sandbox`, `submodules/libtgvoip`; `.claude/settings.local.json`
- Modify: `Telegram.xcodeproj/project.pbxproj` (drop `$(PROJECT_DIR)/submodules/libtgvoip` from `HEADER_SEARCH_PATHS` at the two lines found by grep; drop the dangling `libtgvoip.framework` file references)
- Create: `docs/superpowers/specs/2026-11-02-nanogram-macos-design.md`, `docs/superpowers/plans/2026-11-02-nanogram-macos-stage1-plan.md` (moved from the recon folder), `NANOGRAM.md` (one page: what this fork is, link to docs)
- Test: `tools/dev/tests/test_fresh_clone.sh`

**Interfaces:** Produces branches `upstream` (snapshot of `telegram/master`) and `main`; remote `telegram`.

- [ ] **Step 1:** `gh repo create klaipher/nanogram-macos --private --description "Nanogram for macOS (fork of Telegram for macOS)"`.
- [ ] **Step 2:** Clone upstream without submodules into `~/Projects/nanogram-macos`; rename remote `origin`→`telegram`; add `origin` = our repo; create `upstream` at `telegram/master` with a snapshot commit carrying trailers `Upstream-Commit: <sha>` (same shape as iOS `cmd_sync_upstream`); create `main` from it.
- [ ] **Step 3:** Write `test_fresh_clone.sh`: clones `origin/main` with `--recurse-submodules --jobs 8` into `mktemp -d`, asserts exit 0, asserts `submodules/rlottie/` and `submodules/tlottie/Cargo.toml` exist and non-empty, asserts no `third-party/twidget`.
- [ ] **Step 4:** Run it → FAIL (private submodules).
- [ ] **Step 5:** Apply the Files changes above; commit; push `main` and `upstream`.
- [ ] **Step 6:** Run `test_fresh_clone.sh` → PASS.
- [ ] **Step 7:** Commit `chore: fork Telegram for macOS as Nanogram; drop private and unused submodules`.

### Task 2: `tg` skeleton, config and doctor

**Files:**
- Create: `tools/dev/tg`, `tools/dev/nanogram/__init__.py`, `config.py`, `doctor.py`, `tools/dev/tests/test_doctor.py`, `tools/dev/tests/run.sh` (runs `python3 -m unittest discover -s tools/dev/tests` + `shellcheck -S warning tools/dev/tg tools/dev/lint/pre-push`)
- Create: `.gitignore` additions: `/build-output/`, `packages/ApiCredentials/Sources/ApiCredentials/NanogramSecrets.swift`, `nanogram/local.json`

**Interfaces:**
- Produces `config.py`: `ROOT: Path`, `CACHE_DIR = ~/.cache/nanogram-macos`, `DERIVED_DATA = CACHE_DIR/DerivedData`, `TG_IOS_CONFIG = ~/.config/telegram-ios`, `MAC_CONFIG = ~/.config/nanogram-macos`, `def xcode_version() -> str`, `def require_file(path: Path, hint: str) -> Path` (raises `ConfigError` with one actionable line).
- Produces `doctor.py`: `def run_doctor() -> list[Finding]`, `Finding(name: str, ok: bool, hint: str)`. Checks: Xcode major == 27, Metal toolchain installed, `cmake ninja meson` present, rustup present (via PATH or `/opt/homebrew/opt/rustup/bin`), submodules populated (rlottie, tlottie, telegram-ios), free disk ≥ 40 GB, `api-credentials.json` present, ASC key present (warn only), Developer ID / Apple Distribution identities (warn only).
- `tg` subcommands (wired in later tasks): `setup doctor frameworks build run test lint warnings check sync-upstream testflight release-direct`.

- [ ] **Step 1:** Write `test_doctor.py`: `test_doctor_missing_config` (point `TG_IOS_CONFIG` at an empty temp dir → finding `api-credentials` with `ok=False` and hint containing `api-credentials.json`); `test_doctor_xcode_mismatch` (monkeypatch `xcode_version` → "26.0" → not ok).
- [ ] **Step 2:** Run `tools/dev/tests/run.sh` → FAIL (module missing).
- [ ] **Step 3:** Implement `config.py`, `doctor.py`, and `tg` dispatcher (`say/warn/die`, `case` dispatch, `tg doctor` prints findings and exits 1 if any non-warn finding fails). `tg` exports `PATH=/opt/homebrew/opt/rustup/bin:$PATH` and `DEVELOPER_DIR` from `xcode-select -p`.
- [ ] **Step 4:** Run `run.sh` → PASS; `tools/dev/tg doctor` on this Mac → all required checks pass.
- [ ] **Step 5:** Commit `feat(tg): add dev tool skeleton with doctor`.

### Task 3: Settings layer (`Nanogram.xcconfig`) and build checks

**Files:**
- Create: `nanogram/Nanogram.xcconfig`, `tools/dev/nanogram/buildcheck.py`, `tools/dev/tests/test_buildcheck.py`, `tools/dev/tests/fixtures/build-debug-arm64.log` (trimmed real `swiftc`/`clang` lines), `fixtures/build-universal.log`
- Modify: `tools/dev/tg` (`cmd_build`)

**Interfaces:**
- `Nanogram.xcconfig` sets: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `ARCHS = arm64`, `VALID_ARCHS = arm64`, `ONLY_ACTIVE_ARCH = YES`, `SWIFT_ENFORCE_EXCLUSIVE_ACCESS = on` for packages is left at default; release-only via `[config=Release]`: `GCC_OPTIMIZATION_LEVEL = 3`, `LLVM_LTO = YES_THIN`, `DEAD_CODE_STRIPPING = YES`, `SWIFT_OPTIMIZATION_LEVEL = -O`, `SWIFT_COMPILATION_MODE = wholemodule`; `COMPILER_INDEX_STORE_ENABLE = NO` for CLI builds.
- Conditions are passed on the command line by `tg` (they must reach packages): `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) NANOGRAM STABLE` (+ `NANOGRAM_MAS` for mas).
- `buildcheck.py`: `def check_log(log: str) -> list[str]` (problems found) — every `swiftc`/`clang` compile line must target `arm64-apple-macos15.0` and none may mention `x86_64`; Release logs must show `-O3` for C and `-flto=thin` at link. `def check_binary(app: Path) -> list[str]` — `lipo -archs` == `arm64` for every Mach-O under the bundle; `LC_BUILD_VERSION minos` == 15.0 for the main binary.
- `tg build [--release] [--edition mas|direct]` runs `xcodebuild build -workspace Telegram-Mac.xcworkspace -scheme Telegram|Release -configuration Debug|Release -destination 'platform=macOS,arch=arm64' -derivedDataPath $DERIVED_DATA -xcconfig nanogram/editions/<edition>.xcconfig <conditions>`; tees the log to `build-output/last-build.log`; runs `buildcheck` on log and app; non-empty problems → exit 1.

- [ ] **Step 1:** Write `test_buildcheck.py`: `test_universal_log_rejected` (fixture with `-target x86_64-apple-macos12.0` → problem mentioning `x86_64`), `test_arm64_15_log_accepted` (fixture → `[]`), `test_old_min_version_rejected` (line with `arm64-apple-macos12.0` → problem).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `buildcheck.py`, the xcconfig (temporary `nanogram/editions/direct.xcconfig` = include only, completed in Task 7), `cmd_build`.
- [ ] **Step 4:** Run unit tests → PASS. Run `tg build` (after Task 4's frameworks exist; until then run on the recon frameworks copied into `core-xprojects/*/build`) → buildcheck passes. **Gate:** if `-xcconfig` does not reach SwiftPM package targets for `MACOSX_DEPLOYMENT_TARGET`/`ARCHS` (check a package's `swiftc` line), pass those two as command-line build settings instead and record the finding in `docs/local-development.md`.
- [ ] **Step 5:** Verify the Xcode UI path: `tg xcode` opens the workspace with `XCODE_XCCONFIG_FILE=nanogram/editions/direct.xcconfig` exported; document it.
- [ ] **Step 6:** Commit `feat(build): our settings layer — arm64, macOS 15, release optimization — with build checks`.

### Task 4: Native libraries — arm64 only, Xcode 27, Rust host fix

**Files:**
- Modify: `core-xprojects/OpenH264/build.sh:54-55,64`, `core-xprojects/openssl/OpenSSLEncryption/build.sh:150,185-187`, `core-xprojects/Mozjpeg/build.sh:63-64`, `core-xprojects/dav1d/build.sh:19-43` (+ delete `dav1d-x86_64.meson`), `core-xprojects/tde2e/build.sh:31-73`, `core-xprojects/wallet-engine/wallet-engine/build.sh:18,52-66,68`, `core-xprojects/mtproto-engine/mtproto-engine/build.sh:16,50-64`, `core-xprojects/tlottie/build.sh:11,53,70-73`, `core-xprojects/ffmpeg/build.sh:82-85`, `scripts/framework-inputs.sh:144-151` (`macos-arm64_x86_64` → `macos-arm64`), `scripts/framework-inputs.sh` stamp gains `archs=arm64` and `deployment=15.0` from our xcconfig
- Create: `tools/dev/nanogram/frameworks.py`, `tools/dev/tests/test_frameworks.py`
- Modify: `tools/dev/tg` (`cmd_frameworks`, `cmd_setup`)

**Interfaces:**
- `frameworks.py`: `def build_frameworks(timing_log: Path) -> None` runs `scripts/configure_frameworks.sh` with `XCODE_XCCONFIG_FILE=nanogram/Nanogram.xcconfig`, `CMAKE_POLICY_VERSION_MINIMUM=3.5`, `BUILD_TIMING_LOG`; `def verify_outputs() -> list[str]` — every required output from `framework_required_outputs` exists and every `.a`/xcframework slice is `arm64` only.
- Rust rule: every cargo invocation runs under `env -u MACOSX_DEPLOYMENT_TARGET` (host proc-macros break at ≥ 12.0; target objects default to macOS 11.0, which links fine into a 15.0 app). Remove the `DEPLOYMENT_TARGET` variables from the three Rust scripts.
- C/C++ scripts take the minimum version from `$MACOSX_DEPLOYMENT_TARGET` (set by the xcconfig) instead of hardcoded `10.11/10.13`.
- `tg setup` = `git submodule update --init --recursive` + `rustup toolchain install 1.96.1 --profile minimal` + `tg frameworks`.

- [ ] **Step 1:** Write `test_frameworks.py`: `test_verify_outputs_rejects_fat_lib` (temp dir with a fake required-output layout where `lipo` is stubbed to return `x86_64 arm64` → problem), `test_verify_outputs_missing` (missing `libssl.a` → problem naming it).
- [ ] **Step 2:** Run → FAIL. Implement `frameworks.py` → PASS.
- [ ] **Step 3:** Apply the script changes; run `tg frameworks` from a clean `core-xprojects/*/build` state with timing → all libraries build, `verify_outputs()` == `[]`. Record per-library times in `docs/local-development.md` next to the universal baseline (~22 min, 2.3 GB).
- [ ] **Step 4:** Remove `yasm`/`nasm` from `scripts/setup_build_env.sh` package list and the Rosetta step (arm64 only).
- [ ] **Step 5:** `tg build` (debug) → succeeds, buildcheck passes. Extend `test_fresh_clone.sh` to run `tg setup && tg build` when `NANOGRAM_FULL=1`.
- [ ] **Step 6:** Commit `build(native): arm64-only native libraries for Xcode 27; fix Rust host proc-macro failure`.

### Task 5: Our strict package `NanogramKit`

**Files:**
- Create: `packages/NanogramKit/Package.swift`, `packages/NanogramKit/Sources/NanogramKit/NanogramKit.swift`, `packages/NanogramKit/Tests/NanogramKitTests/StrictnessTests.swift`
- Modify: `Telegram.xcodeproj/project.pbxproj` (add `packages/NanogramKit` folder reference to the `Packages` group and link the product to the `Telegram` target — the only pbxproj edit pattern we use; same as upstream's "Adding a Feature")

**Interfaces:**
- `Package.swift`: `// swift-tools-version:6.2`, `platforms: [.macOS(.v15)]`, `swiftLanguageModes: [.v6]`, `swiftSettings: [.treatAllWarnings(as: .error)]` on every target via a shared `let nanogramSwiftSettings`. Depends only on what later tasks need (`TelegramUtils`, `TGUIKit`, `ApiCredentials`).
- Public entry: `public enum Nanogram { public static func installHooks() }` called once from `Telegram-Mac/app/main.swift` (one-line upstream edit).
- Every later task that adds Swift code adds it here.

- [ ] **Step 1:** Write `StrictnessTests.swift`: `test_installHooks_isIdempotent` (call twice, assert a counter-backed `Nanogram.installedHookCount == 1`).
- [ ] **Step 2:** `swift test --package-path packages/NanogramKit` → FAIL. Implement → PASS.
- [ ] **Step 3:** Prove strictness bites: add a temporary unused `var` → `swift build` fails with a warning-as-error; remove it.
- [ ] **Step 4:** `tg build` → green. Commit `feat: add strict NanogramKit package wired into the app`.

### Task 6: Identity and credentials

**Files:**
- Modify: `packages/ApiCredentials/Sources/ApiCredentials/Config.swift` (lines 4, 7, 12, 15, ~53, ~76: `apiId`/`apiHash` read from `NanogramSecrets`; `bundleId = "org.klaipher.Nanogram"`; `teamId = "YGTMYL879P"`; container prefix fixed to `"nanogram"` for both editions)
- Create (generated, gitignored): `packages/ApiCredentials/Sources/ApiCredentials/NanogramSecrets.swift`
- Create: `tools/dev/nanogram/credentials.py`, `tools/dev/tests/test_credentials.py`
- Modify: `nanogram/Nanogram.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER` for app and share via target-conditional settings or `tg` command-line `PRODUCT_BUNDLE_IDENTIFIER` per target if conditional settings can't select targets; `DEVELOPMENT_TEAM = YGTMYL879P`)

**Interfaces:**
- `credentials.py`: `def write_secrets(src: Path, dst: Path) -> None` writes `enum NanogramSecrets { static let apiId: Int32; static let apiHash: String }`, file mode 0600, only if content changed (keeps incremental builds). Raises `ConfigError("api-credentials.json missing: put {\"api_id\":…,\"api_hash\":…} in ~/.config/telegram-ios/")`.
- `tg build` calls `write_secrets` first. `tg` masks `api_hash` if it ever prints settings.

- [ ] **Step 1:** Write tests: `test_credentials_missing_fails` (no source file → `ConfigError` with that hint), `test_secrets_not_rewritten_when_unchanged` (mtime unchanged on second call), `test_generated_file_is_gitignored` (`git check-ignore` returns 0).
- [ ] **Step 2:** Run → FAIL; implement → PASS.
- [ ] **Step 3:** Apply `Config.swift` and xcconfig changes; `tg build`; `codesign -d --entitlements - <app>` and `defaults read <app>/Contents/Info CFBundleIdentifier` → `org.klaipher.Nanogram`; share extension `org.klaipher.Nanogram.MacShare`.
- [ ] **Step 4:** `grep -rn "ru.keepcoder\|6N38VWS5BX" --include=*.swift --include=*.plist --include=*.entitlements --include=*.xcconfig .` outside `submodules/` → no hits in files we ship.
- [ ] **Step 5:** Commit `feat: Nanogram identity — bundle IDs, team, app group, own API credentials (generated, not committed)`.

### Task 7: Editions, entitlements, single instance

**Files:**
- Create: `nanogram/editions/mas.xcconfig`, `nanogram/editions/direct.xcconfig`, `nanogram/entitlements/Nanogram-MAS.entitlements` (sandbox; app group; `network.client`/`server`; camera; audio-input; location; `files.user-selected.read-write`; `files.downloads.read-write`; maps; **no** `webcredentials:telegram.org`), `Nanogram-Direct.entitlements` (no sandbox; app group; camera; audio-input; location — hardened-runtime exceptions only if a test proves one is needed), `NanogramShare.entitlements` (sandbox; app group; `network.client`; `files.user-selected.read-only`)
- Modify: the `#if !APP_STORE` Sparkle sites to `#if !APP_STORE && !NANOGRAM_MAS`: `Telegram-Mac/updater/AppUpdateViewController.swift` (file guard), `Telegram-Mac/app/MainViewController.swift:9,166,216,255`, `Telegram-Mac/app/AppDelegate.swift:1174,1240,1349,1364,1386,1434,1652`, `Telegram-Mac/utils/InAppLinks.swift:2195`, `Telegram-Mac/packages-integration/hooks/SettingsHooksInstall.swift:355-383`
- Modify: `nanogram/editions/mas.xcconfig` excludes Sparkle from embedding (`EXCLUDED_SOURCE_FILE_NAMES`/link settings, or a Run Script that strips `Sparkle.framework` from the mas product — choose whichever the build check proves leaves no `Sparkle` symbol referenced)
- Create: `packages/NanogramKit/Sources/NanogramKit/SingleInstance.swift`, test in `NanogramKitTests`
- Create: `tools/dev/tests/test_editions.py`

**Interfaces:**
- `tg build --edition mas|direct` selects the xcconfig and conditions (`mas` adds `NANOGRAM_MAS`).
- `SingleInstance.ensure() -> Bool` — if another process with our bundle ID is running (any edition), activates it and returns false; `main.swift` exits when false (if upstream already does this, reuse and only test).

- [ ] **Step 1:** Write `test_editions.py`: `test_mas_has_sandbox_no_sparkle` (built mas app: entitlements contain `com.apple.security.app-sandbox = true`; no `Contents/Frameworks/Sparkle.framework`; `nm -u` main binary has no `SU`/`SPU` symbols), `test_direct_has_sparkle_no_sandbox`, `test_both_share_app_group` (both entitlements list `YGTMYL879P.org.klaipher.Nanogram`).
- [ ] **Step 2:** Run (after building both) → FAIL; implement → PASS.
- [ ] **Step 3:** `test_single_instance_across_editions` (Review Focus 3): launch direct build, then mas build; assert second process exits within 5 s and only one `Nanogram` process remains.
- [ ] **Step 4:** Manual check with the owner's account (owner types the code): log in on direct, quit, open mas → same account and chats without re-login. Record result in `docs/local-development.md`.
- [ ] **Step 5:** Commit `feat: mas and direct editions with shared data and single instance`.

### Task 8: Branding and Telegram-owned endpoints

**Files:**
- Modify: `Telegram-Mac/Assets.xcassets/AppIcon.appiconset/Logo_*.png` (rendered), `TelegramShare/Info.plist` (`CFBundleDisplayName`), both `Info.plist` copyright
- Modify: `Telegram.xcodeproj/project.pbxproj` only via xcconfig `PRODUCT_NAME = Nanogram` (verify `Nanogram.app/Contents/MacOS/Nanogram`); update `buildbox/verify-build.sh` bundle name or stop using it (our checks are `buildcheck`)
- Create: `tools/dev/nanogram/render-mac-icon.swift` (port of iOS `AlternateIconSources/render.swift`, input `NanogramComet.svg` dark variant)
- Create: `packages/NanogramKit/Sources/NanogramKit/Branding.swift` — at launch replaces "Telegram" with "Nanogram" in the app menu item titles (avoids editing 6 MainMenu.xib files) and sets `TelegramUtils.appName` if it is a `var`; if it is `let` (System.swift:17), change that one line
- Modify (one line each, under `#if NANOGRAM`): crash-report bot (`CrashReportStore.swift:4`) → disabled; internal MTProto updater (`MacInternal` callers in `AppDelegate.swift:1188` and `AppUpdateViewController.swift:265-269`) → off; `AppConstants.swift:10` `itunesAppLink` → `https://apps.apple.com/app/id6829268176`; `CrashRecovery.swift:59` → our repo releases URL
- Test: `NanogramKitTests/BrandingTests.swift`, `tools/dev/tests/test_endpoints.py`

**Interfaces:** `Branding.apply(to menu: NSMenu)`; endpoints test greps the built binary's strings.

- [ ] **Step 1:** Write tests: `test_menu_titles_rebranded` (build an `NSMenu` with "Quit Telegram" → "Quit Nanogram"; "Telegram Premium" stays unchanged — only app-name items change), `test_no_telegram_update_endpoints_in_binary` (`strings` of both editions contain none of `mac-updates.telegram.org`, `osx.telegram.org/updates`, `macos_stable_updater_bot`, `api.appcenter.ms`).
- [ ] **Step 2:** Run → FAIL; implement; render icons; run → PASS.
- [ ] **Step 3:** Launch the app: Dock and About show "Nanogram" and the Comet icon (screenshot to scratchpad, check by eye).
- [ ] **Step 4:** Commit `feat: Nanogram branding; remove Telegram update, crash-bot and store endpoints`.

### Task 9: Sparkle on our own feed (direct edition)

**Files:**
- Modify: `nanogram/editions/direct.xcconfig` (`SFEED_URL = https:/$()/github.com/klaipher/nanogram-releases/releases/latest/download/appcast.xml`, `SUPublicEDKey` value, `DSA_PEM_FILE =` empty)
- Modify: `Telegram-Mac/Info.plist` — add `SUPublicEDKey = $(SPARKLE_ED_PUBLIC_KEY)`; keep `SUPublicDSAKeyFile` empty for us
- Create: `tools/dev/nanogram/sparkle.py` (`def ensure_keys() -> str` runs Sparkle 1.21's `generate_keys` once, private key to `~/.config/nanogram-macos/sparkle_ed25519` (0600), returns public key; `def sign(archive: Path) -> str` returns `sparkle:edSignature`), `tools/dev/tests/test_sparkle.py`
- **Deviation from spec, decided here:** stay on the upstream Sparkle 1.21 submodule (it supports EdDSA) instead of Sparkle 2. Sparkle 2 would rewrite upstream's `AppUpdateViewController.swift` (private Sparkle 1 APIs) and conflict on every sync. Reported to the owner with this plan.

- [ ] **Step 1:** Tests: `test_sign_roundtrip` (sign a temp file, verify with Sparkle's `sign_update --verify` or the Python `ed25519` check over the public key), `test_private_key_never_in_repo` (`git grep` for the key's base64 prefix → none).
- [ ] **Step 2:** Run → FAIL; implement → PASS.
- [ ] **Step 3:** Commit `feat(direct): Sparkle EdDSA feed on klaipher/nanogram-releases (nothing published)`.

### Task 10: Warning baseline for upstream code

**Files:**
- Create: `tools/dev/nanogram/warnings.py`, `tools/dev/tests/test_warnings.py`, `fixtures/warnings.log`, `nanogram/warnings-baseline.json`
- Modify: `nanogram/Nanogram.xcconfig` — upstream gets the same checks as warnings: `OTHER_SWIFT_FLAGS = $(inherited) -strict-concurrency=complete` (Task 3's gate tells whether it reaches packages; if not, pass on the command line)

**Interfaces:**
- `def count(log: str) -> dict[str, int]` — unique `path:line:col: warning:` lines (xcodebuild repeats lines; dedupe), keyed by package name (`packages/<P>/`, `submodules/telegram-ios/submodules/<P>/`, `submodules/<P>/`, else `app`); our packages (`NanogramKit`, any `packages/Nanogram*`) are excluded — they cannot have warnings.
- `def compare(baseline: dict, current: dict) -> list[str]` — packages whose count went up.
- `tg warnings [--update]`: clean debug build log → count → compare or write baseline.

- [ ] **Step 1:** Tests: `test_duplicates_counted_once`, `test_package_attribution` (one line per path shape), `test_increase_reported`, `test_decrease_ok`.
- [ ] **Step 2:** Run → FAIL; implement → PASS.
- [ ] **Step 3:** Produce the first baseline from a clean debug build with complete concurrency on; commit `feat: tracked warning baseline for upstream code (strictness A)`.

### Task 11: tglint for macOS and `tg check`

**Files:**
- Create: `tools/dev/lint/tglint.py`, `swiftlint.yml`, `pre-push`, `tools/dev/tests/test_tglint.py` + fixtures — ported from iOS `5ac4d079`, header comment naming the source commit
- Modify: `tglint.py` constants: tools dir `~/.cache/nanogram-macos/tools`, `EXCLUDED_PREFIXES = ("submodules/", "third-party/", "core-xprojects/", "build-output/")`; `affected_tests` replaced by `def affected_packages(paths) -> list[str]` (packages with a `Tests/` folder whose sources changed)
- Modify: `tools/dev/tg` (`cmd_lint`, `cmd_check`, `cmd_test`)

**Interfaces:**
- `tg test [package]` = `swift test --package-path packages/<P>` for affected/named packages (NanogramKit always).
- `tg check` = `tools/dev/tests/run.sh` + `tg lint` + `tg build` (debug, with buildcheck) + `tg warnings` + `tg test`. The pre-push hook runs `tg check`. Exit 1 on any failure.

- [ ] **Step 1:** Port tests first (`test_tglint.py` incl. diff parsing, filters, install-hook, checksum, plus `test_affected_packages`); run → FAIL; port → PASS.
- [ ] **Step 2:** `tg lint` on a branch with a deliberate `try!` in NanogramKit → blocking finding; remove.
- [ ] **Step 3:** `tg check` → green end to end; record its duration.
- [ ] **Step 4:** Commit `feat: tglint, tg check and pre-push gate for macOS`.

### Task 12: Dependency updates

Each library is its own commit, gated by `tg frameworks && tg check` and a 2-minute manual smoke (log in, open a chat with media, play a video, send a sticker, start and end a call to Saved Messages or the owner's second device if available). Libraries whose sources live in our repo:

| Library | From → To | Where |
|---|---|---|
| OpenSSL | 1.1.1 branch tip (EOL) → latest `openssl-3.5.x` LTS tag, pinned by commit | `core-xprojects/openssl/OpenSSLEncryption/build.sh` (clone `-b <tag>`; verify `OPENSSL_VERSION_TEXT`) |
| OpenH264 | 2.4.1 → 2.7.0 | `core-xprojects/OpenH264/build.sh:19` |
| opus | 1.3.1 → 1.6.1 | `core-xprojects/libopus/` tarball + sha256 |
| libvpx | 1.11.0 → 1.17.0 | `core-xprojects/libvpx/source` |
| libwebp | 1.3.2 → 1.6.0 | `core-xprojects/libwebp/` archive |
| Boost.Regex | 2022 → boost-1.92.0 | `submodules/regex` |

Libraries inside `submodules/telegram-ios` (**spec refinement, decided here:** a `nanogram-mac` branch in `klaipher/Telegram-iOS` = the commit upstream Mac pins + library-bump commits only, cherry-picked from the iOS fork where they already shipped; on each Mac sync the branch is rebased onto the new pin; still independent of the iOS fork's `main`):

| Library | From → To | Cherry-pick from iOS fork |
|---|---|---|
| FFmpeg | 8.1.2 → 9.0.2 | `5cd48648`, `b212bb52`, `39eb2962` |
| dav1d | 1.5.0-23 → 1.5.4 | `bd6dbf95` |
| mozjpeg 4.1.4 | stays (iOS switched to libjpeg-turbo via Bazel; Mac switch is a separate change, not stage 1) | — |
| TDLib/tde2e 1.8.49 | stays (tied to TelegramCore's API at the upstream pin) | — |

- [ ] **Step 1:** Write `tools/dev/tests/test_versions.py`: `test_pinned_versions` reads each library's version from its source (version header/CHANGELOG/meson) and asserts the table's "To" values. Run → FAIL.
- [ ] **Step 2..n:** One library per step: bump, `tg frameworks`, `tg check`, smoke, commit `build(deps): <lib> <from> → <to>`.
- [ ] **Final step:** `test_versions.py` → PASS. Point `.gitmodules` `submodules/telegram-ios` at `https://github.com/klaipher/Telegram-iOS` branch `nanogram-mac`; `test_fresh_clone.sh` → PASS.

### Task 13: `tg sync-upstream`

**Files:**
- Create: `tools/dev/nanogram/sync.py`, `tools/dev/tests/test_sync.py`
- Modify: `tools/dev/tg` (`cmd_sync_upstream`), `docs/local-development.md` ("Keeping up with upstream")

**Interfaces:**
- `def snapshot(remote="telegram", branch="master") -> str | None` — fetch, `commit-tree` of the upstream tree on top of `upstream` with `Upstream-Commit:` trailer, CAS `update-ref`; returns new sha or `None` when unchanged (iOS logic, upstream has no tags so it tracks `master`).
- `@dataclass MergeResult(clean: bool, conflicts: list[str])`; `def merge_into_main() -> MergeResult` — `git merge upstream` on a clean `main`; on conflict, stop and return the conflicted paths (no auto-resolution).
- Post-merge (only when clean): if upstream's `submodules/telegram-ios` pin changed, print the rebase command for `nanogram-mac`; `git submodule update --init --recursive`; `tg frameworks`; `tg build`; `tg warnings --update` (new upstream warnings join the baseline, never block); `tg check`.

- [ ] **Step 1:** Tests on temp repos: `test_snapshot_noop_when_tree_equal`, `test_snapshot_records_upstream_commit`, `test_sync_reports_conflicts` (Review Focus 2: both sides edit `Config.swift` → result lists it, `main` left in the merge state with a message, nothing committed).
- [ ] **Step 2:** Run → FAIL; implement → PASS.
- [ ] **Step 3:** Real run against `telegram/master` (whatever landed since the fork) → clean or reported; commit `feat: tg sync-upstream for macOS`.

### Task 14: TestFlight (mas edition)

**Files:**
- Create: `tools/dev/nanogram/release.py` (port of iOS `device_signing.py` export/upload parts), `tools/dev/tests/test_release.py`
- Modify: `tools/dev/tg` (`cmd_testflight`)

**Interfaces:**
- `def archive(edition: str, build_number: str) -> Path` — `xcodebuild archive -scheme Release -configuration Release -xcconfig nanogram/editions/<edition>.xcconfig CURRENT_PROJECT_VERSION=<n> <conditions> -allowProvisioningUpdates` + ASC key flags.
- `def export_options(method: str, upload: bool) -> dict` — `app-store-connect` (mas) or `developer-id` (direct), `signingStyle=automatic`, `uploadSymbols=True`, `manageAppVersionAndBuildNumber=False`.
- `def upload_mas(pkg: Path) -> None` — `xcrun altool --upload-app -t macos -f <pkg> --apiKey … --apiIssuer …` with `API_PRIVATE_KEYS_DIR` (same reason as iOS: xcodebuild's own upload rejects the key).
- Build number: `TG_BUILD_NUMBER` or `date +%Y%m%d%H%M`. Version = upstream `MARKETING_VERSION`.
- One-time: the App Store Connect app 6829268176 needs the macOS platform. Try the API (`appStoreVersions` with `platform=MAC_OS`); if the API refuses, `tg testflight` stops with one line telling the owner where to click in App Store Connect.

- [ ] **Step 1:** Tests: `test_export_options_mas`, `test_export_options_direct`, `test_missing_asc_key_fails_early`, `test_build_number_override`.
- [ ] **Step 2:** Run → FAIL; implement → PASS.
- [ ] **Step 3:** `tg testflight --export-only` → signed `.pkg`, `pkgutil --check-signature` shows Apple distribution; buildcheck on the archived app passes (arm64, 15.0, `-O3`/LTO in log).
- [ ] **Step 4:** **Owner's OK**, then `tg testflight` → build appears in TestFlight (internal group); install on this Mac from TestFlight; app launches, logs in.
- [ ] **Step 5:** Commit `feat: tg testflight for the mas edition`.

### Task 15: Direct edition release (local only)

**Files:**
- Modify: `tools/dev/nanogram/release.py` (`def notarize(app: Path) -> None` via `xcrun notarytool submit --key … --key-id … --issuer … --wait` + `xcrun stapler staple`; `def make_dmg(app: Path, out: Path) -> Path` via `hdiutil create -fs APFS -format ULFO`; `def appcast_entry(version, build, dmg, ed_signature, url) -> str`), `tools/dev/tests/test_release.py`
- Modify: `tools/dev/tg` (`cmd_release_direct` → output in `build-output/direct/<build>/`: `.dmg`, `appcast.xml`, `Nanogram-<version>-<build>-source.tar.gz` from `git archive` + submodules)

- [ ] **Step 1:** Tests: `test_appcast_entry_fields` (enclosure url, `sparkle:version`, `sparkle:shortVersionString`, `sparkle:edSignature`, `length`), `test_source_archive_includes_submodules` (tar listing contains `submodules/telegram-ios/submodules/TelegramCore/Package.swift`).
- [ ] **Step 2:** Run → FAIL; implement → PASS.
- [ ] **Step 3:** `tg release-direct` → `spctl -a -vv -t install <dmg>` says "Notarized Developer ID"; `codesign --verify --deep --strict` passes; app runs from the mounted dmg. Nothing uploaded.
- [ ] **Step 4:** Commit `feat: tg release-direct — notarized dmg, Sparkle appcast, source archive (local)`.

### Task 16: Docs and stage-1 report

**Files:**
- Create/modify: `docs/local-development.md` (prerequisites, `tg` commands, editions, secrets layout, sync, release, measured numbers), `NANOGRAM.md`
- Modify: `~/.claude/projects/-Users-klaipher-Projects/memory/nanogram-macos-fork.md` (repo path, commands)

- [ ] **Step 1:** Re-measure the baseline table from the spec on the fork (clone, frameworks, clean debug, no-change, ChatUI body edit, TGUIKit API edit, release, app size, disk) and add a "stage 1" column. Stage 2 will start from these numbers.
- [ ] **Step 2:** Offer the owner upstream PRs for the generic fixes (private submodules in `.gitmodules`, mtproto-engine in `xcode27.sh`, Rust host proc-macro + deployment target) — do not open them without an explicit yes.
- [ ] **Step 3:** Delete `~/Projects/nanogram-macos-recon` only after the owner agrees (24 GB).
- [ ] **Step 4:** Commit `docs: macOS fork development guide and stage 1 numbers`.
