"""The iOS and Mac FFmpeg builds share one configure flag list (ffmpeg-common-flags.sh).

Pure Python, no build. The same file lives in both repos: in the iOS repo it checks build-ffmpeg-bazel.sh, in the Mac
repo core-xprojects/ffmpeg/ffmpeg/build.sh (the common file comes from the telegram-ios submodule there).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
IOS_DIR = ROOT / "submodules/ffmpeg/Sources/FFMpeg"
MAC_DIR = ROOT / "submodules/telegram-ios/submodules/ffmpeg/Sources/FFMpeg"
IS_IOS = (ROOT / "MODULE.bazel").is_file()
FFMPEG_DIR = IOS_DIR if IS_IOS else MAC_DIR
COMMON = FFMPEG_DIR / "ffmpeg-common-flags.sh"
SCRIPT = IOS_DIR / "build-ffmpeg-bazel.sh" if IS_IOS else ROOT / "core-xprojects/ffmpeg/ffmpeg/build.sh"

TOKEN = re.compile(r"--[a-z0-9_\-]+(?:=[^\s\"'\\]*)?")

# What each platform may add on top of the shared list. Anything else belongs in the shared file.
ALLOWED_EXTRAS = {
    "ios": {
        "--enable-muxer=mp4,matroska,ogg,mpegts",
        # The darwin configure call: AudioToolbox decoders and encoders, VideoToolbox hwaccels.
        "--enable-audiotoolbox",
        "--enable-decoder=alac_at,gsm_ms_at,aac_at",
        "--enable-encoder=libvpx_vp9,aac_at",
        "--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,av1_videotoolbox",
    },
    "mac": {
        "--enable-audiotoolbox",
        "--enable-decoder=aac,alac_at,gsm_ms_at",
        "--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,av1_videotoolbox",
    },
}


def region(text, start):
    begin = text.index(start)
    end = re.search(r'^\s*"\s*$', text[begin:], re.M)
    return text[begin:begin + end.end()]


def tokens(text):
    return set(TOKEN.findall(text))


@unittest.skipUnless(COMMON.is_file(), "the common flag file is not checked out (submodule missing)")
class FfmpegFlagParityTests(unittest.TestCase):
    def setUp(self):
        self.common_text = COMMON.read_text()
        self.common = tokens(region(self.common_text, 'FFMPEG_COMMON_FLAGS="'))
        self.script_text = SCRIPT.read_text()
        self.side = "ios" if IS_IOS else "mac"

    def test_the_build_script_sources_the_common_file(self):
        self.assertIn("ffmpeg-common-flags.sh", self.script_text)
        self.assertIn("$FFMPEG_COMMON_FLAGS", region(self.script_text, 'CONFIGURE_FLAGS="'))

    def test_the_script_adds_only_the_listed_platform_extras(self):
        own = tokens(region(self.script_text, 'CONFIGURE_FLAGS="'))
        self.assertEqual(own - self.common - ALLOWED_EXTRAS[self.side], set())

    def test_the_common_set_has_what_both_apps_play(self):
        flags = " ".join(sorted(self.common))
        for decoder in ("h264", "hevc", "libvpx_vp9", "libopus", "mp3", "flac", "vorbis", "libdav1d", "av1"):
            self.assertRegex(flags, r"--enable-decoder=\S*\b%s\b" % decoder, decoder)
        for demuxer in ("aac", "mov", "mp3", "ogg", "flac", "wav", "aiff", "matroska", "mpegts"):
            self.assertRegex(flags, r"--enable-demuxer=\S*\b%s\b" % demuxer, demuxer)

    def test_the_common_set_switches_off_the_autodetected_glue(self):
        for flag in ("network", "securetransport", "bzlib", "iconv", "appkit", "avfoundation", "coreimage", "metal", "sdl2"):
            self.assertIn("--disable-" + flag, self.common)

    def test_no_component_list_names_a_component_that_does_not_exist(self):
        # `libopus` is a decoder only; there is no libopus demuxer or parser, and a trailing comma is a typo.
        for token in self.common:
            if token.startswith(("--enable-demuxer=", "--enable-parser=")):
                self.assertNotIn("libopus", token.split("=", 1)[1].split(","), token)
            if "=" in token:
                self.assertFalse(token.endswith(","), token)
                self.assertNotIn(",,", token)


if __name__ == "__main__":
    unittest.main()
