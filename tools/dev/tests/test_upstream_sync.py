"""tools/dev/upstream-sync/sync.py: the merge dry run, with local git repositories only (no network, no build)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SYNC_DIR = Path(__file__).resolve().parents[1] / "upstream-sync"
sys.path.insert(0, str(SYNC_DIR))
import sync  # noqa: E402

AREAS = [{"name": "App", "prefixes": ["Telegram/"]}, {"name": "Libs", "prefixes": ["third-party/"]}]
PINS = [{"name": "tgcalls", "path": "submodules/tgcalls", "upstream_url": "x"},
        {"name": "other", "path": "submodules/other", "upstream_url": "y"}]
SHA_A, SHA_B, SHA_C = "a" * 40, "b" * 40, "c" * 40


def g(cwd, *args, **kw):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(cwd), *args], check=True,
                          capture_output=True, text=True, **kw).stdout.strip()


def write(root, files):
    for name, text in files.items():
        path = Path(root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def commit_all(root, message, links):
    """`git add -A` would drop a gitlink whose directory does not exist, so the links are set after it."""
    g(root, "add", "-A")
    for path, sha in links.items():
        g(root, "update-index", "--add", "--cacheinfo", f"160000,{sha},{path}")
    g(root, "commit", "-q", "-m", message)


class Parsing(unittest.TestCase):
    def test_clean_merge_is_the_tree_alone(self):
        result = sync.parse_merge_tree("abc123\n")
        self.assertEqual((result.tree, result.conflicts, result.messages), ("abc123", [], []))

    def test_conflicts_then_messages(self):
        text = "abc\nTelegram/a.swift\nbuild-system/x.json\n\nAuto-merging Telegram/a.swift\nCONFLICT (content): Merge conflict in Telegram/a.swift\n"
        result = sync.parse_merge_tree(text)
        self.assertEqual(result.conflicts, ["Telegram/a.swift", "build-system/x.json"])
        self.assertEqual(len(result.conflict_messages), 1)

    def test_area_grouping_orders_by_size_and_falls_back_to_the_path(self):
        grouped = sync.group_by_area(["Telegram/a", "Telegram/b", "third-party/x", "docs/guide/a.md", "README.md"], AREAS)
        self.assertEqual(list(grouped)[0], "App")
        self.assertEqual(sync.area_of("docs/guide/a.md", AREAS), "docs/guide")
        self.assertEqual(sync.area_of("README.md", AREAS), "(top level)")

    def test_gitlinks_and_pin_changes(self):
        links = sync.parse_gitlinks(f"160000 commit {SHA_A}\tsubmodules/tgcalls\n100644 blob {SHA_B}\tsubmodules/file\n")
        self.assertEqual(links, {"submodules/tgcalls": SHA_A})
        changes = sync.pin_changes({"submodules/tgcalls": SHA_A, "submodules/other": SHA_B},
                                   {"submodules/tgcalls": SHA_C, "submodules/other": SHA_B}, {"submodules/tgcalls": SHA_A}, PINS)
        self.assertEqual([(c.name, c.old, c.new, c.ours) for c in changes], [("tgcalls", SHA_A, SHA_C, SHA_A)])

    def test_config_file_loads(self):
        config = sync.load_config()
        self.assertTrue(config["pins"] and config["areas"])
        for pin in config["pins"]:
            self.assertEqual(bool(pin.get("fork_url")), bool(pin.get("fork_branch")), pin["name"])


class DryRun(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name).resolve()
        self.upstream, self.ours = root / "upstream", root / "ours"
        base = {"Telegram/App.swift": "one\ntwo\nthree\n", "Telegram/Other.swift": "x\n", "third-party/lib.txt": "lib\n"}
        for repo in (self.upstream, self.ours):
            repo.mkdir()
            g(repo, "init", "-q", "-b", "main")
            write(repo, base)
            commit_all(repo, "base", {"submodules/tgcalls": SHA_A})
        g(self.upstream, "tag", "v1")
        self.base = g(self.ours, "rev-parse", "HEAD")
        # Our work: edits the line upstream edits too, and adds a file.
        write(self.ours, {"Telegram/App.swift": "one\nTWO ours\nthree\n", "Telegram/Ours.swift": "ours\n"})
        commit_all(self.ours, "ours", {"submodules/tgcalls": SHA_A})
        # Upstream's next release.
        write(self.upstream, {"Telegram/App.swift": "one\ntwo upstream\nthree\n", "third-party/lib.txt": "lib2\n"})
        commit_all(self.upstream, "13.2", {"submodules/tgcalls": SHA_C})
        g(self.upstream, "tag", "v2")
        self.config = {"upstream_url": str(self.upstream), "base_commit": self.base, "base_label": "v1", "branch": "main",
                       "areas": AREAS, "pins": PINS}

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        return (g(self.ours, "for-each-ref"), g(self.ours, "count-objects", "-v"), g(self.ours, "status", "--porcelain"))

    def test_reports_the_conflict_the_clean_files_and_the_bumped_pin_without_touching_our_repo(self):
        before = self.snapshot()
        text, data = sync.run(self.ours, "v2", None, self.config, offline=True)
        self.assertEqual(data["conflicts"], ["Telegram/App.swift"])
        self.assertEqual(data["conflicts_by_area"], {"App": ["Telegram/App.swift"]})
        self.assertEqual(data["upstream_changed"], 3)  # App.swift, lib.txt and the bumped pin
        self.assertEqual([(p["name"], p["old"], p["new"]) for p in data["pins"]], [("tgcalls", SHA_A, SHA_C)])
        self.assertIn("1 conflicting file", text)
        self.assertIn("tgcalls (submodules/tgcalls)", text)
        self.assertEqual(self.snapshot(), before, "the dry run must not create refs, objects or changes in our repo")
        self.assertEqual(g(self.ours, "tag", "--list"), "")

    def test_clean_when_upstream_touches_other_files(self):
        write(self.ours, {"Telegram/App.swift": "one\ntwo\nthree\n"})
        commit_all(self.ours, "drop our edit of the contested line", {"submodules/tgcalls": SHA_A})
        text, data = sync.run(self.ours, "v2", None, self.config, offline=True)
        self.assertTrue(data["clean"])
        self.assertIn("Merge: clean", text)

    def test_unknown_tag_stops_with_a_message(self):
        with self.assertRaises(SystemExit):
            sync.run(self.ours, "v9", None, self.config, offline=True)

    def test_command_line_exit_status(self):
        config_file = Path(self.tmp.name) / "config.json"
        config_file.write_text(json.dumps(self.config))
        args = ["--tag", "v2", "--repo", str(self.ours), "--config", str(config_file), "--offline"]
        self.assertEqual(sync.main(args), 0)
        self.assertEqual(sync.main(args + ["--fail-on-conflict"]), 1)


if __name__ == "__main__":
    unittest.main()
