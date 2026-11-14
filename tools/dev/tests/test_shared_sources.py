"""The Mac packages compile the iOS core's sources through symlinks (shared-libraries plan W7); no copy is kept.

Each symlink must be tracked as a symlink, resolve inside submodules/telegram-ios, and point at a real file or directory
(the core has to be checked out for the resolution checks; they skip without it).
"""
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
CORE = ROOT / "submodules" / "telegram-ios"
LINKED = {
    "packages/RingBuffer/CoreSources": "submodules/RingBuffer",
    "packages/EDSunriseSet/CoreSources": "submodules/Sunrise",
    "packages/HLSPlayback/Sources": "submodules/HLSPlayback/Sources",
    "packages/HLSPlayback/Tests": "submodules/HLSPlayback/Tests",
    "packages/SwiftMath/Sources/SwiftMath/MathBundle": "third-party/SwiftMath/Sources/MathBundle",
    "packages/SwiftMath/Sources/SwiftMath/MathRender": "third-party/SwiftMath/Sources/MathRender",
    "packages/VP9Hardware/Sources/VP9Hardware/VP9HardwareDecoder.swift": "submodules/AnimatedStickerNode/VP9Hardware/Sources/VP9HardwareDecoder.swift",
    "packages/VP9Hardware/Sources/VP9Hardware/WebMStickerDemuxer.swift": "submodules/AnimatedStickerNode/VP9Hardware/Sources/WebMStickerDemuxer.swift",
    "packages/VP9Hardware/Tests/VP9HardwareTests/VP9HardwareTests.swift": "submodules/AnimatedStickerNode/VP9Hardware/Tests/VP9HardwareTests.swift",
    "packages/VP9Hardware/Tests/VP9HardwareTests/VP9HardwareStatsTests.swift": "submodules/AnimatedStickerNode/VP9Hardware/Tests/VP9HardwareStatsTests.swift",
    "packages/QrStudioUI/Sources/QrStudioUI/QrStudioCodeMatrix.swift": "submodules/QrCode/Sources/QrCodeMatrix.swift",
    "packages/SceneEffects/Sources/InteractiveDiamond/DiamondAnimation.swift": "submodules/TelegramUI/Components/Premium/PremiumDiamondComponent/Sources/InteractiveDiamond/DiamondAnimation.swift",
    "packages/SceneEffects/Sources/InteractiveDiamond/DiamondGeometry.swift": "submodules/TelegramUI/Components/Premium/PremiumDiamondComponent/Sources/InteractiveDiamond/DiamondGeometry.swift",
    "packages/SceneEffects/Sources/InteractiveDiamond/GramDiamond.metal": "submodules/TelegramUI/Components/Premium/PremiumDiamondComponent/MetalResources/GramDiamond.metal",
    "packages/SceneEffects/Sources/LiquidGlassShapes/LiquidGlassShapes.metal": "submodules/TelegramUI/Components/LiquidGlassShapes/Metal/LiquidGlassShapes.metal",
    "packages/SceneEffects/Sources/LiquidGlassShapes/LiquidGlassSurfaceReleasePolicy.swift": "submodules/TelegramUI/Components/LiquidGlassShapes/Sources/LiquidGlassSurfaceReleasePolicy.swift",
}
for _name in ("QrStudioCodePaths", "QrStudioCodePillLogic", "QrStudioColor", "QrStudioExportLayout", "QrStudioExportMotion",
              "QrStudioExportRenderer", "QrStudioLens", "QrStudioLookSettings", "QrStudioMotion", "QrStudioServerLook",
              "QrStudioSheetMotion"):
    LINKED[f"packages/QrStudioUI/Sources/QrStudioUI/{_name}.swift"] = f"submodules/TelegramUI/Components/QrStudioLogic/Sources/{_name}.swift"
for _name in ("STPCardValidator.m", "STPBINRange.m", "NSString+Stripe_CardBrands.m", "NSString+Stripe_CardBrands.h"):
    LINKED[f"submodules/Stripe/Sources/{_name}"] = f"submodules/Stripe/Sources/{_name}"
for _name in ("STPCardValidator.h", "STPBINRange.h", "STPCardBrand.h"):
    LINKED[f"submodules/Stripe/PublicHeaders/Stripe/{_name}"] = f"submodules/Stripe/PublicHeaders/Stripe/{_name}"


def tracked_mode(path: str) -> str:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s", "--", path], capture_output=True, text=True, check=True).stdout.split()
    return out[0] if out else ""


class SharedSourcesTests(unittest.TestCase):
    def test_every_shared_path_is_a_tracked_symlink(self):
        for path in LINKED:
            self.assertEqual(tracked_mode(path), "120000", path)

    def test_every_link_points_into_the_core(self):
        if not (CORE / "submodules").is_dir():
            self.skipTest("core not checked out")
        for path, target in LINKED.items():
            link = ROOT / path
            self.assertTrue(link.is_symlink(), path)
            self.assertEqual(link.resolve(), (CORE / target).resolve(), path)
            self.assertTrue(link.exists(), path)

    def test_no_copy_of_a_shared_source_remains(self):
        for old in ("packages/HLSPlayback/Sources/HLSPlayback", "packages/HLSPlayback/Tests/HLSPlaybackTests",
                    "packages/RingBuffer/Sources", "packages/EDSunriseSet/Sources"):
            self.assertFalse((ROOT / old).exists(), old)

    def test_the_mac_only_files_stay_regular_files(self):
        for path in ("packages/VP9Hardware/Sources/VP9Hardware/VP9HardwareStickerReader.swift",
                     "packages/SceneEffects/Sources/LiquidGlassShapes/LiquidGlassShapesTypes.swift",
                     "packages/QrStudioUI/Sources/QrStudioUI/QrStudioLook.swift"):
            self.assertEqual(tracked_mode(path), "100644", path)


if __name__ == "__main__":
    unittest.main()
