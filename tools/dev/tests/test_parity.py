import contextlib
import datetime
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "parity"))

import parity  # noqa: E402

TODAY = datetime.date(2026, 11, 10)
OWNER_URL = "https://github.com/klaipher/example"


def run(repo, *args, env=None):
    full_env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                    GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", **(env or {}))
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True, env=full_env).stdout.strip()


def init(repo):
    Path(repo).mkdir(parents=True, exist_ok=True)
    run(repo, "init", "-q", "-b", "main")
    run(repo, "config", "commit.gpgsign", "false")
    run(repo, "config", "protocol.file.allow", "always")


def commit(repo, files, message, date=None):
    for path, text in files.items():
        target = Path(repo) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        run(repo, "add", path)
    env = {"GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date} if date else None
    run(repo, "commit", "-q", "-m", message, env=env)
    return run(repo, "rev-parse", "HEAD")


def config_text(extra=""):
    return f"""
core submodules/telegram-ios
core-root ROOT
repo-root ios ROOT
mode shared
reference main
lag commits=2 days=7
pin tgcalls ios=submodules/TgVoipWebrtc/tgcalls mac=submodules/tgcalls
pin webrtc ios=third-party/webrtc/webrtc mac=submodules/tg_owt
webrtc-root mac=src ios=
share submodules/Postbox
share submodules/TelegramCore
allow core submodules/Postbox/Mac.swift | Mac-only file
{extra}
"""


class ConfigTests(unittest.TestCase):
    def test_parses_every_directive(self):
        config = parity.parse_config(config_text("allow webrtc pc until=2026-12-01 | seam"))
        self.assertEqual(config.core_roots, ["ROOT"])
        self.assertEqual(config.repo_roots["ios"], ["ROOT"])
        self.assertEqual((config.lag_commits, config.lag_days), (2, 7))
        self.assertEqual([p.name for p in config.pins], ["tgcalls", "webrtc"])
        self.assertEqual(config.shares, ["submodules/Postbox", "submodules/TelegramCore"])
        self.assertEqual(config.allows[-1].until, datetime.date(2026, 12, 1))

    def test_mirror_lines_name_both_files(self):
        config = parity.parse_config(config_text("mirror ios=a/X.swift mac=b/X.swift warn-until=2026-12-01\nmirror ios=a/Y.swift mac=b/Y.swift"))
        self.assertEqual([(m.ios, m.mac, m.warn_until) for m in config.mirrors],
                         [("a/X.swift", "b/X.swift", datetime.date(2026, 12, 1)), ("a/Y.swift", "b/Y.swift", None)])

    def test_mirror_needs_both_sides(self):
        for text in ("mirror ios=a/X.swift", "mirror mac=b/X.swift", "mirror a b"):
            with self.assertRaises(parity.ParityError):
                parity.parse_config(text)

    def test_allow_needs_a_reason(self):
        with self.assertRaises(parity.ParityError):
            parity.parse_config("allow core submodules/Postbox/X.swift")

    def test_unknown_directive_and_bad_mode_fail(self):
        for text in ("frobnicate x", "mode sideways"):
            with self.assertRaises(parity.ParityError):
                parity.parse_config(text)

    def test_allow_prefix_and_expiry(self):
        config = parity.parse_config("allow webrtc pc until=2026-11-12 | seam")
        self.assertIsNotNone(parity.is_allowed(config, "webrtc", "pc/peer_connection.cc", TODAY))
        self.assertIsNone(parity.is_allowed(config, "webrtc", "pcx/file.cc", TODAY))
        self.assertIsNone(parity.is_allowed(config, "core", "pc/peer_connection.cc", TODAY))
        self.assertIsNone(parity.is_allowed(config, "webrtc", "pc/a.cc", datetime.date(2026, 11, 13)))

    def test_repository_file_parses(self):
        root = Path(__file__).resolve().parents[3]
        config = parity.load_config(root)
        self.assertTrue(config.core_roots and config.shares and config.pins)
        self.assertTrue(all(a.reason for a in config.allows))

    def test_repository_mirrors_name_the_vp9_copies(self):
        root = Path(__file__).resolve().parents[3]
        config = parity.load_config(root)
        names = {m.ios.rsplit("/", 1)[-1] for m in config.mirrors}
        self.assertEqual(names, {"VP9HardwareDecoder.swift", "WebMStickerDemuxer.swift", "feature-parity.md"})
        for mirror in config.mirrors:
            self.assertEqual(mirror.ios.rsplit("/", 1)[-1], mirror.mac.rsplit("/", 1)[-1])


class CoreRepoCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.core = Path(self.tmp.name) / "core"
        init(self.core)
        self.root_sha = commit(self.core, {"submodules/Postbox/A.swift": "a\n", "submodules/TelegramCore/B.swift": "b\n"}, "root")
        self.config = parity.parse_config(config_text().replace("ROOT", self.root_sha))

    def lag(self, pin, lts=None):
        report = parity.Report()
        parity.core_ahead_and_behind(report, self.core, pin, "main", self.config, TODAY, lts)
        return {name: (level, message) for level, name, message in report.items}


class RootTests(CoreRepoCase):
    def test_own_history_passes(self):
        commit(self.core, {"submodules/Postbox/A.swift": "a2\n"}, "next")
        report = parity.Report()
        parity.check_roots(report, "r", self.core, ["HEAD"], self.config.core_roots)
        self.assertFalse(report.failed)

    def test_foreign_root_fails(self):
        run(self.core, "checkout", "-q", "--orphan", "telegram")
        foreign = commit(self.core, {"x": "x\n"}, "telegram history")
        report = parity.Report()
        parity.check_roots(report, "r", self.core, [foreign], self.config.core_roots)
        self.assertTrue(report.failed)
        self.assertIn(foreign[:10], report.lines()[0])

    def test_merge_of_foreign_history_fails(self):
        run(self.core, "checkout", "-q", "--orphan", "telegram")
        commit(self.core, {"x": "x\n"}, "telegram history")
        run(self.core, "checkout", "-q", "main")
        run(self.core, "merge", "-q", "--allow-unrelated-histories", "-m", "bad merge", "telegram")
        report = parity.Report()
        parity.check_roots(report, "r", self.core, ["main"], self.config.core_roots)
        self.assertTrue(report.failed)

    def test_no_configured_root_only_warns(self):
        report = parity.Report()
        parity.check_roots(report, "r", self.core, ["HEAD"], [])
        self.assertFalse(report.failed)
        self.assertEqual(report.items[0][0], "warning")


class LagAndFilesTests(CoreRepoCase):
    def test_pin_on_reference_is_clean(self):
        pin = commit(self.core, {"submodules/Postbox/A.swift": "a2\n"}, "fix")
        result = self.lag(pin)
        self.assertEqual(result["core-ancestry"][0], "ok")
        self.assertEqual(result["core-lag"][0], "ok")
        self.assertEqual(result["core-files"][0], "ok")

    def test_lag_counts_only_shared_paths_and_blocks_over_limit(self):
        pin = run(self.core, "rev-parse", "HEAD")
        for n in range(3):
            commit(self.core, {"submodules/Postbox/A.swift": f"n{n}\n"}, f"fix {n}")
        commit(self.core, {"Telegram/Unrelated.swift": "u\n"}, "not shared")
        result = self.lag(pin)
        self.assertEqual(result["core-lag"][0], "error")
        self.assertIn("3 commit(s)", result["core-lag"][1])

    def test_lag_is_a_warning_before_block_from(self):
        self.config.block_from = datetime.date(2026, 12, 1)
        pin = run(self.core, "rev-parse", "HEAD")
        for n in range(3):
            commit(self.core, {"submodules/Postbox/A.swift": f"n{n}\n"}, f"fix {n}")
        self.assertEqual(self.lag(pin)["core-lag"][0], "warning")

    def test_lag_age_blocks(self):
        pin = run(self.core, "rev-parse", "HEAD")
        commit(self.core, {"submodules/Postbox/A.swift": "old\n"}, "old fix", date="2026-10-01T12:00:00")
        result = self.lag(pin)
        self.assertEqual(result["core-lag"][0], "error")
        self.assertIn("days", result["core-lag"][1])

    def test_pin_not_on_main_fails_in_shared_mode_and_warns_in_legacy(self):
        run(self.core, "checkout", "-q", "-b", "side")
        pin = commit(self.core, {"submodules/Postbox/A.swift": "side\n"}, "side only")
        run(self.core, "checkout", "-q", "main")
        commit(self.core, {"submodules/TelegramCore/B.swift": "b2\n"}, "main moves")
        self.assertEqual(self.lag(pin)["core-ancestry"][0], "error")
        self.config.mode = "legacy"
        self.assertEqual(self.lag(pin)["core-ancestry"][0], "warning")

    def test_mac_only_edit_to_shared_file_is_flagged(self):
        run(self.core, "checkout", "-q", "-b", "lts")
        pin = commit(self.core, {"submodules/TelegramCore/B.swift": "mac only\n"}, "mac tweak")
        run(self.core, "checkout", "-q", "main")
        commit(self.core, {"submodules/Postbox/A.swift": "a2\n"}, "main moves")
        result = self.lag(pin, lts=pin)
        self.assertEqual(result["core-files"][0], "error")
        self.assertIn("submodules/TelegramCore/B.swift", result["core-files"][1])

    def test_allow_listed_mac_file_passes(self):
        run(self.core, "checkout", "-q", "-b", "lts")
        pin = commit(self.core, {"submodules/Postbox/Mac.swift": "mac\n"}, "mac file")
        run(self.core, "checkout", "-q", "main")
        commit(self.core, {"submodules/TelegramCore/B.swift": "b2\n"}, "main moves")
        self.assertEqual(self.lag(pin, lts=pin)["core-files"][0], "ok")

    def test_cherry_pick_from_main_is_not_flagged(self):
        run(self.core, "checkout", "-q", "-b", "lts")
        run(self.core, "checkout", "-q", "main")
        fix = commit(self.core, {"submodules/TelegramCore/B.swift": "fixed\n"}, "fix on main")
        commit(self.core, {"submodules/Postbox/A.swift": "a3\n"}, "main moves on")
        run(self.core, "checkout", "-q", "lts")
        run(self.core, "cherry-pick", "-x", fix)
        pin = run(self.core, "rev-parse", "HEAD")
        result = self.lag(pin, lts=pin)
        self.assertEqual(result["core-files"][0], "ok")
        self.assertEqual(result["core-ancestry"][0], "ok")

    def edited_pick(self):
        run(self.core, "checkout", "-q", "-b", "lts")
        run(self.core, "checkout", "-q", "main")
        fix = commit(self.core, {"submodules/TelegramCore/B.swift": "fixed\n"}, "fix on main")
        commit(self.core, {"submodules/TelegramCore/B.swift": "fixed again\n"}, "main moves on")
        run(self.core, "checkout", "-q", "lts")
        return commit(self.core, {"submodules/TelegramCore/B.swift": "fixed differently\n"},
                      f"fix on main\n\n(cherry picked from commit {fix})")

    def test_cherry_pick_trailer_does_not_hide_extra_edits(self):
        pin = self.edited_pick()
        result = self.lag(pin, lts=pin)
        self.assertEqual(result["core-files"][0], "error")
        self.assertIn("submodules/TelegramCore/B.swift", result["core-files"][1])

    def test_adapted_backport_passes_with_an_allow_entry(self):
        pin = self.edited_pick()
        self.config.allows.append(parity.Allow("core", "submodules/TelegramCore/B.swift", "LTS backport", None))
        self.assertEqual(self.lag(pin, lts=pin)["core-files"][0], "ok")

    def test_exact_cherry_pick_with_different_context_is_not_flagged(self):
        lines = [f"line {i}\n" for i in range(12)]
        base = commit(self.core, {"submodules/TelegramCore/B.swift": "".join(lines)}, "base")
        run(self.core, "checkout", "-q", "-b", "lts")
        run(self.core, "checkout", "-q", "main")
        moved = lines[:]
        moved[0] = "line 0 on main\n"
        commit(self.core, {"submodules/TelegramCore/B.swift": "".join(moved)}, "main edits the top")
        fixed = moved[:]
        fixed[9] = "line 9 fixed\n"
        fix = commit(self.core, {"submodules/TelegramCore/B.swift": "".join(fixed)}, "fix on main")
        run(self.core, "checkout", "-q", "lts")
        self.assertEqual(run(self.core, "rev-parse", "HEAD^{tree}"), run(self.core, "rev-parse", f"{base}^{{tree}}"))
        picked = lines[:]
        picked[9] = "line 9 fixed\n"
        pin = commit(self.core, {"submodules/TelegramCore/B.swift": "".join(picked)},
                     f"fix on main\n\n(cherry picked from commit {fix})")
        self.assertEqual(self.lag(pin, lts=pin)["core-files"][0], "ok")

    def test_evil_merge_on_lts_is_flagged_and_a_clean_merge_is_not(self):
        run(self.core, "checkout", "-q", "-b", "lts")
        commit(self.core, {"submodules/Postbox/Mac.swift": "mac\n"}, "lts work")
        run(self.core, "checkout", "-q", "main")
        commit(self.core, {"submodules/Postbox/A.swift": "a2\n"}, "main fix")
        run(self.core, "checkout", "-q", "lts")
        run(self.core, "merge", "-q", "--no-ff", "--no-edit", "main")
        clean = run(self.core, "rev-parse", "HEAD")
        run(self.core, "checkout", "-q", "main")
        commit(self.core, {"submodules/TelegramCore/B.swift": "b2\n"}, "main moves on")
        self.assertEqual(self.lag(clean, lts=clean)["core-files"][0], "ok")
        run(self.core, "checkout", "-q", "lts")
        run(self.core, "merge", "-q", "--no-ff", "--no-commit", "main")
        Path(self.core, "submodules/TelegramCore/B.swift").write_text("b2 plus a mac edit\n")
        run(self.core, "add", "submodules/TelegramCore/B.swift")
        run(self.core, "commit", "-q", "--no-edit")
        evil = run(self.core, "rev-parse", "HEAD")
        result = self.lag(evil, lts=evil)
        self.assertEqual(result["core-files"][0], "error")
        self.assertIn("submodules/TelegramCore/B.swift", result["core-files"][1])


class PublishedTests(unittest.TestCase):
    def test_owner_remote_branch_contains_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "r"
            init(repo)
            sha = commit(repo, {"a": "a\n"}, "one")
            run(repo, "remote", "add", "origin", OWNER_URL)
            self.assertFalse(parity.reachable_from_owner(repo, sha, "klaipher")[0])
            run(repo, "update-ref", "refs/remotes/origin/main", sha)
            self.assertTrue(parity.reachable_from_owner(repo, sha, "klaipher")[0])
            later = commit(repo, {"a": "b\n"}, "two")
            self.assertFalse(parity.reachable_from_owner(repo, later, "klaipher")[0])

    def test_third_party_remote_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "r"
            init(repo)
            sha = commit(repo, {"a": "a\n"}, "one")
            run(repo, "remote", "add", "origin", "https://github.com/macosswift/tg_owt")
            run(repo, "update-ref", "refs/remotes/origin/main", sha)
            self.assertFalse(parity.reachable_from_owner(repo, sha, "klaipher")[0])


    def test_local_path_remote_under_the_owner_home_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "r"
            init(repo)
            sha = commit(repo, {"a": "a\n"}, "one")
            for url in ("/Users/klaipher/Projects/nanogram-macos/submodules/tgcalls", "file:///Users/klaipher/x",
                        "../klaipher/x"):
                subprocess.run(["git", "-C", str(repo), "remote", "remove", "local"], capture_output=True)
                run(repo, "remote", "add", "local", url)
                run(repo, "update-ref", "refs/remotes/local/main", sha)
                self.assertFalse(parity.reachable_from_owner(repo, sha, "klaipher")[0], url)

    def test_owner_url_forms(self):
        for url in ("https://github.com/klaipher/x", "https://github.com/klaipher/x.git", "git@github.com:klaipher/x.git",
                    "ssh://git@github.com/klaipher/x"):
            self.assertTrue(parity.is_owner_url(url, "klaipher"), url)
        for url in ("https://github.com/notklaipher/x", "https://github.com/klaipherx/y", "/Users/klaipher/x",
                    "https://github.com/TelegramMessenger/klaipher"):
            self.assertFalse(parity.is_owner_url(url, "klaipher"), url)


class WebrtcTests(unittest.TestCase):
    def test_differences_map_the_src_root_and_skip_non_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            mac, ios = Path(tmp) / "owt", Path(tmp) / "webrtc"
            init(mac)
            init(ios)
            same = {"src/api/same.cc": "x\n", "src/pc/seam.cc": "mac\n", "src/BUILD.gn": "mac\n", "src/mac_only.cc": "m\n"}
            commit(mac, same, "mac")
            commit(ios, {"api/same.cc": "x\n", "pc/seam.cc": "ios\n", "BUILD.gn": "ios\n", "ios_only.cc": "i\n"}, "ios")
            config = parity.parse_config("webrtc-root mac=src ios=")
            diff = parity.webrtc_differences(config, mac, run(mac, "rev-parse", "HEAD"), ios, run(ios, "rev-parse", "HEAD"))
            self.assertEqual(diff, ["pc/seam.cc"])


class MacCheckTests(unittest.TestCase):
    """A Mac superproject with a core submodule, tgcalls and tg_owt, and an iOS superproject next to it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.mac, self.ios = base / "mac", base / "ios"
        init(self.ios)
        init(self.mac)
        self.core = self.mac / "submodules/telegram-ios"
        init(self.core)
        root_sha = commit(self.core, {"submodules/Postbox/A.swift": "a\n"}, "root")
        self.pin = root_sha
        self.calls = self.sub(self.mac / "submodules/tgcalls", {"x.cc": "x\n"})
        self.owt = self.sub(self.mac / "submodules/tg_owt", {"src/api/a.cc": "a\n"})
        self.calls_ios = self.sub(self.ios / "submodules/TgVoipWebrtc/tgcalls", {"x.cc": "x\n"}, share_with=self.calls)
        self.web_ios = self.sub(self.ios / "third-party/webrtc/webrtc", {"api/a.cc": "a\n"})
        for repo in (self.core,):
            run(repo, "remote", "add", "origin", OWNER_URL)
            run(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.text = config_text().replace("ROOT", root_sha).replace("reference main", "reference origin/main")
        (self.mac / "docs").mkdir()
        (self.mac / "docs/mac-core-paths.txt").write_text(self.text)
        run(self.mac, "add", "docs", "submodules")
        run(self.mac, "commit", "-q", "-m", "mac")
        run(self.ios, "add", "submodules", "third-party")
        run(self.ios, "commit", "-q", "-m", "ios")

    def sub(self, path, files, share_with=None):
        init(path)
        sha = commit(path, files, "sub", date="2026-11-01T00:00:00+0000")
        run(path, "remote", "add", "origin", OWNER_URL)
        run(path, "update-ref", "refs/remotes/origin/main", sha)
        return sha

    def check(self, **kwargs):
        config = parity.parse_config(self.text)
        report = parity.check_mac(self.mac, config, TODAY, ios_repo=self.ios, ios_ref="HEAD", **kwargs)
        return report, {name: level for level, name, _ in report.items}

    def test_everything_in_step_passes(self):
        report, levels = self.check()
        self.assertFalse(report.failed, report.lines())
        self.assertEqual(levels["pin-equal-tgcalls"], "ok")
        self.assertEqual(levels["webrtc"], "ok")

    def test_unpublished_pin_fails(self):
        run(self.calls_dir(), "update-ref", "-d", "refs/remotes/origin/main")
        report, levels = self.check()
        self.assertEqual(levels["pin-tgcalls"], "error")

    def calls_dir(self):
        return self.mac / "submodules/tgcalls"

    def test_tgcalls_sha_mismatch_fails(self):
        newer = commit(self.mac / "submodules/tgcalls", {"x.cc": "y\n"}, "mac moves")
        run(self.mac / "submodules/tgcalls", "update-ref", "refs/remotes/origin/main", newer)
        run(self.mac, "add", "submodules/tgcalls")
        run(self.mac, "commit", "-q", "-m", "bump")
        report, levels = self.check()
        self.assertEqual(levels["pin-equal-tgcalls"], "error")
        self.assertTrue(report.failed)

    def add_mirror(self, ios_text="same\n", mac_text="same\n", extra=""):
        commit(self.core, {"submodules/Copy/X.swift": ios_text}, "core copy")
        new_pin = run(self.core, "rev-parse", "HEAD")
        run(self.core, "update-ref", "refs/remotes/origin/main", new_pin)
        commit(self.mac, {"packages/Copy/X.swift": mac_text}, "mac copy")
        run(self.mac, "add", "submodules/telegram-ios")
        run(self.mac, "commit", "-q", "-m", "bump core")
        self.text += f"\nmirror ios=submodules/Copy/X.swift mac=packages/Copy/X.swift {extra}\n"

    def test_identical_mirror_passes(self):
        self.add_mirror()
        report, levels = self.check()
        self.assertEqual(levels["mirror-X.swift"], "ok")
        self.assertFalse(report.failed, report.lines())

    def test_drifted_mirror_fails_on_the_mac_side(self):
        self.add_mirror(mac_text="edited on the Mac\n")
        report, levels = self.check()
        self.assertEqual(levels["mirror-X.swift"], "error")
        self.assertTrue(report.failed)
        self.assertIn("port the change", [m for l, n, m in report.items if n == "mirror-X.swift"][0])

    def test_mirror_warning_window_makes_it_soft(self):
        self.add_mirror(mac_text="edited on the Mac\n", extra="warn-until=2026-12-01")
        report, levels = self.check()
        self.assertEqual(levels["mirror-X.swift"], "warning")
        self.assertFalse(report.failed, report.lines())

    def test_unreadable_mirror_only_warns(self):
        self.text += "\nmirror ios=submodules/Nope/X.swift mac=packages/Nope/X.swift\n"
        report, levels = self.check()
        self.assertEqual(levels["mirror-X.swift"], "warning")
        self.assertFalse(report.failed, report.lines())

    def test_pin_warning_window_makes_it_soft(self):
        newer = commit(self.mac / "submodules/tgcalls", {"x.cc": "y\n"}, "mac moves")
        run(self.mac / "submodules/tgcalls", "update-ref", "refs/remotes/origin/main", newer)
        run(self.mac, "add", "submodules/tgcalls")
        run(self.mac, "commit", "-q", "-m", "bump")
        self.text += "\npin tgcalls ios=submodules/TgVoipWebrtc/tgcalls mac=submodules/tgcalls warn-until=2026-12-01\n"
        self.text = self.text.replace("pin tgcalls ios=submodules/TgVoipWebrtc/tgcalls mac=submodules/tgcalls\n", "", 1)
        _, levels = self.check()
        self.assertEqual(levels["pin-equal-tgcalls"], "warning")

    def test_webrtc_difference_needs_an_allow_entry(self):
        commit(self.owt_dir(), {"src/api/a.cc": "changed\n"}, "mac fix")
        run(self.owt_dir(), "update-ref", "refs/remotes/origin/main", "HEAD")
        run(self.mac, "add", "submodules/tg_owt")
        run(self.mac, "commit", "-q", "-m", "owt")
        report, levels = self.check()
        self.assertEqual(levels["webrtc"], "error")
        self.text += "\nallow webrtc api | intended\n"
        report, levels = self.check()
        self.assertEqual(levels["webrtc"], "ok")

    def owt_dir(self):
        return self.mac / "submodules/tg_owt"

    def test_dirty_core_warns_and_blocks_a_release(self):
        (self.core / "submodules/Postbox/A.swift").write_text("edited\n")
        _, levels = self.check()
        self.assertEqual(levels["core-clean"], "warning")
        report, levels = self.check(release=True)
        self.assertEqual(levels["core-clean"], "error")
        self.assertTrue(report.failed)

    def test_foreign_core_history_fails(self):
        run(self.core, "checkout", "-q", "--orphan", "telegram")
        foreign = commit(self.core, {"x": "x\n"}, "telegram")
        run(self.core, "update-ref", "refs/remotes/origin/main", foreign)
        report, levels = self.check(pin_override=foreign)
        self.assertEqual(levels["core-root"], "error")

    def test_cli_exit_codes(self):
        script = Path(parity.__file__)
        good = subprocess.run([sys.executable, str(script), "roots", "--root", str(self.mac), self.pin],
                              capture_output=True, text=True)
        self.assertEqual(good.returncode, 0, good.stderr)
        (self.core / "x").write_text("x")
        run(self.core, "checkout", "-q", "--orphan", "telegram")
        foreign = commit(self.core, {"y": "y\n"}, "telegram")
        bad = subprocess.run([sys.executable, str(script), "roots", "--root", str(self.mac), foreign],
                             capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)


class IosSideTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ios = Path(self.tmp.name) / "ios"
        init(self.ios)
        (self.ios / "docs").mkdir()
        self.first = commit(self.ios, {"submodules/Postbox/A.swift": "a\n"}, "root")
        self.text = config_text().replace("ROOT", self.first)
        (self.ios / "docs/mac-core-paths.txt").write_text(self.text)
        run(self.ios, "add", "docs")
        run(self.ios, "commit", "-q", "-m", "paths")
        self.config = parity.parse_config(self.text)

    def hook(self, local, remote, ref="refs/heads/main"):
        stdin = f"{ref} {local} {ref} {remote}\n"
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = parity.push_hook(self.ios, "origin", stdin, TODAY)
        return code, out.getvalue(), err.getvalue()

    def test_history_rooted_push_passes_and_notes_shared_paths(self):
        before = run(self.ios, "rev-parse", "HEAD")
        after = commit(self.ios, {"submodules/Postbox/A.swift": "a2\n"}, "fix")
        code, out, err = self.hook(after, before)
        self.assertEqual(code, 0, err)
        self.assertIn("tg core-bump", out)

    def test_unshared_push_is_silent(self):
        before = run(self.ios, "rev-parse", "HEAD")
        after = commit(self.ios, {"Telegram/App.swift": "x\n"}, "app only")
        code, out, _ = self.hook(after, before)
        self.assertEqual((code, out), (0, ""))

    def test_foreign_history_blocks_the_push(self):
        run(self.ios, "checkout", "-q", "--orphan", "telegram")
        foreign = commit(self.ios, {"x": "x\n"}, "telegram")
        code, _, err = self.hook(foreign, parity.ZERO_SHA)
        self.assertEqual(code, 1)
        self.assertIn("not ours", err)

    def test_tag_and_delete_pushes_are_ignored(self):
        self.assertEqual(self.hook(parity.ZERO_SHA, "a" * 40)[0], 0)
        self.assertEqual(self.hook(run(self.ios, "rev-parse", "HEAD"), parity.ZERO_SHA, ref="refs/tags/x")[0], 0)

    def test_escape_hatch(self):
        run(self.ios, "checkout", "-q", "--orphan", "telegram")
        foreign = commit(self.ios, {"x": "x\n"}, "telegram")
        os.environ["TG_PARITY"] = "0"
        self.addCleanup(os.environ.pop, "TG_PARITY", None)
        self.assertEqual(self.hook(foreign, parity.ZERO_SHA)[0], 0)

    def test_unpublished_pin_in_pushed_gitlink_blocks(self):
        calls = self.ios / "submodules/TgVoipWebrtc/tgcalls"
        init(calls)
        commit(calls, {"x.cc": "x\n"}, "sub")
        run(calls, "remote", "add", "origin", OWNER_URL)
        before = run(self.ios, "rev-parse", "HEAD")
        run(self.ios, "add", "submodules/TgVoipWebrtc/tgcalls")
        run(self.ios, "commit", "-q", "-m", "pin")
        after = run(self.ios, "rev-parse", "HEAD")
        code, _, err = self.hook(after, before)
        self.assertEqual(code, 1)
        self.assertIn("unpublished", err)
        run(calls, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.assertEqual(self.hook(after, before)[0], 0)

    def unpublished_tgcalls_on_main(self):
        calls = self.ios / "submodules/TgVoipWebrtc/tgcalls"
        init(calls)
        commit(calls, {"x.cc": "x\n"}, "sub")
        run(calls, "remote", "add", "origin", OWNER_URL)
        run(self.ios, "add", "submodules/TgVoipWebrtc/tgcalls")
        run(self.ios, "commit", "-q", "-m", "pin")
        run(self.ios, "remote", "add", "origin", "https://github.com/klaipher/nanogram.git")
        run(self.ios, "update-ref", "refs/remotes/origin/main", "HEAD")
        return calls

    def test_hotfix_branch_is_not_blocked_by_a_pin_already_on_the_remote(self):
        self.unpublished_tgcalls_on_main()
        run(self.ios, "checkout", "-q", "-b", "hotfix")
        hotfix = commit(self.ios, {"Telegram/App.swift": "fix\n"}, "hotfix")
        code, _, err = self.hook(hotfix, parity.ZERO_SHA, ref="refs/heads/hotfix")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.hook(run(self.ios, "rev-parse", "main"), parity.ZERO_SHA, ref="refs/heads/copy")[0], 0)

    def test_new_branch_that_moves_a_pin_to_an_unpublished_commit_blocks(self):
        calls = self.unpublished_tgcalls_on_main()
        run(calls, "update-ref", "refs/remotes/origin/main", "HEAD")
        commit(calls, {"x.cc": "y\n"}, "sub 2")
        run(self.ios, "checkout", "-q", "-b", "bump")
        run(self.ios, "add", "submodules/TgVoipWebrtc/tgcalls")
        run(self.ios, "commit", "-q", "-m", "bump")
        code, _, err = self.hook(run(self.ios, "rev-parse", "HEAD"), parity.ZERO_SHA, ref="refs/heads/bump")
        self.assertEqual(code, 1)
        self.assertIn("unpublished", err)

    def mac_with_copy(self, text):
        mac = Path(self.tmp.name) / "mac"
        init(mac)
        commit(mac, {"packages/Copy/X.swift": text}, "mac")
        return mac

    def mirrored(self, ios_text):
        commit(self.ios, {"submodules/Copy/X.swift": ios_text}, "copy")
        text = self.text + "\nmirror ios=submodules/Copy/X.swift mac=packages/Copy/X.swift\n"
        return parity.parse_config(text)

    def test_mirror_drift_never_blocks_ios(self):
        config = self.mirrored("ios\n")
        report = parity.check_ios(self.ios, config, mac_repo=self.mac_with_copy("mac\n"), today=TODAY)
        self.assertFalse(report.failed, report.lines())
        self.assertEqual([level for level, name, _ in report.items if name == "mirror-X.swift"], ["warning"])

    def test_identical_mirror_is_ok_on_ios(self):
        config = self.mirrored("same\n")
        report = parity.check_ios(self.ios, config, mac_repo=self.mac_with_copy("same\n"), today=TODAY)
        self.assertEqual([level for level, name, _ in report.items if name == "mirror-X.swift"], ["ok"])

    def test_push_touching_a_mirrored_file_notes_the_mac_copy(self):
        config = self.mirrored("one\n")
        self.text += "\nmirror ios=submodules/Copy/X.swift mac=packages/Copy/X.swift\n"
        (self.ios / "docs/mac-core-paths.txt").write_text(self.text)
        run(self.ios, "add", "docs")
        run(self.ios, "commit", "-q", "-m", "paths")
        before = run(self.ios, "rev-parse", "HEAD")
        after = commit(self.ios, {"submodules/Copy/X.swift": "two\n"}, "edit")
        code, out, err = self.hook(after, before)
        self.assertEqual(code, 0, err)
        self.assertIn("identical copy", out)
        self.assertEqual(config.mirrors[0].ios, "submodules/Copy/X.swift")

    def test_fast_never_reads_the_mac_to_block(self):
        report = parity.check_ios(self.ios, self.config, mac_repo=None)
        self.assertFalse(report.failed)


if __name__ == "__main__":
    unittest.main()
