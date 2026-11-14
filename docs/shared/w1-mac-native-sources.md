# Mac W1.2: native sources shared with the iOS core

Plan: the shared-codebase execution plan, wave 1 item W1.2 (kept outside this repo). No builds were run; these are the identity checks done before the copies were deleted.

## libwebp 1.6.0

Deleted: `core-xprojects/libwebp/libwebp-1.6.0.tar.gz` (sha256 e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564, the value `build-cmake.sh` pinned).
New source: `submodules/telegram-ios/third-party/webp/libwebp` (iOS vendored tree bf9fde2b at 466d8350; the iOS integrator turns it into a v1.6.0 submodule at the same path, so this script needs no change then).

Proof (`diff -r` of the unpacked tarball against the iOS tree at 466d8350): zero differing files. The tarball has 30 extra autotools files only (`configure`, `aclocal.m4`, `ltmain.sh`, `Makefile.in` files, `config.h.in`, `libtool` m4 files and similar); the iOS tree has one extra file, `doc/TODO`. `CMakeLists.txt`, `cmake/`, `src/` and `sharpyuv/` sources are identical. The Mac build is CMake only, so no autotools file is used. Nothing is lost.

## libjpeg-turbo 3.2.1

Deleted: `core-xprojects/Mozjpeg/libjpeg-turbo-3.2.1.tar.gz`. Its sha256 is c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f, equal to the pin in `Mozjpeg/build.sh` and in iOS `MODULE.bazel` (`libjpeg_turbo_tar_gz`). The script now downloads `https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz` into a temporary directory and checks that sha256 before use.

## flatc 25.12.19

Deleted: `scripts/flatc` (sha256 4448902b456693cb1b5fc6158071b6499525518160314abf128e531bd8b44d3d). Its embedded build path names `flatbuffers-25.12.19`, the iOS pin (`MODULE.bazel` `flatbuffers_zip`, sha256 f5d4636bfc4d30c622c9ad238ce947848c2b90b10aecd387dc62cdee2584359b). `prepare-flat-serialization.py` downloads that archive, checks the sha256, builds `flatc` with the same CMake flags as iOS `third-party/flatc/BUILD`, and caches it in `.build/flatc/25.12.19/`. A `scripts/flatc` file, if someone puts one there, still takes precedence.

## OpenSSL

`patch-conf.diff` patched `Configurations/10-main.conf` for darwin64 no-asm targets of OpenSSL 1.1; the `patch` call was already commented out and OpenSSL 3.5.9 has native darwin64-arm64-cc and darwin64-x86_64-cc targets, so the hunk is intentionally dropped. The `../../submodules/telegram-ios/submodules/openssl` argument pointed to a directory that does not exist in the core and was never read.

## Pending until the iOS integrator lane lands: the core bump checklist

The core bump is not only `git add submodules/telegram-ios`. The iOS shared/w1 head moves `boost_regex`, ogg and td headers, so one bump commit must carry all of these (no commit before then keeps the tree consistent with the 466d8350 pin):

- Pin: `git -C submodules/telegram-ios fetch`, check out the iOS shared/w1 head, then `git submodule update --init --recursive --depth 1` inside the core (new nested submodules: ffmpeg-9.0.2, libwebp, ogg, opusfile, regex, wamr).
- `submodules/CodeSyntax/CodeSyntax/CodeSyntax.xcodeproj/project.pbxproj` lines 349 and 387: `HEADER_SEARCH_PATHS` to `$PROJECT_DIR/../../telegram-ios/third-party/boost_regex/regex/include/`, together with `tools/dev/tests/test_libprisma_shared.py` (CORE_REGEX and the assert at line 37) and `tools/dev/tests/test_versions.py:168`.
- `tools/tests/audio-trim-store/run.py`: ogg includes `third-party/ogg/ogg/include` and `third-party/ogg/overlay` (they do not exist at 466d8350, so the change belongs in the bump commit).
- Once iOS item W1.1-7 lands (td SharedHeaders deleted, TdBinding uses `../td/tde2e`): drop the `sync-headers.sh .../td/td .../td/TdBinding/SharedHeaders/td` step in `scripts/configure_frameworks.sh` (line 99-101) and the TD_PAIR in `tools/dev/nanogram/fwcache.py:43`, otherwise they write into a directory the core no longer tracks and dirty it.
- `docs/mac-core-paths.txt` share lines; `native-libs.json` must be copied byte for byte to the iOS repo.
