"""Check privacy declarations in the generated app, not just its source template."""
from pathlib import Path
import plistlib
import sys
import unittest


class BundlePrivacyTests(unittest.TestCase):
    def test_bluetooth_usage_description(self):
        # Chromium can query paired devices from the browser process. Without
        # this declaration, macOS TCC terminates the entire app instead of
        # presenting a permission prompt.
        with (APP / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        description = info.get("NSBluetoothAlwaysUsageDescription")
        self.assertIsInstance(description, str,
                              "The app must declare NSBluetoothAlwaysUsageDescription")
        self.assertTrue(description.strip(), "The Bluetooth usage explanation must not be blank")


if __name__ == "__main__":
    APP = Path(sys.argv.pop(1))
    unittest.main()
