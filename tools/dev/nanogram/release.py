"""Release builds: tg testflight (mas edition) and tg release-direct (direct edition, local only).

Both archive the Release scheme with our edition xcconfig, sign with Xcode's automatic signing through the
App Store Connect API key (~/.config/telegram-ios/asc: asc.json {"key_id", "issuer_id"} + AuthKey_<id>.p8,
a team key with the Admin role), and export. mas: a signed .pkg, uploaded with altool (xcodebuild's own upload
refuses the API key, as on iOS). direct: a Developer ID app, notarized, stapled, in a .dmg with a signed
Sparkle appcast and the matching source archive. Nothing is published from here.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from nanogram import branding, buildcheck, config, editions
from nanogram import enhanced_security as enhanced_security_module
from nanogram import dmg as disk_image

TEAM = "YGTMYL879P"
APP_STORE_APP_ID = "6829268176"
METHODS = {"mas": "app-store-connect", "direct": "developer-id"}
DISTRIBUTION_AUTHORITIES = {"mas": "Apple Distribution:", "direct": "Developer ID Application:"}
MACHO_MAGICS = {bytes.fromhex(magic) for magic in ("feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe",
                                                    "bebafeca")}
NESTED_CODE_DIRS = ("Frameworks", "PlugIns", "XPCServices", "Helpers", "Library/LoginItems")
APPLE_FONT_PREFIXES = ("SF", ".SF", "NewYork")
FONT_SUFFIXES = (".otf", ".ttf", ".ttc")
WORKSPACE = "Telegram-Mac.xcworkspace"
PBXPROJ = config.ROOT / "Telegram.xcodeproj" / "project.pbxproj"
# Written by the launch order file generator (M31, tools/dev/orderfile.py). The Release
# link of the app uses it when it exists; a symbol the linker cannot find is ignored.
ORDER_FILE = config.ROOT / "Telegram-Mac" / "OrderFiles" / "Telegram.order"
# Profile-only entitlements (Maps) cannot be in a profile-less local signature, and an -xcconfig setting cannot be
# overridden on the command line, so the archive signs with the development set and the archived app is re-signed
# with the distribution set before export (which provisions and signs it for the App Store).
DISTRIBUTION_ENTITLEMENTS = {"mas": config.ROOT / "nanogram" / "entitlements" / "Nanogram-MAS.entitlements"}
ENHANCED_SECURITY_ENV = "NANOGRAM_ENHANCED_SECURITY"
BUILD_NUMBER_RE = re.compile(r"^\d+(\.\d+){0,2}$")
ASC_API = "https://api.appstoreconnect.apple.com"
EXPORT_TIMEOUT = 600

__all__ = ["AscKey", "asc_key", "build_number", "marketing_version", "conditions", "release_settings", "distribution_entitlements", "enhanced_security_requested",
           "archive_command", "archive", "export_options", "export", "set_build_number", "ensure_mac_platform",
           "upload_mas", "unsign_resource_bundles", "check_distribution_signing", "check_exported_app", "enhanced_security_problems", "enhanced_security_unbacked_problems", "testflight", "notarize", "make_dmg", "appcast_entry", "appcast", "source_archive",
           "release_direct", "build_info_text", "git_state", "build_warnings", "has_unreleased_entries", "dwarf_uuids",
           "archive_dsyms", "record_build"]


class ReleaseError(config.ConfigError):
    pass


@dataclass(frozen=True)
class AscKey:
    path: Path
    key_id: str
    issuer: str

    def auth_flags(self) -> list[str]:
        return ["-authenticationKeyPath", str(self.path), "-authenticationKeyID", self.key_id,
                "-authenticationKeyIssuerID", self.issuer]


def asc_dir() -> Path:
    return config.asc_dir()


def asc_key(directory: Path | None = None) -> AscKey:
    directory = Path(directory or asc_dir())
    settings = directory / "asc.json"
    if not settings.is_file():
        raise ReleaseError(f"no App Store Connect API key: put asc.json ({{\"key_id\": ..., \"issuer_id\": ...}}) "
                           f"and AuthKey_<key_id>.p8 (team key, Admin role) in {directory}")
    try:
        data = json.loads(settings.read_text())
        key_id, issuer = str(data["key_id"]), str(data["issuer_id"])
    except (ValueError, KeyError, TypeError):
        raise ReleaseError(f"{settings} must hold {{\"key_id\": ..., \"issuer_id\": ...}}") from None
    path = directory / f"AuthKey_{key_id}.p8"
    if not path.is_file():
        raise ReleaseError(f"{path} is missing: download the key AuthKey_{key_id}.p8 from App Store Connect > "
                           "Users and Access > Integrations")
    return AscKey(path, key_id, issuer)


def build_number(env=None, now: datetime.datetime | None = None) -> str:
    env = os.environ if env is None else env
    if "TG_BUILD_NUMBER" in env:
        value = env["TG_BUILD_NUMBER"]
        if not BUILD_NUMBER_RE.match(value):
            raise ReleaseError(f"TG_BUILD_NUMBER={value!r} is not a build number (digits, at most 3 dot parts)")
        return value
    return (now or datetime.datetime.now()).strftime("%Y%m%d%H%M")


def marketing_version(pbxproj: Path = PBXPROJ) -> str:
    versions = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", Path(pbxproj).read_text()))
    if len(versions) != 1:
        raise ReleaseError(f"expected one MARKETING_VERSION in {pbxproj}, found {sorted(versions) or 'none'}")
    return versions.pop()


def conditions(edition: str) -> str:
    value = "$(inherited) NANOGRAM STABLE"
    return value + " NANOGRAM_MAS" if edition == "mas" else value


def enhanced_security_requested(environ: Mapping[str, str] | None = None) -> bool:
    environ = os.environ if environ is None else environ
    return environ.get(ENHANCED_SECURITY_ENV, "").strip().lower() in ("1", "yes", "true")


def distribution_entitlements(edition: str, enhanced_security: bool = False) -> Path | None:
    path = DISTRIBUTION_ENTITLEMENTS.get(edition)
    if path is not None and enhanced_security:
        return enhanced_security_module.variant_path(path)
    return path


def release_settings(order_file: Path = ORDER_FILE, environ: Mapping[str, str] | None = None) -> list[str]:
    """Command-line settings of every Release build: they reach every target, SwiftPM packages included.
    M17: no runtime exclusivity checks in Release (the app target already has them off); Debug and tests keep them."""
    settings = ["SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off"]
    if Path(order_file).is_file():
        settings.append(f"NANOGRAM_ORDER_FILE={order_file}")
    if enhanced_security_requested(environ):
        settings.append("NANOGRAM_ENHANCED_SECURITY_REQUEST=YES")
    return settings


def _xcconfig(edition: str) -> Path:
    if edition not in METHODS:
        raise ReleaseError(f"unknown edition {edition!r} (mas or direct)")
    return config.ROOT / "nanogram" / "editions" / f"{edition}.xcconfig"


def archive_command(edition: str, build: str, archive_path: Path, key: AscKey,
                    derived: Path = config.DERIVED_DATA) -> list[str]:
    command = ["xcodebuild", "archive",
               "-workspace", WORKSPACE, "-scheme", "Release", "-configuration", "Release",
               "-destination", "generic/platform=macOS", "-archivePath", str(archive_path),
               "-derivedDataPath", str(derived), "-xcconfig", str(_xcconfig(edition)),
               f"SWIFT_ACTIVE_COMPILATION_CONDITIONS={conditions(edition)}",
               f"CURRENT_PROJECT_VERSION={build}",
               *release_settings(),
               "COMPILER_INDEX_STORE_ENABLE=NO"]
    command += ["-allowProvisioningUpdates", *key.auth_flags(), "-showBuildTimingSummary"]
    return command


def _run_logged(command: list[str], log: Path, what: str, timeout: int | None = None) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    with log.open("w") as handle:
        try:
            status = subprocess.run(command, cwd=config.ROOT, stdout=handle, stderr=subprocess.STDOUT,
                                    timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            raise ReleaseError(f"{what} did not finish in {timeout}s (seen once: xcodebuild -exportArchive waiting "
                               f"on App Store Connect forever); run it again; log: {log}") from None
    elapsed = int(time.monotonic() - start)
    if status != 0:
        errors = sorted({line.strip() for line in log.read_text(errors="replace").splitlines()
                         if re.search(r"(error|fatal error):", line)})
        for line in errors[:30]:
            print(line, file=sys.stderr)
        raise ReleaseError(f"{what} failed after {elapsed}s (exit {status}); full log: {log}")
    print(f"==> {what} done in {elapsed}s (log: {log})", flush=True)


def archived_app(archive_path: Path) -> Path:
    apps = sorted((Path(archive_path) / "Products" / "Applications").glob("*.app"))
    if len(apps) != 1:
        raise ReleaseError(f"expected one app in {archive_path}/Products/Applications, found {len(apps)}")
    return apps[0]


def check_archive(archive_path: Path, log: Path, edition: str) -> None:
    """buildcheck (release flags on every compile, arm64, macOS 15.0) and the edition checks on the archived app."""
    app = archived_app(archive_path)
    problems = buildcheck.check_log(log.read_text(errors="replace"), release=True)
    problems += buildcheck.check_binary(app)
    problems += editions.check_edition(editions.inspect_app(app), edition)
    problems += branding.check_names(app)
    problems += [f"Telegram endpoint in the bundle: {hit}" for hit in branding.find_forbidden(app)]
    if problems:
        for problem in problems:
            print(f"release: {problem}", file=sys.stderr)
        raise ReleaseError(f"the archived {edition} app failed its checks ({len(problems)} problems, see above)")
    print(f"==> buildcheck and {edition} edition checks ok on {app.name}", flush=True)


def archive(edition: str, build: str, out_dir: Path, key: AscKey) -> Path:
    archive_path = Path(out_dir) / "Nanogram.xcarchive"
    if archive_path.exists():
        shutil.rmtree(archive_path)
    for module in ("localfixes", "credentials"):
        subprocess.run([sys.executable, "-m", f"nanogram.{module}"], cwd=config.ROOT, check=True)
    editions.refresh_build_descriptions(_xcconfig(edition), edition, config.DERIVED_DATA)
    log = Path(out_dir) / "archive.log"
    print(f"==> Archiving Release ({edition} edition, build {build}), log: {log}", flush=True)
    _run_logged(archive_command(edition, build, archive_path, key), log, "archive")
    unsigned = unsign_resource_bundles(archived_app(archive_path))
    if unsigned:
        print(f"==> Removed the build signature of {len(unsigned)} resource bundles", flush=True)
    set_build_number(archive_path, build, distribution_entitlements(edition, enhanced_security_requested()))
    check_archive(archive_path, log, edition)
    return archive_path


def _plist_format(data: bytes):
    return plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML


def _set_plist_value(path: Path, keys: tuple[str, ...], value: str) -> None:
    data = path.read_bytes()
    root = plistlib.loads(data)
    node = root
    for key in keys[:-1]:
        node = node[key]
    node[keys[-1]] = value
    path.write_bytes(plistlib.dumps(root, fmt=_plist_format(data)))


def _signing_authority(bundle: Path) -> str:
    info = subprocess.run(["codesign", "-dvv", str(bundle)], capture_output=True, text=True).stderr
    match = re.search(r"^Authority=(.+)$", info, re.MULTILINE)
    if not match:
        raise ReleaseError(f"{bundle} is not signed with an identity")
    return match.group(1)


def _authority(path: Path) -> str | None:
    info = subprocess.run(["codesign", "-dvv", str(path)], capture_output=True, text=True).stderr
    match = re.search(r"^Authority=(.+)$", info, re.MULTILINE)
    return match.group(1) if match else None


def _is_macho(path: Path) -> bool:
    try:
        with Path(path).open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def _has_signature(bundle: Path) -> bool:
    return (Path(bundle) / "Contents" / "_CodeSignature").is_dir() or (Path(bundle) / "_CodeSignature").is_dir()


def resource_bundles(app: Path) -> list[Path]:
    return sorted((Path(app) / "Contents" / "Resources").glob("*.bundle"))


def _macho_files(bundle: Path) -> list[Path]:
    return sorted(path for path in Path(bundle).rglob("*")
                  if path.is_file() and not path.is_symlink() and _is_macho(path))


def unsign_resource_bundles(app: Path) -> list[Path]:
    unsigned = []
    for bundle in resource_bundles(app):
        if _macho_files(bundle):
            continue
        for signature in (bundle / "Contents" / "_CodeSignature", bundle / "_CodeSignature"):
            if signature.is_dir():
                shutil.rmtree(signature)
                unsigned.append(bundle)
    return unsigned


def nested_code(app: Path) -> list[Path]:
    app = Path(app)
    contents = app / "Contents"
    code = [app]
    for directory in NESTED_CODE_DIRS:
        code += sorted(path for path in (contents / directory).glob("*") if not path.is_symlink())
    for framework in sorted((contents / "Frameworks").glob("*.framework")):
        for version in sorted((framework / "Versions").glob("[!C]*")):
            code += sorted(version.glob("XPCServices/*.xpc")) + sorted(version.glob("Updater.app"))
            code += [path for path in sorted(version.glob("Autoupdate")) if _is_macho(path)]
    for bundle in resource_bundles(app):
        if _has_signature(bundle):
            code.append(bundle)
        code += _macho_files(bundle)
    return code


def check_distribution_signing(app: Path, edition: str) -> list[str]:
    prefix, team = DISTRIBUTION_AUTHORITIES[edition], f"({TEAM})"
    problems = []
    for item in nested_code(app):
        authority = _authority(item)
        if not authority or not authority.startswith(prefix) or not authority.endswith(team):
            where = item.relative_to(Path(app).parent)
            problems.append(f"{where} is signed by {authority or 'no identity'}, expected {prefix} ... {team}")
    return problems


def apple_fonts(app: Path) -> list[str]:
    return sorted(str(path.relative_to(Path(app).parent)) for path in Path(app).rglob("*")
                  if path.suffix.lower() in FONT_SUFFIXES and path.name.startswith(APPLE_FONT_PREFIXES))


def signed_entitlements(bundle: Path) -> dict:
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)], capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        return plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError):
        return {}


def embedded_profile(app: Path) -> dict | None:
    path = Path(app) / "Contents" / "embedded.provisionprofile"
    if not path.is_file():
        return None
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    if result.returncode != 0:
        return {}
    try:
        return plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError):
        return {}


def embedded_profile_entitlements(app: Path) -> dict | None:
    profile = embedded_profile(app)
    return None if profile is None else profile.get("Entitlements", {})


def embedded_profile_expiry(app: Path) -> datetime.datetime | None:
    expiry = (embedded_profile(app) or {}).get("ExpirationDate")
    return expiry if isinstance(expiry, datetime.datetime) else None


def enhanced_security_problems(app: Path, entitlements_of=signed_entitlements,
                               profile_of=embedded_profile_entitlements, expiry_of=embedded_profile_expiry,
                               now: datetime.datetime | None = None) -> list[str]:
    name = Path(app).name
    grant = enhanced_security_module.PREFIX
    signed = entitlements_of(Path(app))
    problems = [f"{name} is signed without {key} = {value!r} (Enhanced Security was requested)"
                for key, value in enhanced_security_module.SOFT_MODE_KEYS.items() if signed.get(key) != value]
    profile = profile_of(Path(app))
    if profile is None:
        problems.append(f"{name} embeds no provisioning profile (Contents/embedded.provisionprofile) that could "
                        f"grant {grant}")
    elif profile.get(grant) is not True:
        problems.append(f"the provisioning profile of {name} does not grant {grant}")
    else:
        expiry = expiry_of(Path(app))
        now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        if expiry is not None and expiry.replace(tzinfo=None) <= now:
            problems.append(f"the provisioning profile of {name} expired on {expiry:%Y-%m-%d}")
    return problems


def enhanced_security_unbacked_problems(app: Path, entitlements_of=signed_entitlements,
                                        profile_of=embedded_profile_entitlements) -> list[str]:
    problems = []
    grant = enhanced_security_module.PREFIX
    for item in nested_code(app)[1:]:
        if not item.is_dir():
            continue
        carried = sorted(key for key in entitlements_of(item) if key.startswith(grant))
        if not carried:
            continue
        where = item.relative_to(Path(app).parent)
        profile = profile_of(item)
        if profile is None:
            problems.append(f"{where} is signed with {', '.join(carried)} but embeds no provisioning profile; "
                            "a restricted entitlement without a profile keeps the bundle from launching")
        elif profile.get(grant) is not True:
            problems.append(f"{where} is signed with {', '.join(carried)} but its provisioning profile does not "
                            f"grant {grant}; a restricted entitlement the profile does not grant keeps the bundle "
                            "from launching")
    return problems


ENHANCED_SECURITY_HINT = ("Enhanced Security needs the capability on the macOS App ID in the developer portal and a "
                          "Developer ID profile that grants it; fix that, or release without it by unsetting "
                          f"{ENHANCED_SECURITY_ENV}")


def check_exported_app(app: Path, edition: str, enhanced_security: bool | None = None) -> None:
    if enhanced_security is None:
        enhanced_security = enhanced_security_requested()
    problems = check_distribution_signing(app, edition)
    problems += [f"Apple system font in the bundle (ITMS-91182): {font}" for font in apple_fonts(app)]
    enhanced_security_failed = False
    if enhanced_security:
        found = enhanced_security_problems(app) + enhanced_security_unbacked_problems(app)
        enhanced_security_failed = bool(found)
        problems += found
    if problems:
        for problem in problems:
            print(f"release: {problem}", file=sys.stderr)
        if enhanced_security_failed:
            print(f"release: {ENHANCED_SECURITY_HINT}", file=sys.stderr)
        raise ReleaseError(f"the exported {edition} app failed its signing checks ({len(problems)} problems, "
                           "see above)")
    print(f"==> every nested code item of {Path(app).name} is signed for {edition} distribution", flush=True)


def check_exported_pkg(pkg: Path, edition: str) -> None:
    expanded = Path(pkg).parent / f".{Path(pkg).stem}.expanded"
    if expanded.exists():
        shutil.rmtree(expanded)
    try:
        result = subprocess.run(["pkgutil", "--expand-full", str(pkg), str(expanded)], capture_output=True,
                                text=True)
        if result.returncode != 0:
            raise ReleaseError(f"pkgutil cannot expand {pkg}: {result.stderr.strip()}")
        check_exported_app(_single(expanded, "*/Payload/*.app"), edition)
    finally:
        shutil.rmtree(expanded, ignore_errors=True)


def _archive_identity(bundle: Path) -> str:
    info = subprocess.run(["codesign", "-dvv", str(bundle)], capture_output=True, text=True).stderr
    return "-" if "Signature=adhoc" in info else _signing_authority(bundle)


def _resign(bundle: Path, entitlements: Path | None = None) -> None:
    keep = "identifier,requirements,flags,runtime" + ("" if entitlements else ",entitlements")
    command = ["codesign", "--force", "--sign", _archive_identity(bundle), f"--preserve-metadata={keep}"]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    result = subprocess.run(command + [str(bundle)], capture_output=True, text=True)
    if result.returncode != 0:
        raise ReleaseError(f"cannot re-sign {bundle.name}: {result.stderr.strip()}")


def set_build_number(archive_path: Path, build: str, app_entitlements: Path | None = None) -> None:
    """CFBundleVersion of the archived app and its extensions. Upstream's Info.plists carry a literal build number
    (bumped by hand for each upstream release), so it is stamped here instead of editing them. The bundles are
    re-signed with the identity they had (the app with `app_entitlements` when given); export signs them for
    distribution."""
    app = archived_app(archive_path)
    nested = sorted((app / "Contents" / "PlugIns").glob("*.appex")) + sorted((app / "Contents" / "XPCServices").glob("*.xpc"))
    for bundle in nested + [app]:
        _set_plist_value(bundle / "Contents" / "Info.plist", ("CFBundleVersion",), build)
        _resign(bundle, app_entitlements if bundle == app else None)
    _set_plist_value(Path(archive_path) / "Info.plist", ("ApplicationProperties", "CFBundleVersion"), build)


def build_info_text(build: str, commit: str, branch: str, dirty: bool, pushed: bool) -> str:
    return (f"build {build}\ncommit {commit}\nbranch {branch}\n"
            f"dirty {'yes' if dirty else 'no'}\npushed {'yes' if pushed else 'no'}\n")


def git_state(root: Path = config.ROOT) -> tuple[str, str, bool, bool]:
    def git_output(*args: str) -> str | None:
        result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    commit = git_output("rev-parse", "HEAD") or "unknown"
    branch = git_output("rev-parse", "--abbrev-ref", "HEAD") or "unknown"
    dirty = bool(git_output("status", "--porcelain", "--untracked-files=no"))
    pushed = bool(git_output("branch", "-r", "--contains", commit)) if commit != "unknown" else False
    return commit, branch, dirty, pushed


def has_unreleased_entries(changelog: Path) -> bool:
    try:
        lines = Path(changelog).read_text().splitlines()
    except OSError:
        return False
    inside = False
    for line in lines:
        if line.startswith("## Unreleased"):
            inside = True
        elif line.startswith("## "):
            inside = False
        elif inside and line.strip():
            return True
    return False


def build_warnings(build: str, commit: str, dirty: bool, pushed: bool, unreleased: bool) -> list[str]:
    warnings = []
    if dirty:
        warnings.append(f"the working tree has uncommitted changes: build {build} is not exactly commit {commit[:8]}")
    if not pushed:
        warnings.append(f"commit {commit[:8]} is not on any remote branch: the changelog for the next build "
                        "cannot start from it")
    if unreleased:
        warnings.append(f"CHANGELOG.md still has Unreleased entries: add this build's entry (build {build}, "
                        f"commit {commit[:8]})")
    return warnings


def dwarf_uuids(path: Path) -> list[str]:
    result = subprocess.run(["dwarfdump", "--uuid", str(path)], capture_output=True, text=True)
    return re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(", result.stdout) if result.returncode == 0 else []


def archive_dsyms(archive_path: Path, dest_root: Path, edition: str, build: str, uuids_of=dwarf_uuids) -> Path | None:
    """Zips the archive's dSYMs into <dest_root>/<edition>/<build>/, outside the xcarchive and every cache, with
    uuids.txt. The folder is emptied first, so a rebuilt number holds this build's alone. None when the archive has
    no dSYM for the app; an app dSYM whose UUIDs are not the app's refuses the release."""
    dsyms = sorted((Path(archive_path) / "dSYMs").glob("*.dSYM"))
    app = archived_app(archive_path)
    app_dsym = next((item for item in dsyms if item.name == f"{app.name}.dSYM"), None)
    if app_dsym is None:
        return None
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    app_uuids = set(uuids_of(app / "Contents" / "MacOS" / info.get("CFBundleExecutable", app.stem)))
    if not app_uuids or app_uuids != set(uuids_of(app_dsym)):
        raise ReleaseError(f"{app_dsym.name} in the archive does not match the {app.name} binary (UUIDs "
                           f"{sorted(app_uuids)} vs {sorted(uuids_of(app_dsym))}): its traces would not symbolicate")
    dest = Path(dest_root) / edition / build
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    lines = []
    for dsym in dsyms:
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(dsym), str(dest / f"{dsym.name}.zip")], check=True)
        lines += [f"{dsym.name} {uuid}" for uuid in uuids_of(dsym)]
    (dest / "uuids.txt").write_text("\n".join(lines) + "\n")
    return dest


