"""Exercise stable-engine selection and actual Sparkle feed signing with public test keys."""
import base64
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


updates = module("update-cef")
releases = module("verify-release")


def build(chromium, cef="156.0.15", channel="stable", kind="minimal"):
    version = cef + "+g123abcd+chromium-" + chromium
    return dict(cef_version=version, chromium_version=chromium, channel=channel,
                files=[dict(type=kind, name=f"cef_binary_{version}_macosarm64_minimal.tar.bz2",
                            size=100, sha1="a" * 40)])


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.current = dict(platform="macosarm64", channel="stable", cef_version="156.0.14+g123abcd+chromium-156.0.8078.48",
                            chromium_version="156.0.8078.48", index_url="https://cef-builds.spotifycdn.com/index.json")

    def select(self, *versions):
        return updates.latest_lock(self.current, {"macosarm64": {"versions": list(versions)}})

    def test_numeric_selection_ignores_index_order_and_other_channels(self):
        selected = self.select(build("156.0.8078.90"), build("157.0.8100.1", "157.0.1", "beta"),
                               build("156.0.8078.100"), build("156.0.8078.80"))
        self.assertEqual(selected["chromium_version"], "156.0.8078.100")
        self.assertIn("%2B", selected["archive_url"])
        self.assertEqual(selected["sha1"], "a" * 40)
        self.assertEqual(selected["size"], 100)

    def test_old_reuploaded_build_cannot_downgrade_engine(self):
        self.assertEqual(self.select(build("156.0.8078.40")), self.current)

    def test_cef_revision_updates_even_when_chromium_stays_the_same(self):
        self.assertEqual(self.select(build("156.0.8078.48"))["cef_version"].split("+")[0], "156.0.15")

    def test_skips_engines_without_a_minimal_build(self):
        self.assertEqual(self.select(build("156.0.8078.80", kind="standard")), self.current)

    def test_waits_for_a_stable_mac_arm_build(self):
        self.assertEqual(self.select(build("157.0.8100.1", "157.0.1", "beta")), self.current)
        self.assertEqual(self.select(), self.current)

    def test_rejects_unsafe_archive_metadata(self):
        for field, value in (("name", "../../unsafe.tar.bz2"), ("size", -1), ("sha1", "bad")):
            version = build("156.0.8078.80")
            version["files"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.select(version)

    def test_rejects_nonstable_configuration(self):
        self.current["channel"] = "beta"
        with self.assertRaises(ValueError):
            self.select()

    def test_release_uses_committed_engine_without_downgrading(self):
        releases.verify_engine(self.current, self.current)
        newer = dict(self.current, chromium_version="156.0.8078.100")
        releases.verify_engine(newer, self.current)
        with self.assertRaises(ValueError):
            releases.verify_engine(self.current, newer)
        with self.assertRaises(ValueError):
            releases.verify_engine(dict(self.current, platform="windows64"), self.current)


@unittest.skipUnless(sys.platform == "darwin" and (ROOT / "vendor/sparkle/bin/generate_appcast").exists(),
                     "Requires the pinned macOS Sparkle tools")
class SparkleFeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rail feed test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "updates"
        self.output.mkdir()
        # Public RFC 8032 test vector, never a release credential or a Keychain item.
        self.key = self.root / "test-key"
        self.key.write_text(base64.b64encode(bytes.fromhex(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode())
        self.public = base64.b64encode(bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()

    def tool(self, name, *args, check=True):
        return subprocess.run([str(ROOT / "vendor/sparkle/bin" / name), *map(str, args)],
                              check=check, capture_output=True, text=True)

    def archive(self, version):
        app = self.root / "Rail Fixture.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True, exist_ok=True)
        plist = dict(CFBundleIdentifier="invalid.example.rail.fixture", CFBundleName="Rail Fixture",
                     CFBundleVersion=version, CFBundleShortVersionString="0.1.0", LSMinimumSystemVersion="13.0",
                     SUFeedURL="https://example.invalid/appcast.xml", SUPublicEDKey=self.public,
                     SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        executable = app / "Contents/MacOS/Fixture"
        executable.parent.mkdir(exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        path = self.output / ("Rail-" + version + ".zip")
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(path)], check=True)
        return path

    def generate(self):
        self.tool("generate_appcast", "--ed-key-file", self.key, "--download-url-prefix",
                  "https://github.com/example/rail/releases/download/test/", "--maximum-deltas", "0",
                  "--maximum-versions", "0", self.output)

    def test_real_feed_preserves_history_and_rejects_tampering_and_stale_runs(self):
        old = self.archive("1.1.0")
        self.generate()
        old.unlink()  # Older archives stay on their original GitHub Releases.
        new = self.archive("2.1.0")
        self.generate()
        feed = self.output / "appcast.xml"
        versions = {item.findtext(releases.SPARKLE + "version") for item in ET.parse(feed).findall("./channel/item")}
        self.assertEqual(versions, {"1.1.0", "2.1.0"})
        releases.verify(feed, "2.1.0")
        with self.assertRaises(ValueError):
            releases.verify(feed, "1.1.0")
        self.tool("sign_update", "--verify", "--ed-key-file", self.key, feed)
        enclosure = next(item.find("enclosure") for item in ET.parse(feed).findall("./channel/item")
                         if item.findtext(releases.SPARKLE + "version") == "2.1.0")
        signature = enclosure.get(releases.SPARKLE + "edSignature")
        self.tool("sign_update", "--verify", "--ed-key-file", self.key, new, signature)
        new.write_bytes(new.read_bytes() + b"tampered")
        self.assertNotEqual(self.tool("sign_update", "--verify", "--ed-key-file", self.key, new, signature, check=False).returncode, 0)
        with self.assertRaises(ValueError):
            releases.verify(feed, "2.1.0")
        feed.write_text(feed.read_text().replace("2.1.0", "9.1.0"))
        self.assertNotEqual(self.tool("sign_update", "--verify", "--ed-key-file", self.key, feed, check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
