#!/usr/bin/env python3
"""Download the pinned official CEF Release distribution and verify its checksum."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "cef.lock.json").read_text())
VENDOR = ROOT / "vendor"
DESTINATION = VENDOR / "cef"


def verified(path):
    if not path.exists() or path.stat().st_size != LOCK["size"]:
        return False
    checksum = hashlib.sha1()
    with path.open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest() == LOCK["sha1"]


def main():
    stamp = DESTINATION / ".rail-cef.json"
    required = ["include/cef_version.h", "cmake/FindCEF.cmake",
                "Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"]
    if (stamp.exists() and json.loads(stamp.read_text()) == LOCK
            and all((DESTINATION / name).exists() for name in required)):
        print("CEF is ready: " + str(DESTINATION))
        return

    VENDOR.mkdir(exist_ok=True)
    cache = VENDOR / ".downloads"
    cache.mkdir(exist_ok=True)
    archive = cache / LOCK["archive"]
    if not verified(archive):
        # Confirm the pinned hash and file size against the official build index.
        index = json.loads(subprocess.run(
            ["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
             "--retry", "3", "--connect-timeout", "30", LOCK["index_url"]],
            check=True, capture_output=True).stdout)
        entries = index[LOCK["platform"]]["versions"]
        files = [file for version in entries
                 if version["cef_version"] == LOCK["cef_version"]
                 and version["channel"] == LOCK["channel"]
                 for file in version["files"] if file["name"] == LOCK["archive"]]
        if not files or any(files[0][key] != LOCK[key] for key in ("sha1", "size")):
            raise RuntimeError("Pinned CEF archive does not match the official build index")
        partial = archive.with_suffix(archive.suffix + ".part")
        print("Downloading CEF " + LOCK["cef_version"], flush=True)
        try:
            subprocess.run(
                ["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                 "--retry", "3", "--connect-timeout", "30", "--output", str(partial),
                 LOCK["archive_url"]], check=True)
            if not verified(partial):
                raise RuntimeError("CEF archive size or SHA-1 checksum does not match cef.lock.json")
            os.replace(partial, archive)
        finally:
            partial.unlink(missing_ok=True)

    print("Verified CEF archive; extracting Release runtime", flush=True)
    with tempfile.TemporaryDirectory(prefix=".cef-extract-", dir=VENDOR) as staging:
        staging_path = Path(staging)
        with tarfile.open(archive, "r:bz2") as source:
            # Reject absolute paths, traversal, and links escaping the archive root.
            for member in source.getmembers():
                output = (staging_path / member.name).resolve()
                if not output.is_relative_to(staging_path.resolve()):
                    raise RuntimeError("Unsafe path in CEF archive: " + member.name)
                if member.issym() or member.islnk():
                    base = output.parent if member.issym() else staging_path
                    if not (base / member.linkname).resolve().is_relative_to(staging_path.resolve()):
                        raise RuntimeError("Unsafe link in CEF archive: " + member.name)
                if member.isdev() or member.isfifo():
                    raise RuntimeError("Unsupported special file in CEF archive")
            source.extractall(staging, filter="data")
        extracted = staging_path / LOCK["archive"].removesuffix(".tar.bz2")
        if not extracted.is_dir():
            raise RuntimeError("CEF archive has an unexpected top-level directory")
        (extracted / ".rail-cef.json").write_text(json.dumps(LOCK, indent=2) + "\n")
        if DESTINATION.exists():
            shutil.rmtree(DESTINATION)
        extracted.rename(DESTINATION)
    print("CEF is ready: " + str(DESTINATION))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("CEF bootstrap failed: " + str(error), file=sys.stderr)
        sys.exit(1)
