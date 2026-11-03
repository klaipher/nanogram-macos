import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, frameworks, fwcache  # noqa: E402


def populate(root):
    outputs = frameworks.required_outputs(root)
    for path in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x")
    return outputs


class VerifyOutputsTests(unittest.TestCase):
    def test_required_outputs_cover_every_library(self):
        with tempfile.TemporaryDirectory() as tmp:
            names = {p.name for p in frameworks.required_outputs(Path(tmp))}
        for name in ("libssl.a", "libopenh264.a", "libdav1d.a", "libtde2e.a", "libwallet_engine.a",
                     "libmtproto_engine_ffi.a", "libmac_framework_objc_static.a", "libtlottie.a"):
            self.assertIn(name, names)

    def test_xcframework_slices_are_arm64_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [str(p) for p in frameworks.required_outputs(Path(tmp))]
        self.assertTrue(any("/macos-arm64/" in p for p in paths))
        self.assertFalse(any("x86_64" in p for p in paths))

    def test_verify_outputs_rejects_fat_lib(self):
        with tempfile.TemporaryDirectory() as tmp:
            populate(Path(tmp))
            problems = frameworks.verify_outputs(Path(tmp), archs_of=lambda path: ["x86_64", "arm64"])
        self.assertTrue(problems)
        self.assertTrue(all("x86_64" in p for p in problems), problems)
        self.assertTrue(any("libssl.a" in p for p in problems))

    def test_verify_outputs_accepts_arm64(self):
        with tempfile.TemporaryDirectory() as tmp:
            populate(Path(tmp))
            self.assertEqual(frameworks.verify_outputs(Path(tmp), archs_of=lambda path: ["arm64"]), [])

    def test_verify_outputs_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs = populate(Path(tmp))
            next(p for p in outputs if p.name == "libssl.a").unlink()
            problems = frameworks.verify_outputs(Path(tmp), archs_of=lambda path: ["arm64"])
        self.assertEqual(len(problems), 1)
        self.assertIn("libssl.a", problems[0])
        self.assertIn("missing", problems[0])