def record_build(archive_path: Path, out_dir: Path, edition: str, build: str, dsym_root: Path | None = None,
                 root: Path = config.ROOT, uuids_of=dwarf_uuids, say=print) -> None:
    """What the next changelog needs (git log <previous build's commit>..<this one>) and what a crash report needs
    (the dSYMs): BUILD-INFO.txt next to the artifacts and next to the dSYMs. Warns, never blocks."""
    commit, branch, dirty, pushed = git_state(root)
    text = build_info_text(build, commit, branch, dirty, pushed)
    (Path(out_dir) / "BUILD-INFO.txt").write_text(text)
    for warning in build_warnings(build, commit, dirty, pushed, has_unreleased_entries(Path(root) / "CHANGELOG.md")):
        say(f"warning: {warning}")
    dest = archive_dsyms(archive_path, dsym_root or config.dsym_dir(), edition, build, uuids_of)
    if dest is None:
        say(f"warning: the archive holds no dSYM for the app: traces of build {build} will not symbolicate")
        return
    (dest / "BUILD-INFO.txt").write_text(text)
    say(f"==> dSYMs and BUILD-INFO of build {build} kept in {dest}")


def export_options(method: str, upload: bool) -> dict:
    if method not in METHODS.values():
        raise ValueError(f"unknown export method {method!r}")
    if upload and method != "app-store-connect":
        raise ValueError("only app-store-connect exports can upload")
    options = {"method": method, "destination": "upload" if upload else "export", "teamID": TEAM,
               "signingStyle": "automatic"}
    if method == "app-store-connect":
        options.update(uploadSymbols=True, manageAppVersionAndBuildNumber=False)
    return options


