#!/usr/bin/env python3
"""Fetch the pinned Sparkle framework and release tools, preserving symlinks."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    lock = json.loads((ROOT / "sparkle.lock.json").read_text())
    vendor = ROOT / "vendor"
    destination = vendor / "sparkle"
    stamp = destination / ".rail-sparkle.json"
    required = ["Sparkle.framework/Sparkle", "Sparkle.framework/Headers/Sparkle.h",
                "bin/generate_appcast", "bin/sign_update", "LICENSE"]
    if (stamp.exists() and json.loads(stamp.read_text()) == lock
            and all((destination / name).exists() for name in required)):
        print("Sparkle is ready: " + str(destination))
        return
    cache = vendor / ".downloads"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / lock["archive"]

    def verified(path):
        if not path.exists() or path.stat().st_size != lock["size"]:
            return False
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest() == lock["sha256"]

    if not verified(archive):
        partial = archive.with_suffix(archive.suffix + ".part")
        try:
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent",
                            "--show-error", "--retry", "3", "--connect-timeout", "30",
                            "--output", str(partial), lock["archive_url"]], check=True)
            if not verified(partial):
                raise RuntimeError("Sparkle archive size or SHA-256 does not match sparkle.lock.json")
            os.replace(partial, archive)
        finally:
            partial.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sparkle-extract-", dir=vendor) as staging:
        with tarfile.open(archive, "r:xz") as source:
            source.extractall(staging, filter="data")
        staged = Path(staging)
        if not all((staged / name).exists() for name in required):
            raise RuntimeError("Sparkle archive is missing the framework or release tools")
        (staged / stamp.name).write_text(json.dumps(lock, indent=2) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        staged.rename(destination)
    print("Sparkle is ready: " + str(destination))


if __name__ == "__main__":
    main()
