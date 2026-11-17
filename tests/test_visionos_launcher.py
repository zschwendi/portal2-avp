"""Launcher card and controller-route rules (PortalLauncherModel.swift); no headset or game files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT/'visionos/Sources/PortalLauncherModel.swift'
CHECKS = ROOT/'tests/visionos_launcher_checks.swift'


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Swift toolchain required')
class LauncherModelTests(unittest.TestCase):
    def run_checks(self, *flags):
        with tempfile.TemporaryDirectory(prefix='p2-launcher-') as directory:
            binary = str(Path(directory)/'launcher-check')
            subprocess.run(['xcrun', 'swiftc', *flags, '-warnings-as-errors', '-parse-as-library',
                            str(MODEL), str(CHECKS), '-o', binary], check=True, capture_output=True, text=True)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('launcher checks passed', result.stdout)

    def test_swift5_strict_concurrency(self):
        self.run_checks('-swift-version', '5', '-strict-concurrency=complete')

    def test_swift6(self):
        self.run_checks('-swift-version', '6')

    def test_model_stays_platform_independent(self):
        imports = [line for line in MODEL.read_text().splitlines() if line.startswith('import ')]
        self.assertEqual(imports, ['import Foundation'])


if __name__ == '__main__':
    unittest.main()