def export(archive_path: Path, edition: str, out_dir: Path, key: AscKey) -> Path:
    out_dir = Path(out_dir)
    options = out_dir / f"ExportOptions-{edition}.plist"
    options.write_bytes(plistlib.dumps(export_options(METHODS[edition], upload=False)))
    export_path = out_dir / "export"
    if export_path.exists():
        shutil.rmtree(export_path)
    command = ["xcodebuild", "-exportArchive", "-archivePath", str(archive_path), "-exportOptionsPlist", str(options),
               "-exportPath", str(export_path), "-allowProvisioningUpdates", *key.auth_flags()]
    print(f"==> Exporting for {METHODS[edition]}", flush=True)
    _run_logged(command, out_dir / "export.log", "export", timeout=EXPORT_TIMEOUT)
    return export_path


def _jwt(key: AscKey) -> str:
    def b64(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
    now = int(time.time())
    signing_input = (b64(json.dumps({"alg": "ES256", "kid": key.key_id, "typ": "JWT"}).encode()) + "." +
                     b64(json.dumps({"iss": key.issuer, "iat": now, "exp": now + 600,
                                     "aud": "appstoreconnect-v1"}).encode()))
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key.path)], input=signing_input.encode(),
                         capture_output=True, check=True).stdout
    offset = 4 if der[1] & 0x80 else 2

    def integer(at: int) -> tuple[bytes, int]:
        length = der[at + 1]
        return der[at + 2:at + 2 + length].lstrip(b"\0").rjust(32, b"\0"), at + 2 + length
    r, offset = integer(offset)
    s, _ = integer(offset)
    return signing_input + "." + b64(r + s)


