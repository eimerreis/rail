#!/usr/bin/env python3
"""Reject stale release runs and ensure Sparkle generated a signed archive entry."""
from pathlib import Path
import argparse
import importlib.util
import json
import xml.etree.ElementTree as ET


SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify(path, version):
    items = ET.parse(path).findall("./channel/item")
    versions = [item.findtext(SPARKLE + "version") for item in items]
    key = lambda value: tuple(int(part) for part in value.split("."))
    if not versions or any(value is None for value in versions) or max(versions, key=key) != version:
        raise ValueError("This build is older than an existing published build")
    entry = items[versions.index(version)]
    enclosure = entry.find("enclosure")
    if enclosure is None or not enclosure.get(SPARKLE + "edSignature") or int(enclosure.get("length", "0")) <= 0:
        raise ValueError("Release feed is missing a signed archive")
    if not enclosure.get("url", "").startswith("https://github.com/"):
        raise ValueError("Release archive must use HTTPS GitHub hosting")
    archive = path.parent / enclosure.get("url").rsplit("/", 1)[-1]
    if not archive.is_file() or archive.stat().st_size != int(enclosure.get("length")):
        raise ValueError("The signed archive is missing or its length differs from the feed")


def verify_engine(current, previous):
    spec = importlib.util.spec_from_file_location("update_cef", Path(__file__).with_name("update-cef.py"))
    updates = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(updates)
    if any(current[key] != previous[key] for key in ("platform", "channel", "index_url")):
        raise ValueError("The released engine uses a different platform, channel, or index")
    if updates.version_key(current) < updates.version_key(previous):
        raise ValueError("Version the latest released Chromium engine before publishing; engine downgrades are not allowed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=Path, nargs="?")
    parser.add_argument("version", nargs="?")
    parser.add_argument("--engine", type=Path)
    parser.add_argument("--minimum-engine", type=Path)
    args = parser.parse_args()
    if args.engine and args.minimum_engine:
        verify_engine(json.loads(args.engine.read_text()), json.loads(args.minimum_engine.read_text()))
    elif args.feed and args.version:
        verify(args.feed, args.version)
    else:
        parser.error("Provide feed and version, or --engine and --minimum-engine")