class BuildEnvironmentTests(unittest.TestCase):
    def test_build_env_comes_from_our_xcconfig(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(config, "CACHE_DIR", Path(tmp)):
            env = frameworks.build_environment(Path("/tmp/timing.tsv"), base={})
        self.assertEqual(env["XCODE_XCCONFIG_FILE"], str(config.ROOT / "nanogram" / "Nanogram.xcconfig"))
        self.assertEqual(env["MACOSX_DEPLOYMENT_TARGET"], "15.0")
        self.assertEqual(env["ARCHS"], "arm64")
        self.assertEqual(env["CMAKE_POLICY_VERSION_MINIMUM"], "3.5")
        self.assertEqual(env["BUILD_TIMING_LOG"], "/tmp/timing.tsv")

    def test_conditional_settings_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            xcconfig = Path(tmp) / "a.xcconfig"
            xcconfig.write_text("// c\nARCHS = arm64\nLLVM_LTO[config=Release] = YES_THIN\n#include \"b.xcconfig\"\n")
            self.assertEqual(frameworks.xcconfig_settings(xcconfig), {"ARCHS": "arm64"})


class RustScriptTests(unittest.TestCase):
    SCRIPTS = ("core-xprojects/wallet-engine/wallet-engine/build.sh",
               "core-xprojects/mtproto-engine/mtproto-engine/build.sh",
               "core-xprojects/tlottie/build.sh")

    def test_every_cargo_call_unsets_deployment_target(self):
        for script in self.SCRIPTS:
            text = (config.ROOT / script).read_text()
            calls = [line for line in text.splitlines() if re.search(r'"\$CARGO_BIN" (build|run|rustc)', line)]
            self.assertTrue(calls, script)
            for line in calls:
                self.assertIn("env -u MACOSX_DEPLOYMENT_TARGET", line, f"{script}: {line.strip()}")
            self.assertNotIn("DEPLOYMENT_TARGET=", text, script)
            self.assertNotIn("x86_64", text, script)


class FakeRunner:
    def __init__(self, current=(), cached=(), stamps=None, rust="rustc 1"):
        self.stamps_by_unit = stamps or {unit: f"stamp of {unit}\n" for unit in fwcache.UNITS}
        self.current = set(current)
        self.broken = set()
        self.evicted = set()
        self.failing = set()
        self.rust_line = rust
        self.cached = {fwcache.cache_key(self.stamps_by_unit[u], rust) for u in cached}
        self.calls = []

    def prepare(self):
        self.calls.append(("prepare",))

    def stamps(self):
        return dict(self.stamps_by_unit)

    def rust(self):
        return self.rust_line

    def is_current(self, unit, stamp):
        return unit in self.current

    def find(self, key):
        if key in self.evicted:
            self.evicted.discard(key)
            self.cached.discard(key)
            return fwcache.Entry(key, "?", Path("/cache") / key, 1, 0.0)
        if key in self.cached:
            return fwcache.Entry(key, "?", Path("/cache") / key, 1, 0.0)
        return None

    def restore(self, unit, entry, stamp):
        self.calls.append(("restore", unit))
        if unit in self.failing:
            raise config.ConfigError(f"cache entry for {unit} has no files")
        if unit not in self.broken:
            self.current.add(unit)

    def configure(self):
        self.calls.append(("configure",))
        self.current.update(fwcache.UNITS)

    def headers_synced(self):
        return True

    def sync_headers(self):
        self.calls.append(("sync_headers",))

    def build_tlottie(self, stamp):
        self.calls.append(("build_tlottie",))
        self.current.add("tlottie")

    def write_stamp(self, unit, stamp):
        self.calls.append(("write_stamp", unit))
        self.current.add(unit)

    def store(self, unit, key, stamp):
        self.calls.append(("store", unit))
        self.cached.add(key)

    def prune(self, keep):
        self.calls.append(("prune",))

    def cache_size(self):
        return 0

    def names(self):
        return [c[0] for c in self.calls]


ALL = fwcache.UNITS


class CacheRunTests(unittest.TestCase):
    def test_all_current_skips_configure(self):
        runner = FakeRunner(current=ALL, cached=ALL)
        summary = frameworks.run(Path("/root"), True, runner)
        for name in ("configure", "sync_headers", "build_tlottie", "restore", "store"):
            self.assertNotIn(name, runner.names())
        self.assertEqual((summary.current, summary.restored, summary.built), (len(ALL), 0, 0))

    def test_hits_restore_and_skip_configure(self):
        runner = FakeRunner(current=(), cached=ALL)
        summary = frameworks.run(Path("/root"), True, runner)
        self.assertEqual([c[1] for c in runner.calls if c[0] == "restore"], list(ALL))
        self.assertIn("sync_headers", runner.names())
        self.assertNotIn("configure", runner.names())
        self.assertNotIn("build_tlottie", runner.names())
        self.assertEqual((summary.current, summary.restored, summary.built), (0, len(ALL), 0))
        self.assertLess(runner.names().index("restore"), runner.names().index("sync_headers"))

    def test_miss_runs_configure_then_stores(self):
        hits = [u for u in ALL if u != "webrtc"]
        runner = FakeRunner(current=(), cached=hits)
        summary = frameworks.run(Path("/root"), True, runner)
        self.assertEqual(runner.names().count("configure"), 1)
        self.assertEqual([c[1] for c in runner.calls if c[0] == "store"], ["webrtc"])
        self.assertLess(runner.names().index("configure"), runner.names().index("store"))
        self.assertNotIn("build_tlottie", runner.names())
        self.assertEqual(summary.built, 1)

    def test_restore_that_is_not_current_gets_built(self):
        runner = FakeRunner(current=(), cached=ALL)
        runner.broken = {"wallet-engine"}
        summary = frameworks.run(Path("/root"), True, runner)
        self.assertEqual(runner.names().count("configure"), 1)
        self.assertEqual((summary.restored, summary.built), (len(ALL) - 1, 1))

    def test_entry_evicted_after_planning_gets_built(self):
        runner = FakeRunner(current=(), cached=ALL)
        runner.evicted = {fwcache.cache_key(runner.stamps_by_unit["webrtc"], "rustc 1")}
        summary = frameworks.run(Path("/root"), True, runner)
        self.assertNotIn(("restore", "webrtc"), runner.calls)
        self.assertEqual(runner.names().count("configure"), 1)
        self.assertEqual((summary.restored, summary.built), (len(ALL) - 1, 1))

    def test_failed_restore_gets_built(self):
        runner = FakeRunner(current=(), cached=ALL)
        runner.failing = {"OpenSSL"}
        summary = frameworks.run(Path("/root"), True, runner)
        self.assertEqual(runner.names().count("configure"), 1)
        self.assertEqual((summary.restored, summary.built), (len(ALL) - 1, 1))

    def test_missing_rust_never_restores_or_stores_rust_units(self):
        rust_units = set(fwcache.RUST_UNITS)
        runner = FakeRunner(current=(), cached=ALL, rust=fwcache.MISSING_RUST)
        statuses = frameworks.plan(runner.stamps(), runner.is_current, runner.find, fwcache.MISSING_RUST, True)
        self.assertEqual({u for u, s in statuses.items() if s == "build"}, rust_units)
        runner.cached = set()
        frameworks.run(Path("/root"), True, runner)
        restored = {c[1] for c in runner.calls if c[0] == "restore"}
        stored = {c[1] for c in runner.calls if c[0] == "store"}
        self.assertFalse(restored & rust_units, restored)
        self.assertFalse(stored & rust_units, stored)
        self.assertEqual(stored, set(ALL) - rust_units)

    def test_configure_builds_tlottie_once(self):
        runner = FakeRunner(current=(), cached=())
        frameworks.run(Path("/root"), True, runner)
        self.assertEqual(runner.names().count("configure"), 1)
        self.assertNotIn("build_tlottie", runner.names())

    def test_tlottie_miss_alone_builds_only_tlottie(self):
        runner = FakeRunner(current=[u for u in ALL if u != "tlottie"], cached=())
        frameworks.run(Path("/root"), True, runner)
        self.assertIn("build_tlottie", runner.names())
        self.assertNotIn("configure", runner.names())

    def test_current_units_seed_the_cache(self):
        runner = FakeRunner(current=ALL, cached=[u for u in ALL if u != "OpenSSL"])
        frameworks.run(Path("/root"), True, runner)
        self.assertEqual([c[1] for c in runner.calls if c[0] == "store"], ["OpenSSL"])

    def test_no_cache_builds_even_with_hit(self):
        runner = FakeRunner(current=(), cached=ALL)
        statuses = frameworks.plan(runner.stamps(), runner.is_current, runner.find, "rustc 1", use_cache=False)
        self.assertEqual(set(statuses.values()), {"build"})
        frameworks.run(Path("/root"), False, runner)
        self.assertNotIn("restore", runner.names())
        self.assertNotIn("store", runner.names())
        self.assertIn("configure", runner.names())

    def test_plan_statuses(self):
        runner = FakeRunner(current=["OpenSSL"], cached=["libopus"])
        statuses = frameworks.plan(runner.stamps(), runner.is_current, runner.find, "rustc 1", use_cache=True)
        self.assertEqual(statuses["OpenSSL"], "current")
        self.assertEqual(statuses["libopus"], "restore")
        self.assertEqual(statuses["webrtc"], "build")

    def test_tmpdir_points_into_cache(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(config, "CACHE_DIR", Path(tmp)):
            env = frameworks.build_environment(Path("/tmp/timing.tsv"), base={})
            self.assertTrue(env["TMPDIR"].startswith(str(Path(tmp) / "tmp")))
            self.assertTrue(Path(env["TMPDIR"]).is_dir())

    def test_no_cache_flag_from_environment(self):
        with mock.patch.dict(os.environ, {"NANOGRAM_FRAMEWORK_CACHE": "0"}):
            self.assertFalse(frameworks.cache_enabled([]))
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertTrue(frameworks.cache_enabled([]))
            self.assertFalse(frameworks.cache_enabled(["--no-cache"]))


if __name__ == "__main__":
    unittest.main()
