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


class WidgetQuickJSPinTests(unittest.TestCase):
    def repo(self):
        import subprocess
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@l", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@l",
               "PATH": "/usr/bin:/bin:/opt/homebrew/bin"}
        def git(*args):
            return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True, env=env).stdout.strip()
        git("init", "-q")
        (root / "a").write_text("1")
        git("add", "a")
        git("commit", "-qm", "old")
        old = git("rev-parse", "HEAD")
        (root / "a").write_text("2")
        git("commit", "-qam", "fixed")
        fixed = git("rev-parse", "HEAD")
        git("checkout", "-q", old)
        return root, old, fixed, git

    def test_moves_the_nested_quickjs_to_the_fixed_commit(self):
        root, old, fixed, git = self.repo()
        self.assertTrue(localfixes.pin_checkout(root, fixed))
        self.assertEqual(git("rev-parse", "HEAD"), fixed)

    def test_does_nothing_when_already_at_the_fixed_commit(self):
        root, old, fixed, git = self.repo()
        git("checkout", "-q", fixed)
        self.assertFalse(localfixes.pin_checkout(root, fixed))
        self.assertEqual(git("rev-parse", "HEAD"), fixed)

    def test_skips_a_checkout_that_is_not_there(self):
        self.assertFalse(localfixes.pin_checkout(Path("/nonexistent/quickjs"), "b526a817f188ef861eea7666d68361c7851673a0"))

    def test_the_pin_is_the_quickjs_security_release(self):
        self.assertEqual(localfixes.WIDGET_QUICKJS_COMMIT, "b526a817f188ef861eea7666d68361c7851673a0")
        self.assertEqual(localfixes.WIDGET_QUICKJS_PATH, "third-party/widget-sandbox/packages/ios/Sources/CQuickJS/quickjs")
