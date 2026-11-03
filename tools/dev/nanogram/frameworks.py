"""`tg frameworks`: native libraries with our settings (arm64, macOS 15), through the shared cache.

Each library (and tlottie) is current, restored from ~/.cache/nanogram-macos/frameworks (fwcache.py) or built.
Upstream's scripts/configure_frameworks.sh runs only when something must be built; it skips current and restored
libraries by their stamps. Finally every required output must exist and hold an arm64 slice only.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Literal, Protocol

if TYPE_CHECKING:
    from .fwcache import Entry

from . import config

XCCONFIG = config.ROOT / "nanogram" / "Nanogram.xcconfig"
SCRIPTS = config.ROOT / "scripts"
EXPORTED_SETTINGS = ("MACOSX_DEPLOYMENT_TARGET", "ARCHS")
SETTING_RE = re.compile(r"^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*(//.*)?$")


def xcconfig_settings(path: Path) -> dict[str, str]:
    """Unconditional `KEY = value` settings of one xcconfig file (no includes, no [config=...] variants)."""
    settings = {}
    for line in Path(path).read_text().splitlines():
        match = SETTING_RE.match(line)
        if match:
            settings[match.group(1)] = match.group(2)
    return settings


def libraries() -> list[str]:
    text = (SCRIPTS / "configure_frameworks.sh").read_text()
    match = re.search(r"^declare -a libs=\(([^)]*)\)", text, re.MULTILINE)
    if not match:
        raise config.ConfigError("scripts/configure_frameworks.sh has no `declare -a libs=(...)` list any more: update frameworks.py")
    return re.findall(r'"([^"]+)"', match.group(1))


def required_outputs(root: Path | None = None) -> list[Path]:
    """Every output upstream's framework_required_outputs lists for `root`, plus tlottie's library."""
    root = Path(root or config.ROOT)
    script = (f'. "{SCRIPTS / "framework-inputs.sh"}"; '
              f'for lib in {" ".join(libraries())}; do framework_required_outputs "$1" "$lib" || exit 1; done')
    out = subprocess.run(["bash", "-c", script, "bash", str(root)], capture_output=True, text=True, check=True).stdout
    paths = [Path(line) for line in out.splitlines() if line.strip()]
    paths.append(root / "core-xprojects" / "tlottie" / "build" / "libtlottie.a")
    return paths


def lipo_archs(path: Path) -> list[str]:
    result = subprocess.run(["lipo", "-archs", str(path)], capture_output=True, text=True, check=False)
    return result.stdout.split() if result.returncode == 0 else [f"unreadable ({result.stderr.strip()})"]


def verify_outputs(root: Path | None = None, archs_of: Callable[[Path], list[str]] = lipo_archs) -> list[str]:
    root = Path(root or config.ROOT)
    problems = []
    for path in required_outputs(root):
        shown = path.relative_to(root) if path.is_relative_to(root) else path
        if not path.is_file() or path.stat().st_size == 0:
            problems.append(f"missing {shown}")
            continue
        if path.suffix == ".a":
            archs = archs_of(path)
            if archs != ["arm64"]:
                problems.append(f"{shown}: architectures {' '.join(archs)} (want arm64)")
    return problems


def build_environment(timing_log: Path, base: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if base is None else base)
    settings = xcconfig_settings(XCCONFIG)
    for key in EXPORTED_SETTINGS:
        env[key] = settings[key]
    env["XCODE_XCCONFIG_FILE"] = str(XCCONFIG)
    env["CMAKE_POLICY_VERSION_MINIMUM"] = "3.5"
    env["BUILD_TIMING_LOG"] = str(timing_log)
    env["PATH"] = f"{config.RUSTUP_BIN}:{env.get('PATH', '/usr/bin:/bin')}"
    env["TMPDIR"] = str(scratch_dir())
    Path(env["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    return env


def scratch_dir() -> Path:
    return Path(config.CACHE_DIR) / "tmp" / f"frameworks-{os.getpid()}"


Status = Literal["current", "restore", "build"]


class Runner(Protocol):
    def prepare(self) -> None: ...
    def stamps(self) -> dict[str, str]: ...
    def rust(self) -> str: ...
    def is_current(self, unit: str, stamp: str) -> bool: ...
    def find(self, key: str) -> Entry | None: ...
    def restore(self, unit: str, entry: Entry, stamp: str) -> None: ...
    def configure(self) -> None: ...
    def headers_synced(self) -> bool: ...
    def sync_headers(self) -> None: ...
    def build_tlottie(self, stamp: str) -> None: ...
    def write_stamp(self, unit: str, stamp: str) -> None: ...
    def store(self, unit: str, key: str, stamp: str) -> None: ...
    def prune(self, keep: set[str]) -> None: ...
    def cache_size(self) -> int: ...


@dataclass(frozen=True)
class Summary:
    current: int
    restored: int
    built: int
    seconds: float
    cache_bytes: int


def plan(stamps: dict[str, str], is_current: Callable[[str, str], bool], find: Callable[[str], Entry | None],
         rust: str, use_cache: bool) -> dict[str, Status]:
    from .fwcache import cache_key, cacheable
    statuses: dict[str, Status] = {}
    for unit, stamp in stamps.items():
        if is_current(unit, stamp):
            statuses[unit] = "current"
        elif use_cache and cacheable(unit, rust) and find(cache_key(stamp, rust)) is not None:
            statuses[unit] = "restore"
        else:
            statuses[unit] = "build"
    return statuses


def run(root: Path, use_cache: bool, runner: Runner) -> Summary:
    from .fwcache import UNITS, cache_key, cacheable
    started = time.monotonic()
    runner.prepare()
    stamps = runner.stamps()
    rust = runner.rust()
    statuses = plan(stamps, runner.is_current, runner.find, rust, use_cache)
    for unit in UNITS:
        if statuses[unit] == "restore":
            entry = runner.find(cache_key(stamps[unit], rust))
            if entry is None:
                statuses[unit] = "build"
                continue
            try:
                runner.restore(unit, entry, stamps[unit])
            except (OSError, config.ConfigError, subprocess.CalledProcessError):
                statuses[unit] = "build"
                continue
            if not runner.is_current(unit, stamps[unit]):
                statuses[unit] = "build"
    configured = any(status == "build" for unit, status in statuses.items() if unit != "tlottie")
    if configured:
        runner.configure()
        stamps = runner.stamps()
        runner.write_stamp("tlottie", stamps["tlottie"])
    elif any(status != "current" for status in statuses.values()) or not runner.headers_synced():
        runner.sync_headers()
    if (statuses["tlottie"] == "build" and not configured) or not runner.is_current("tlottie", stamps["tlottie"]):
        runner.build_tlottie(stamps["tlottie"])
    keys = {unit: cache_key(stamp, rust) for unit, stamp in stamps.items()}
    if use_cache:
        for unit in UNITS:
            if cacheable(unit, rust) and runner.find(keys[unit]) is None and runner.is_current(unit, stamps[unit]):
                runner.store(unit, keys[unit], stamps[unit])
        runner.prune(set(keys.values()))
    counts = {status: sum(1 for s in statuses.values() if s == status) for status in ("current", "restore", "build")}
    return Summary(counts["current"], counts["restore"], counts["build"], time.monotonic() - started,
                   runner.cache_size() if use_cache else 0)


def outputs_present(paths: list[Path]) -> bool:
    return bool(paths) and all(p.is_file() and p.stat().st_size > 0 for p in paths)


class RealRunner:
    def __init__(self, root: Path, log: Path, timing_log: Path):
        from . import fwcache
        self.fwcache = fwcache
        self.root = Path(root)
        self.log = log
        self.timing_log = timing_log
        self.env = build_environment(timing_log)
        self.env.setdefault("FRAMEWORK_XCODE_VERSION", fwcache.xcode_version_line())
        self.outputs = fwcache.required_outputs_by_unit(self.root)
        self._rust: str | None = None

    def _run(self, args: list[str], what: str) -> None:
        with self.log.open("a") as handle:
            result = subprocess.run(args, cwd=self.root, env=self.env, stdout=handle, stderr=subprocess.STDOUT,
                                    check=False)
        if result.returncode != 0:
            raise config.ConfigError(f"{what} failed (exit {result.returncode}): see {self.log}")

    def prepare(self) -> None:
        for script in ("prepare-telegram-api.py", "prepare-flat-serialization.py"):
            self._run(["python3", str(self.root / "scripts" / script)], script)

    def stamps(self) -> dict[str, str]:
        return self.fwcache.local_stamps(self.root, self.env, rust=self.rust())

    def rust(self) -> str:
        if self._rust is None:
            self._rust = self.fwcache.pinned_rust(self.root)
        return self._rust

    def is_current(self, unit: str, stamp: str) -> bool:
        stamp_path = self.fwcache.stamp_file(self.root, unit)
        if not stamp_path.is_file() or stamp_path.read_text() != stamp:
            return False
        if not outputs_present(self.outputs[unit]):
            return False
        if unit == "wallet-engine":
            check = self.root / "scripts" / "check-wallet-engine-bindings.sh"
            return subprocess.run(["sh", str(check), str(self.root)], capture_output=True).returncode == 0
        return True

    def find(self, key: str) -> Entry | None:
        return self.fwcache.lookup(key)

    def restore(self, unit: str, entry: Entry, stamp: str) -> None:
        self.fwcache.restore(self.root, unit, entry, stamp)

    def configure(self) -> None:
        self._run(["sh", str(self.root / "scripts" / "configure_frameworks.sh")], "native libraries")

    def headers_synced(self) -> bool:
        return all(dest.is_dir() for _, dest in self.fwcache.header_pairs(self.root))

    def sync_headers(self) -> None:
        for source, dest in self.fwcache.header_pairs(self.root):
            self._run(["sh", str(self.root / "scripts" / "sync-headers.sh"), str(source), str(dest)], "header sync")

    def build_tlottie(self, stamp: str) -> None:
        self._run(["sh", str(self.root / "scripts" / "time-step.sh"), "tlottie", "sh",
                   str(self.root / "core-xprojects" / "tlottie" / "build.sh")], "tlottie")
        self.write_stamp("tlottie", stamp)

    def write_stamp(self, unit: str, stamp: str) -> None:
        if outputs_present(self.outputs[unit]):
            self.fwcache.stamp_file(self.root, unit).write_text(stamp)

    def store(self, unit: str, key: str, stamp: str) -> None:
        self.fwcache.store(self.root, unit, key, stamp)

    def prune(self, keep: set[str]) -> None:
        self.fwcache.prune(self.fwcache.max_bytes(), keep)

    def cache_size(self) -> int:
        return self.fwcache.cache_size()


def cache_enabled(argv: list[str]) -> bool:
    return "--no-cache" not in argv and os.environ.get("NANOGRAM_FRAMEWORK_CACHE", "1") != "0"


def gigabytes(size: int) -> str:
    return f"{size / 1024**3:.1f} GB"


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    unknown = [a for a in argv if a not in ("--verify-only", "--no-cache")]
    if unknown:
        print(f"error: unknown frameworks option: {' '.join(unknown)}", file=sys.stderr)
        return 2
    timing_log = config.BUILD_OUTPUT / "frameworks-timing.tsv"
    log = config.BUILD_OUTPUT / "frameworks.log"
    if "--verify-only" not in argv:
        use_cache = cache_enabled(argv)
        source = "shared cache" if use_cache else "no cache"
        print(f"==> Native libraries (arm64, {source}), log: {log.relative_to(config.ROOT)}", flush=True)
        timing_log.parent.mkdir(parents=True, exist_ok=True)
        timing_log.write_text("")
        log.write_text("")
        try:
            summary = run(config.ROOT, use_cache, RealRunner(config.ROOT, log, timing_log))
        except (config.ConfigError, subprocess.CalledProcessError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        finally:
            shutil.rmtree(scratch_dir(), ignore_errors=True)
        for line in timing_log.read_text().splitlines():
            print("   " + line.replace("\t", "  "))
        cache = (f"cache {gigabytes(summary.cache_bytes)} (cap {gigabytes(_cap())})" if use_cache
                 else "cache not used")
        print(f"==> native libraries: {summary.current} current, {summary.restored} restored, {summary.built} built "
              f"in {round(summary.seconds)}s; {cache}", flush=True)
    problems = verify_outputs()
    for problem in problems:
        print(f"frameworks: {problem}", file=sys.stderr)
    if not problems:
        print("frameworks: all outputs present, arm64 only")
    return 1 if problems else 0


def _cap() -> int:
    from .fwcache import max_bytes
    return max_bytes()


if __name__ == "__main__":
    raise SystemExit(main())
