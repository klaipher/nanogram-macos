"""Asset catalogs in Swift packages are compiled into Assets.car, never copied raw.

A `.copy(...)` of an `.xcassets` ships the source folder, so `NSImage(resource:)` finds nothing and traps at runtime.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

PACKAGES = config.ROOT / "packages"
COPY = re.compile(r'\.copy\(\s*"([^"]+)"\s*\)')


def copied_resources(manifest: Path) -> list[str]:
    return COPY.findall(manifest.read_text())


def copies_asset_catalog(package: Path, resource: str) -> bool:
    if resource.rstrip("/").endswith(".xcassets"):
        return True
    for match in package.glob(f"**/{resource}"):
        if ".build" in match.parts:
            continue
        if match.is_dir() and any(match.rglob("*.xcassets")):
            return True
    return False


class PackageResourceTests(unittest.TestCase):
    def test_no_package_copies_an_asset_catalog(self):
        offenders = []
        for manifest in sorted(PACKAGES.glob("*/Package.swift")):
            for resource in copied_resources(manifest):
                if copies_asset_catalog(manifest.parent, resource):
                    offenders.append(f"{manifest.parent.name}: .copy(\"{resource}\")")
        self.assertEqual(offenders, [], "declare asset catalogs with .process(...) so SwiftPM compiles Assets.car")

    def test_detects_a_copied_catalog_inside_a_copied_folder(self):
        self.assertFalse(copies_asset_catalog(PACKAGES / "DataUsageUI", "does-not-exist"))
        self.assertTrue(copies_asset_catalog(PACKAGES / "DataUsageUI", "Resources"))



SHADER_MANIFESTS = (
    "packages/CallVideoLayer/Package.swift",
    "packages/DustLayer/Package.swift",
    "submodules/telegram-ios/submodules/MetalEngine/Package.swift",
)


class ShaderManifestTests(unittest.TestCase):
    """Xcode 27 copies `.copy("*.metal")` resources as source instead of compiling them, and MetalEngine then traps at
    launch (upstream XCODE27.md item 3). The fix is committed in every manifest; this guards against it coming back."""

    def test_every_shader_manifest_compiles_its_metal_files(self):
        for relative in SHADER_MANIFESTS:
            manifest = config.ROOT / relative
            if not manifest.is_file():
                continue  # the core checkout is optional here
            self.assertNotIn('.metal")', manifest.read_text(), relative)

if __name__ == "__main__":
    unittest.main()
