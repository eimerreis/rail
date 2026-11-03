"""Ensure bundled code can run on every macOS version offered the update."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import unittest


def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


class BundleCompatibilityTests(unittest.TestCase):
    def test_bundled_executables_support_the_declared_minimum_macos(self):
        info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        minimum = info['LSMinimumSystemVersion']
        binaries = [APP / 'Contents/MacOS' / info['CFBundleExecutable'],
                    APP / 'Contents/MacOS/RailPasswordHelper',
                    APP / 'Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework',
                    APP / 'Contents/Frameworks/Sparkle.framework/Sparkle']
        for helper in (APP / 'Contents/Frameworks').glob('*.app'):
            helper_info = plistlib.loads((helper / 'Contents/Info.plist').read_bytes())
            binaries.append(helper / 'Contents/MacOS' / helper_info['CFBundleExecutable'])
        for binary in binaries:
            with self.subTest(binary=str(binary.relative_to(APP))):
                result = subprocess.run(['xcrun', 'vtool', '-show-build', str(binary)],
                                        check=True, capture_output=True, text=True)
                targets = re.findall(r'\bminos\s+([\d.]+)', result.stdout)
                self.assertTrue(targets, 'No macOS deployment target found in ' + str(binary))
                for target in targets:
                    self.assertLessEqual(version(target), version(minimum),
                        f'{binary.name} requires macOS {target}, but Rail declares {minimum}')


if __name__ == '__main__':
    APP = Path(sys.argv.pop(1))
    unittest.main()
