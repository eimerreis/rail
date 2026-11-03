#!/usr/bin/env python3
"""Select the newest stable macOS ARM64 minimal CEF build from the official index."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote, urljoin


ROOT = Path(__file__).resolve().parents[1]


def version_key(lock):
    return (tuple(int(part) for part in lock["chromium_version"].split(".")),
            tuple(int(part) for part in lock["cef_version"].split("+")[0].split(".")))


def latest_lock(current, index):
    if current["platform"] != "macosarm64" or current["channel"] != "stable":
        raise ValueError("Automatic updates require the stable macosarm64 channel")
    candidates = []
    for version in index[current["platform"]]["versions"]:
        if version.get("channel") != "stable":
            continue
        for archive in version["files"]:
            if archive.get("type") != "minimal":
                continue
            name = archive["name"]
            expected = f'cef_binary_{version["cef_version"]}_macosarm64_minimal.tar.bz2'
            if (name != expected or not re.fullmatch(r"[a-f0-9]{40}", archive["sha1"])
                    or not isinstance(archive["size"], int) or archive["size"] <= 0):
                raise ValueError("Invalid CEF archive metadata")
            candidate = dict(current, cef_version=version["cef_version"],
                             chromium_version=version["chromium_version"], archive=name,
                             archive_url=urljoin(current["index_url"], quote(name, safe="")),
                             size=archive["size"], sha1=archive["sha1"])
            if version_key(candidate) > version_key(current):
                candidates.append(candidate)
    return max(candidates, key=version_key, default=current)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Update cef.lock.json; otherwise print it")
    parser.add_argument("--minimum-lock", type=Path, help="Previously released lock; never downgrade it")
    args = parser.parse_args()
    path = ROOT / "cef.lock.json"
    current = json.loads(path.read_text())
    if args.minimum_lock:
        baseline = json.loads(args.minimum_lock.read_text())
        if any(baseline[key] != current[key] for key in ("platform", "channel", "index_url")):
            raise ValueError("The released CEF lock uses a different platform, channel, or index")
        current = max((current, baseline), key=version_key)
    index = json.loads(subprocess.run([
        "/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
        "--connect-timeout", "30", current["index_url"]], check=True, capture_output=True).stdout)
    selected = latest_lock(current, index)
    contents = json.dumps(selected, indent=2) + "\n"
    if args.write:
        path.write_text(contents)
        print("Pinned CEF " + selected["cef_version"])
    else:
        print(contents, end="")


if __name__ == "__main__":
    main()