def asc_get(path: str, key: AscKey) -> dict:
    request = urllib.request.Request(ASC_API + path, headers={"Authorization": "Bearer " + _jwt(key)})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise ReleaseError(f"App Store Connect API {path.split('?')[0]}: HTTP {error.code}") from None
    except urllib.error.URLError as error:
        raise ReleaseError(f"App Store Connect API unreachable: {error.reason}") from None


def ensure_mac_platform(key: AscKey) -> None:
    """The App Store Connect app must have the macOS platform before a Mac build can be uploaded. Read-only: adding
    the platform is the owner's click."""
    versions = asc_get(f"/v1/apps/{APP_STORE_APP_ID}/appStoreVersions?fields%5BappStoreVersions%5D=platform"
                       "&limit=200", key)
    platforms = {item.get("attributes", {}).get("platform") for item in versions.get("data", [])}
    if "MAC_OS" not in platforms:
        raise ReleaseError(f"the App Store Connect app {APP_STORE_APP_ID} has no macOS platform: in App Store "
                           "Connect > Apps > Nanogram, click + next to the iOS App heading in the sidebar, choose "
                           "macOS, then run tg testflight again")


def upload_mas(pkg: Path, key: AscKey) -> None:
    env = dict(os.environ, API_PRIVATE_KEYS_DIR=str(key.path.parent))
    result = subprocess.run(["xcrun", "altool", "--upload-app", "-t", "macos", "-f", str(pkg),
                             "--apiKey", key.key_id, "--apiIssuer", key.issuer], env=env)
    if result.returncode != 0:
        raise ReleaseError(f"altool could not upload {pkg} (exit {result.returncode})")


