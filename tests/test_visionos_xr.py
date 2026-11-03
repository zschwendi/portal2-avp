"""Exercise the native XR boundary without requiring any retail game files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple SIMD headers required')
class XRContractTests(unittest.TestCase):
    def test_native_contract(self):
        with tempfile.TemporaryDirectory(prefix='portal2-xr-') as directory:
            binary = str(Path(directory) / 'xr-check')
            subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=undefined', '-fno-sanitize-recover=all',
                            '-I' + str(ROOT / 'runtime/visionos'),
                            str(ROOT / 'runtime/visionos/p2_xr.c'),
                            str(ROOT / 'tests/visionos_xr_check.c'), '-o', binary], check=True)
            subprocess.run([binary], check=True)


if __name__ == '__main__':
    unittest.main()
