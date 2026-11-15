"""The shared tools (klaipher/nanogram-deps, reached through the core) that tg and the pre-push hook call.

The tools and their own tests are one copy in nanogram-deps; here only the Mac side is checked: the files tg calls
exist, the Mac keeps no copy of them, and the Mac's upstream-sync settings load with the shared script. Skipped when the
core is not checked out (a fresh worktree).
"""
import importlib.util
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SHARED = ROOT / "submodules" / "telegram-ios" / "shared"
TOOLS = SHARED / "tools"
needs_shared = unittest.skipUnless(TOOLS.is_dir(), "the core's shared/ submodule is not checked out")

RETIRED_COPIES = (
    "tools/dev/perfgate.py", "tools/dev/worktree/worktree.py", "tools/dev/cachegc/cachegc.py",
    "tools/dev/native/check_native_libs.py", "tools/dev/native/module_settings.py", "tools/dev/native/native-libs.json",
    "tools/dev/native/module-settings.json", "tools/dev/perf/baselines.json", "tools/dev/upstream-sync/sync.py",
)


def load(path: Path, name: str):
    sys.path.insert(0, str(path.parent))
    sys.path.insert(0, str(TOOLS))  # repo_root.py
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SharedToolTests(unittest.TestCase):
    def test_the_mac_keeps_no_copy_of_a_shared_tool(self):
        for relative in RETIRED_COPIES:
            self.assertFalse((ROOT / relative).exists(), relative)

    @needs_shared
    def test_every_shared_tool_tg_calls_exists(self):
        text = (ROOT / "tools/dev/tg").read_text()
        called = set(re.findall(r"shared_tool ([\w/.-]+\.py)", text))
        self.assertTrue(called)
        for relative in called:
            self.assertTrue((TOOLS / relative).is_file(), relative)

    @needs_shared
    def test_the_upstream_sync_settings_load_with_the_shared_script(self):
        sync = load(TOOLS / "upstream-sync" / "sync.py", "shared_upstream_sync")
        config = sync.load_config(ROOT / sync.CONFIG_IN_REPO)
        self.assertTrue(config["pins"] and config["areas"])
        for pin in config["pins"]:
            self.assertEqual(bool(pin.get("fork_url")), bool(pin.get("fork_branch")), pin["name"])
        self.assertTrue(config["moved_libraries"])

    @needs_shared
    def test_the_changelog_reminder_wrapper_exports_the_shared_function(self):
        wrapper = load(ROOT / "tools/dev/lint/changelog_reminder.py", "mac_changelog_reminder")
        self.assertTrue(callable(wrapper.reminder))


if __name__ == "__main__":
    unittest.main()
