"""Native host checks for the visionOS runtime input/config helpers (no game files)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOLCHAIN = Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang')
MACOS_SDK = Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk')


def clang():
    # Direct toolchain binaries when present (no xcrun indirection).
    if TOOLCHAIN.exists() and MACOS_SDK.exists():
        return [str(TOOLCHAIN), '-isysroot', str(MACOS_SDK)]
    return ['xcrun', '--sdk', 'macosx', 'clang']


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple SIMD headers required')
class RuntimeInputTests(unittest.TestCase):
    def run_check(self, sources, sanitizers='undefined'):
        with tempfile.TemporaryDirectory(prefix='portal2-vision-') as directory:
            binary = str(Path(directory) / 'check')
            subprocess.run([*clang(), '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fsanitize=' + sanitizers,
                            '-fno-sanitize-recover=all', '-I' + str(ROOT / 'runtime/visionos'),
                            *[str(ROOT / s) for s in sources], '-o', binary], check=True)
            subprocess.run([binary], check=True)

    def test_xr_contract_and_pose_isolation(self):
        self.run_check(['runtime/visionos/p2_xr.c', 'tests/visionos_xr_check.c'])

    def test_menu_input(self):
        self.run_check(['runtime/visionos/menu_input.c', 'tests/visionos_menu_input_check.c'])

    def test_video_config(self):
        self.run_check(['runtime/visionos/video_config.c', 'tests/visionos_video_config_check.c'],
                       'address,undefined')


if __name__ == '__main__':
    unittest.main()
