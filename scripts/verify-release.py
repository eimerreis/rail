#!/usr/bin/env python3
"""Reject stale release runs and ensure Sparkle generated a signed archive entry."""
from pathlib import Path
import sys
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


if __name__ == "__main__":
    verify(Path(sys.argv[1]), sys.argv[2])
