"""Hand gesture/arbitration model and native input gate checks; no headset or game files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
GESTURES = ROOT/'visionos/Sources/PortalHandGestures.swift'
CHECKS = ROOT/'tests/visionos_hand_checks.swift'


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Swift simd required')
class HandGestureTests(unittest.TestCase):
    def run_checks(self, *flags):
        with tempfile.TemporaryDirectory(prefix='p2-hands-') as directory:
            binary = str(Path(directory)/'hand-check')
            subprocess.run(['xcrun', 'swiftc', *flags, '-warnings-as-errors', '-parse-as-library',
                            str(GESTURES), str(CHECKS), '-o', binary], check=True, capture_output=True, text=True)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('hand checks passed', result.stdout)

    def test_swift5_strict_concurrency(self):
        self.run_checks('-swift-version', '5', '-strict-concurrency=complete')

    def test_swift6(self):
        self.run_checks('-swift-version', '6')

    def test_model_stays_platform_independent(self):
        imports = [line for line in GESTURES.read_text().splitlines() if line.startswith('import ')]
        self.assertEqual(imports, ['import simd'])


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'visionOS SDK required')
class NativeInputGateTests(unittest.TestCase):
    def test_input_bridge_compiles_for_visionos(self):
        sdl = ROOT/'deps/visionos/device/include/SDL2'
        if not (sdl/'SDL.h').exists():
            self.skipTest('visionOS SDL headers not prepared')
        sdk = subprocess.run(['xcrun', '--sdk', 'xros', '--show-sdk-path'], capture_output=True, text=True)
        if sdk.returncode:
            self.skipTest('visionOS SDK not installed')
        for game in ('0', '1'):
            subprocess.run(['xcrun', '--sdk', 'xros', 'clang', '-fsyntax-only', '-target', 'arm64-apple-xros2.0',
                            '-isysroot', sdk.stdout.strip(), '-Wall', '-Wextra', '-Werror', '-DP2_VISION_GAME=' + game,
                            '-I' + str(sdl), '-I' + str(ROOT/'runtime/visionos'),
                            str(ROOT/'runtime/visionos/input_vision.c')], check=True)
        source = (ROOT/'runtime/visionos/input_vision.c').read_text()
        self.assertIn('P2_VISION_INPUT_HANDS', source)
        self.assertIn('p2_vision_head_aim_active()', source)


if __name__ == '__main__':
    unittest.main()