def _single(directory: Path, pattern: str) -> Path:
    found = sorted(Path(directory).glob(pattern))
    if len(found) != 1:
        raise ReleaseError(f"expected one {pattern} in {directory}, found {len(found)}")
    return found[0]


def verify_pkg(pkg: Path) -> str:
    result = subprocess.run(["pkgutil", "--check-signature", str(pkg)], capture_output=True, text=True)
    if result.returncode != 0 or "signed" not in result.stdout.lower():
        raise ReleaseError(f"{pkg} is not signed: {result.stdout.strip() or result.stderr.strip()}")
    return result.stdout


def testflight(export_only: bool = False) -> Path:
    key = asc_key()
    build, version = build_number(), marketing_version()
    if not export_only:
        ensure_mac_platform(key)
    out_dir = config.BUILD_OUTPUT / "testflight" / build
    out_dir.mkdir(parents=True, exist_ok=True)
    archive_path = archive("mas", build, out_dir, key)
    record_build(archive_path, out_dir, "mas", build)
    pkg = _single(export(archive_path, "mas", out_dir, key), "*.pkg")
    print(verify_pkg(pkg), flush=True)
    check_exported_pkg(pkg, "mas")
    if export_only:
        print(f"==> Signed for the App Store, not uploaded: {pkg} (Nanogram {version} ({build}))")
        return pkg
    print(f"==> Uploading Nanogram {version} ({build}) with API key {key.key_id}", flush=True)
    upload_mas(pkg, key)
    (out_dir / ".released").write_text(f"uploaded to TestFlight: Nanogram {version} ({build})\n")
    print("==> Uploaded. It appears in App Store Connect > TestFlight after Apple processes it (10-30 min).")
    return pkg


