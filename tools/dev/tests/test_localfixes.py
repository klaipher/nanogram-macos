import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import localfixes  # noqa: E402

UPSTREAM_METALENGINE = '''        .target(
            name: "MetalEngine",
            dependencies: [],
            path: "Sources/",
            resources: [.copy("MetalEngineShaders.metal")]),
    ]
)
'''
FIXED_METALENGINE = '''        .target(
            name: "MetalEngine",
            dependencies: [],
            path: "Sources/"),
    ]
)
'''
MULTI = 'path: "Sources/",\n            resources: [.copy("a.metal"),\n                        .copy("b.metal")])\n'


class ShaderFixTests(unittest.TestCase):
    def manifest(self, text):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "Package.swift"
        path.write_text(text)
        return path

    def test_copied_metal_resources_removed(self):
        path = self.manifest(UPSTREAM_METALENGINE)
        self.assertTrue(localfixes.compile_shaders(path))
        self.assertEqual(path.read_text(), FIXED_METALENGINE)

    def test_several_copies_removed(self):
        path = self.manifest(MULTI)
        self.assertTrue(localfixes.compile_shaders(path))
        self.assertEqual(path.read_text(), 'path: "Sources/")\n')

    def test_idempotent(self):
        path = self.manifest(FIXED_METALENGINE)
        self.assertFalse(localfixes.compile_shaders(path))
        self.assertEqual(path.read_text(), FIXED_METALENGINE)

    def test_other_resources_kept(self):
        text = 'path: "Sources/",\n            resources: [.copy("Assets/font.ttf")])\n'
        path = self.manifest(text)
        self.assertFalse(localfixes.compile_shaders(path))
        self.assertEqual(path.read_text(), text)

    def test_every_shader_manifest_is_fixed_in_this_checkout(self):
        for manifest in localfixes.SHADER_MANIFESTS:
            self.assertNotIn('.metal")', (localfixes.config.ROOT / manifest).read_text(), manifest)


if __name__ == "__main__":
    unittest.main()
