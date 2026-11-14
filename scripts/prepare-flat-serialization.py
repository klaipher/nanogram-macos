#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

FLATBUFFERS_VERSION = "25.12.19"
FLATBUFFERS_URL = "https://github.com/google/flatbuffers/archive/refs/tags/v25.12.19.zip"
FLATBUFFERS_SHA256 = "f5d4636bfc4d30c622c9ad238ce947848c2b90b10aecd387dc62cdee2584359b"


def cache_directory():
    base = os.environ.get("NANOGRAM_CACHE_DIR")
    base = Path(base) if base else Path.home() / "Library" / "Caches" / "nanogram"
    return base / "flatc" / FLATBUFFERS_VERSION


def cached_flatc():
    binary = cache_directory() / "flatc"
    return binary if binary.is_file() and os.access(binary, os.X_OK) else None


def build_flatc():
    binary = cached_flatc()
    if binary:
        return binary
    directory = cache_directory()
    binary = directory / "flatc"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="flatc-build-", dir=directory) as temporary:
        work = Path(temporary)
        archive = work / "flatbuffers.zip"
        with urllib.request.urlopen(FLATBUFFERS_URL, timeout=60) as response:
            archive.write_bytes(response.read())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != FLATBUFFERS_SHA256:
            raise RuntimeError("flatbuffers " + FLATBUFFERS_VERSION + " archive has sha256 " + digest + ", expected " + FLATBUFFERS_SHA256)
        shutil.unpack_archive(str(archive), str(work))
        source = work / ("flatbuffers-" + FLATBUFFERS_VERSION)
        build = source / "build"
        build.mkdir()
        subprocess.run(["cmake", "..", "-DCMAKE_BUILD_TYPE=Release", "-DFLATBUFFERS_BUILD_TESTS=0", "-DFLATBUFFERS_INSTALL=0",
                        "-DFLATBUFFERS_BUILD_FLATLIB=0", "-DFLATBUFFERS_STATIC_FLATC=0"], cwd=build, check=True)
        subprocess.run(["cmake", "--build", ".", "--target", "flatc", "--parallel"], cwd=build, check=True)
        built = build / "flatc"
        staged = binary.with_suffix(".tmp")
        shutil.copy2(built, staged)
        os.replace(staged, binary)
    return binary


def flatc_path(root):
    override = root / "scripts/flatc"
    if override.is_file() and os.access(override, os.X_OK):
        return override
    return build_flatc()


def prepare(root):
    base = root / "submodules/telegram-ios/submodules/TelegramCore/FlatSerialization"
    models = sorted((base / "Models").glob("*.fbs"))
    if not models:
        raise RuntimeError("FlatSerialization models are missing")
    output = base / "Sources"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="flat-serialization-") as temporary:
        staging = Path(temporary)
        subprocess.run([str(flatc_path(root)), "--require-explicit-ids", "--swift", "-o", str(staging)]
                       + [str(model) for model in models], check=True)
        generated = list(staging.glob("*.swift"))
        expected = {model.stem + "_generated.swift" for model in models}
        if {path.name for path in generated} != expected or any(path.stat().st_size == 0 for path in generated):
            raise RuntimeError("flatc did not produce complete Swift sources")
        for path in generated:
            destination = output / path.name
            contents = path.read_bytes()
            if destination.is_file() and destination.read_bytes() == contents:
                continue
            staged = destination.with_suffix(".swift.tmp")
            staged.write_bytes(contents)
            os.replace(staged, destination)
        names = {path.name for path in generated}
        for path in output.glob("*.swift"):
            if path.name not in names:
                path.unlink()
    print("FlatSerialization sources prepared; unchanged files preserved.")


if __name__ == "__main__":
    try:
        prepare(Path(__file__).resolve().parent.parent)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("error: FlatSerialization generation: " + str(error), file=sys.stderr)
        sys.exit(1)