RELEASES_REPO = "https://github.com/klaipher/nanogram-releases"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_MACOS = buildcheck.MIN_OS


def tracked_changes(root: Path = config.ROOT) -> list[str]:
    """Tracked files (and submodules) that differ from HEAD: the source archive would not match the binary."""
    out = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=root, capture_output=True,
                         text=True, check=True).stdout
    return [line[3:] for line in out.splitlines() if line.strip()]


def _submodule_paths(root: Path) -> list[str]:
    out = subprocess.run(["git", "submodule", "foreach", "--quiet", "--recursive", "echo \"$displaypath\""],
                         cwd=root, capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


def source_archive(out: Path, prefix: str, root: Path = config.ROOT) -> Path:
    """The committed source of the superproject and every submodule (recursive) in one tar.gz (GPL: the source
    matching the binary). Untracked and ignored files, such as the generated API credentials, are not in it."""
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    parts_dir = out.parent / f".{out.name}.parts"
    if parts_dir.exists():
        shutil.rmtree(parts_dir)
    parts_dir.mkdir()
    try:
        parts = []
        for index, path in enumerate([""] + _submodule_paths(root)):
            part = parts_dir / f"{index}.tar"
            subprocess.run(["git", "archive", "--format=tar", f"--prefix={prefix}/{path + '/' if path else ''}",
                            "-o", str(part), "HEAD"], cwd=Path(root) / path, check=True)
            parts.append(f"@{part}")
        tmp = out.with_name(out.name + ".tmp")
        subprocess.run(["/usr/bin/tar", "-c", "-z", "-f", str(tmp), *parts], check=True)
        os.replace(tmp, out)
    finally:
        shutil.rmtree(parts_dir, ignore_errors=True)
    return out


DMG_SPCTL_ARGS = ["-a", "-vv", "-t", "open", "--context", "context:primary-signature"]


def make_dmg(app: Path, out: Path, identity: str | None = None) -> Path:
    """The installer disk image (nanogram/dmg.py: a compressed APFS image with the app, an Applications link and the
    Finder window layout), signed with `identity` if given: Gatekeeper checks a disk image's own signature, so an
    unsigned one is rejected even when notarized."""
    out = disk_image.build(Path(app), Path(out))
    if identity:
        subprocess.run(["codesign", "--force", "--timestamp", "--sign", identity, str(out)], check=True)
    return out


def notarize(path: Path, key: AscKey) -> None:
    """Submits `path` (a .dmg or .zip; an .app is zipped first) to Apple's notary service, waits, staples."""
    path = Path(path)
    submit = path
    if path.suffix == ".app":
        submit = path.with_name(path.stem + "-notarize.zip")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(path), str(submit)], check=True)
    auth = ["--key", str(key.path), "--key-id", key.key_id, "--issuer", key.issuer]
    print(f"==> Notarizing {path.name} (waits for Apple)", flush=True)
    result = subprocess.run(["xcrun", "notarytool", "submit", str(submit), *auth, "--wait",
                             "--output-format", "json"], capture_output=True, text=True)
    try:
        response = json.loads(result.stdout or "{}")
    except ValueError:
        response = {}
    status, submission = response.get("status", "unknown"), response.get("id", "")
    if not submission:
        found = re.search(r"submissions/([0-9a-f-]{36})", result.stdout + result.stderr)
        submission = found.group(1) if found else ""
    for _ in range(3):
        if status in ("Accepted", "Invalid", "Rejected") or not submission:
            break
        print(f"==> Apple did not answer in time; waiting on submission {submission}", flush=True)
        waited = subprocess.run(["xcrun", "notarytool", "wait", submission, *auth, "--timeout", "30m",
                                 "--output-format", "json"], capture_output=True, text=True)
        try:
            status = json.loads(waited.stdout or "{}").get("status", "unknown")
        except ValueError:
            status = "unknown"
    if submit != path:
        submit.unlink(missing_ok=True)
    if status != "Accepted":
        log = path.parent / f"notarization-{submission or 'failed'}.json"
        if submission:
            details = subprocess.run(["xcrun", "notarytool", "log", submission, *auth], capture_output=True,
                                     text=True)
            log.write_text(details.stdout or details.stderr)
        else:
            log.write_text(result.stdout + result.stderr)
        raise ReleaseError(f"notarization of {path.name}: {status}; Apple's log: {log}")
    staple = subprocess.run(["xcrun", "stapler", "staple", str(path)], capture_output=True, text=True)
    if staple.returncode != 0:
        raise ReleaseError(f"stapler could not staple {path.name}: {staple.stdout.strip()} {staple.stderr.strip()}")
    print(f"==> Notarized and stapled {path.name} (submission {submission})", flush=True)


