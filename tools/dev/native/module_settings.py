#!/usr/bin/env python3
"""Per-module and per-platform optimisation settings, one table for both apps.

tools/dev/native/module-settings.json holds
  * "platform": the settings that apply to every module (Swift optimisation level, WMO, C ThinLTO, Rust LTO,
    dead-strip), each with the line in the real build files that proves it ("probes"), so the table cannot go
    stale silently;
  * "modules": every Swift module that BOTH apps build, with its Swift language mode on each side, generated from
    the iOS BUILD files (swift_library / swift6_library / strict_swift_library) and the Mac Package.swift files
    (tools-version and swiftLanguageModes);
  * "allowed": modules whose modes differ, each with a reason, and the count that must shrink to zero.

docs/module-build-settings.md is rendered from it. The same file and script live in both repos.

  module_settings.py --write [--ios PATH --mac PATH]   regenerate module-settings.json and the doc
  module_settings.py --check [--ios PATH --mac PATH]   fail when either differs from the build files
Both repo paths default to the repo this script is in and its sibling next to it.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_native_libs as probes  # noqa: E402

DATA = HERE / "module-settings.json"
RULES = {"swift_library": "5", "swift6_library": "6", "strict_swift_library": "6"}
RULE_RE = re.compile(r"\b(swift_library|swift6_library|strict_swift_library)\(\s*(.*?)\n\)", re.S)
NAME_RE = re.compile(r'\bname\s*=\s*"([^"]+)"')
MODULE_RE = re.compile(r'\bmodule_name\s*=\s*"([^"]+)"')
TARGET_RE = re.compile(r'\.target\(\s*name:\s*"([^"]+)"')

SETTINGS_REASONS = {
    "swift_opt": "Mac builds 12 cold feature modules -Osize in Release to keep the binary small (NANOGRAM_SWIFT_OPT_* in nanogram/Nanogram.xcconfig); iOS builds every module -O. Both are -Onone in Debug.",
    "rust_lto": "iOS links Rust with fat LTO (cross-crate); the Mac builds the Rust engines with the Cargo release profile (thin LTO). Same compiler (native-libs.json, rust). Kept platform-specific: fat LTO costs link time the Mac loop cannot afford.",
    "order_file": "The Mac Release link uses an order file (tools/dev/orderfile.py); iOS does not.",
}


def ios_modules(root: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for build in sorted(root.glob("submodules/**/BUILD")):
        text = build.read_text(errors="replace")
        for rule, body in RULE_RE.findall(text):
            name = NAME_RE.search(body)
            module = MODULE_RE.search(body)
            mode = RULES[rule]
            if '"-swift-version"' in body and re.search(r'"-swift-version",\s*"(\d)"', body):
                mode = re.search(r'"-swift-version",\s*"(\d)"', body).group(1)
            key = (module or name).group(1) if (module or name) else None
            if key:
                found.setdefault(key, mode)
    return found


def package_mode(text: str) -> str:
    v6 = bool(re.search(r"\.v6\b", text))
    v5 = bool(re.search(r"\.v5\b", text))
    if v6 and v5:
        return "mixed"
    if v6:
        return "6"
    if v5:
        return "5"
    tools = re.search(r"swift-tools-version:?\s*(\d+)", text)
    return "6" if tools and int(tools.group(1)) >= 6 else "5"


def mac_modules(root: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    manifests = sorted(root.glob("packages/*/Package.swift")) + sorted(root.glob("submodules/telegram-ios/**/Package.swift"))
    for manifest in manifests:
        text = manifest.read_text(errors="replace")
        mode = package_mode(text)
        for target in TARGET_RE.findall(text):
            found.setdefault(target, mode)
    return found


def load_platform_probes(data: dict, ios: Path, mac: Path) -> list[str]:
    problems = []
    for key, entry in data["platform"].items():
        for side, root in (("ios", ios), ("mac", mac)):
            for probe in entry.get("probes", {}).get(side, []):
                if probes.run_probe(root, dict(probe, what="x", kind="regex")) is None:
                    problems.append(f"platform.{key} ({side}): {probe['id']} not found in {probe['file']}")
    return problems


def build(ios: Path, mac: Path, previous: dict) -> dict:
    i, m = ios_modules(ios), mac_modules(mac)
    both = sorted(set(i) & set(m))
    modules = {name: {"ios": i[name], "mac": m[name]} for name in both}
    def reason(row: dict) -> str:
        lagging = "Mac" if row["ios"] == "6" else "iOS"
        return (f"{lagging} still builds it in the lower Swift language mode (the Mac core's manifests are tools-version 5.5 from upstream); "
                "raised module by module with its tests (shared-codebase plan 3.2), never in bulk")
    allowed = {name: previous.get("allowed", {}).get(name) or reason(row)
               for name, row in modules.items() if row["ios"] != row["mac"]}
    out = dict(previous)
    out["modules"] = modules
    out["allowed"] = allowed
    out["counts"] = {"ios_swift_modules": len(i), "ios_swift6": sum(1 for v in i.values() if v == "6"),
                     "mac_swift_targets": len(m), "mac_swift6": sum(1 for v in m.values() if v == "6"),
                     "built_by_both": len(both), "modes_differ": len(allowed)}
    return out


def render(data: dict) -> str:
    c = data["counts"]
    lines = ["# Module build settings", "",
             "Generated from `tools/dev/native/module-settings.json` by `tools/dev/native/module_settings.py --write`. "
             "The same file and doc live in the iOS and the Mac repo. Do not edit by hand.", "",
             "## Platform-wide settings", "",
             "| Setting | iOS (Bazel) | Mac (Xcode) | Kept equal? |", "|---|---|---|---|"]
    for entry in data["platform"].values():
        lines.append(f"| {entry['label']} | {entry['ios']} | {entry['mac']} | {entry['equal']} |")
    lines += ["", "Why the platform differences stay:", ""]
    lines += [f"- {text}" for text in SETTINGS_REASONS.values()]
    lines += ["", "## Swift language mode per module", "",
              f"iOS builds {c['ios_swift_modules']} Swift modules ({c['ios_swift6']} in Swift 6 mode); the Mac builds "
              f"{c['mac_swift_targets']} package targets ({c['mac_swift6']} in Swift 6 mode). {c['built_by_both']} modules are built by "
              f"both apps; {c['modes_differ']} of them differ in language mode.", ""]
    if data["modules"]:
        lines += ["| Module | iOS | Mac | Status |", "|---|---|---|---|"]
        for name, row in data["modules"].items():
            status = "equal" if row["ios"] == row["mac"] else "differs (allow-listed)"
            lines.append(f"| {name} | Swift {row['ios']} | Swift {row['mac']} | {status} |")
    lines += ["", "Rule: a module's mode is raised on the side that lags, with its tests, one module at a time. "
              "A new difference fails `module_settings.py --check` until it is fixed or listed under `allowed` with a reason.", ""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ios", type=Path)
    parser.add_argument("--mac", type=Path)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    here = HERE.parents[2]
    ios = args.ios or (here if (here / "MODULE.bazel").is_file() else here.parent / "nanogram-ios")
    mac = args.mac or (here if (here / "core-xprojects").is_dir() else here.parent / "nanogram-macos")
    previous = json.loads(DATA.read_text())
    problems = load_platform_probes(previous, ios, mac)
    fresh = build(ios, mac, previous)
    if args.write:
        DATA.write_text(json.dumps(fresh, indent=1) + "\n")
        doc = here / "docs/module-build-settings.md"
        doc.parent.mkdir(exist_ok=True)
        doc.write_text(render(fresh))
        print(f"wrote {DATA.name} and {doc.relative_to(here)}: {fresh['counts']}")
    else:
        if fresh["modules"] != previous.get("modules") or fresh["allowed"] != previous.get("allowed"):
            changed = sorted(set(fresh["modules"]) ^ set(previous.get("modules", {})) |
                             {k for k in fresh["modules"] if fresh["modules"][k] != previous.get("modules", {}).get(k)})
            problems.append("module table is stale for: " + ", ".join(changed[:10]) + " (run module_settings.py --write in both repos)")
        doc = here / "docs/module-build-settings.md"
        if not doc.is_file() or doc.read_text() != render(previous):
            problems.append("docs/module-build-settings.md is not the rendering of module-settings.json")
        for name, row in previous.get("modules", {}).items():
            if row["ios"] != row["mac"] and name not in previous.get("allowed", {}):
                problems.append(f"{name}: Swift {row['ios']} on iOS vs {row['mac']} on the Mac and not allow-listed")
    for line in problems:
        print("module-settings drift:", line)
    if not problems and not args.write:
        print(f"module-settings ok: {len(previous['modules'])} shared modules, {len(previous['allowed'])} allow-listed mode differences")
    return 1 if problems and not args.write else 0


if __name__ == "__main__":
    sys.exit(main())