def download_url(version: str, build: str) -> str:
    return f"{RELEASES_REPO}/releases/download/v{version}-{build}/Nanogram-{version}-{build}.dmg"


def appcast_entry(version: str, build: str, dmg: Path, ed_signature: str, url: str) -> str:
    from email.utils import formatdate
    from xml.sax.saxutils import escape, quoteattr
    return (f"    <item>\n"
            f"      <title>{escape(f'Nanogram {version} ({build})')}</title>\n"
            f"      <pubDate>{formatdate(usegmt=True)}</pubDate>\n"
            f"      <sparkle:version>{escape(build)}</sparkle:version>\n"
            f"      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>\n"
            f"      <sparkle:minimumSystemVersion>{MIN_MACOS}</sparkle:minimumSystemVersion>\n"
            f"      <enclosure url={quoteattr(url)} length=\"{Path(dmg).stat().st_size}\" "
            f"type=\"application/octet-stream\" sparkle:edSignature={quoteattr(ed_signature)}/>\n"
            f"    </item>\n")


def appcast(entries: list[str]) -> str:
    from nanogram import sparkle
    return ("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            f"<rss version=\"2.0\" xmlns:sparkle=\"{SPARKLE_NS}\">\n"
            "  <channel>\n"
            "    <title>Nanogram</title>\n"
            f"    <link>{sparkle.FEED_URL}</link>\n"
            + "".join(entries) +
            "  </channel>\n"
            "</rss>\n")


SIGNING_BLOCK_PREFIX = "<!-- sparkle-signatures:\n"


def sign_appcast(feed: str, key_file: Path | None = None) -> str:
    """The feed followed by Sparkle 2.10's signing block (edSignature and byte length of everything before it),
    which an app with SURequireSignedFeed verifies before it trusts a single item. A block already there is replaced."""
    from nanogram import sparkle
    start = feed.rfind(SIGNING_BLOCK_PREFIX)
    content = feed if start < 0 else feed[:start]
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "appcast.xml"
        path.write_bytes(content.encode())
        signature = sparkle.sign(path, key_file or sparkle.KEY_FILE)
    return f"{content}{SIGNING_BLOCK_PREFIX}edSignature: {signature}\nlength: {len(content.encode())}\n-->\n"


def write_signed_appcast(out_dir: Path, entries: list[str], key_file: Path | None = None) -> Path:
    path = Path(out_dir) / "appcast.xml"
    path.write_text(sign_appcast(appcast(entries), key_file))
    return path


def _check(command: list[str], what: str) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        raise ReleaseError(f"{what} failed: {output.splitlines()[-1] if output else result.returncode}")
    return output


def release_direct(allow_dirty: bool = False) -> Path:
    from nanogram import sparkle
    key = asc_key()
    sparkle.public_key()
    build, version = build_number(), marketing_version()
    changed = tracked_changes()
    if changed and not allow_dirty:
        raise ReleaseError(f"{len(changed)} tracked changes ({', '.join(changed[:3])}...): commit them first, so the "
                           "source archive matches the binary (or pass --allow-dirty for a test build)")
    out_dir = config.BUILD_OUTPUT / "direct" / build
    out_dir.mkdir(parents=True, exist_ok=True)
    archive_path = archive("direct", build, out_dir, key)
    record_build(archive_path, out_dir, "direct", build)
    app = _single(export(archive_path, "direct", out_dir, key), "*.app")
    authority = _signing_authority(app)
    check_exported_app(app, "direct")
    _check(["codesign", "--verify", "--deep", "--strict", str(app)], "codesign --verify --deep --strict")
    notarize(app, key)
    name = f"Nanogram-{version}-{build}"
    dmg = make_dmg(app, out_dir / f"{name}.dmg", identity=authority)
    notarize(dmg, key)
    print(_check(["spctl", *DMG_SPCTL_ARGS, str(dmg)], "spctl (dmg)"), flush=True)
    print(_check(["spctl", "-a", "-vv", "-t", "exec", str(app)], "spctl (app)"), flush=True)
    signature = sparkle.sign(dmg)
    if not sparkle.verify(dmg, signature, sparkle.public_key()):
        raise ReleaseError("the Sparkle signature of the dmg does not verify with our public key")
    write_signed_appcast(out_dir, [appcast_entry(version, build, dmg, signature, download_url(version, build))])
    print("==> Writing the source archive", flush=True)
    source_archive(out_dir / f"{name}-source.tar.gz", f"{name}-source")
    print(f"==> Direct release {version} ({build}) in {out_dir} (not uploaded): {dmg.name}, appcast.xml, "
          f"{name}-source.tar.gz", flush=True)
    return out_dir


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg release")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("settings", help="print the Release command-line settings, one per line")
    flight = commands.add_parser("testflight", help="archive, export and upload the mas edition")
    flight.add_argument("--export-only", action="store_true", help="sign the .pkg, do not upload")
    direct = commands.add_parser("release-direct", help="notarized dmg, appcast and source archive (local)")
    direct.add_argument("--allow-dirty", action="store_true", help="build with uncommitted tracked changes")
    args = parser.parse_args(argv)
    try:
        if args.command == "settings":
            print("\n".join(release_settings()))
        elif args.command == "testflight":
            testflight(export_only=args.export_only)
        else:
            release_direct(allow_dirty=args.allow_dirty)
    except config.ConfigError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
