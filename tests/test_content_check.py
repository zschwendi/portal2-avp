"""Owned-content completeness gate (runtime/content_check.c) and its launchers.

The C checks build small synthetic VPK directory files and archives in a
temporary folder; no game data is read or needed.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / 'runtime/content_check.c'
WARNINGS = ['-Wall', '-Wextra', '-Werror']


def sdk_path(name):
    result = subprocess.run(['xcrun', '--sdk', name, '--show-sdk-path'], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple clang and sanitizers required')
class ContentCheckTests(unittest.TestCase):
    def test_synthetic_vpk_trees(self):
        with tempfile.TemporaryDirectory(prefix='p2-content-') as directory:
            binary = str(Path(directory) / 'content-check')
            subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-O1', '-g', *WARNINGS,
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                            '-I' + str(ROOT / 'runtime'), str(CHECK), str(ROOT / 'tests/content_check_test.c'),
                            '-o', binary], check=True)
            scratch = Path(directory) / 'scratch'
            scratch.mkdir()
            result = subprocess.run([binary, str(scratch)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('content checks passed', result.stdout)

            status_folder = scratch / 'status'
            status = json.loads((status_folder / 'portal2-setup-status.json').read_text())
            # Atomic replacement leaves no temporary files behind.
            self.assertEqual(sorted(p.name for p in status_folder.iterdir()),
                             ['game', 'linux', 'portal2-setup-status.json', 'prep'])
            self.assertRegex(status['timestamp'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
            self.assertIsInstance(status['unix_time'], int)
            self.assertEqual((status['platform'], status['app_version'], status['app_build'], status['trigger']),
                             ('test', '1.2', None, 'check-again'))
            self.assertIs(status['complete'], False)
            self.assertIs(status['engine_started'], False)
            self.assertEqual((status['archives'], status['missing_archives'], status['short_archives']), (3, 1, 0))
            self.assertEqual(status['missing_bytes_estimate'], 3000)
            self.assertEqual(status['missing_names'], ['game/portal2/pak01_002.vpk', 'game/we"ird\\\x01??'])
            self.assertEqual(status['volume_available_important_usage_bytes'], 1234567)
            self.assertIsNone(status['volume_total_bytes'])
            self.assertIsInstance(status['check_microseconds'], int)
            self.assertLess(len((status_folder / 'portal2-setup-status.json').read_bytes()), 2048)

    def test_check_has_no_platform_dependencies(self):
        includes = re.findall(r'^#include\s+[<"]([^>"]+)[>"]', CHECK.read_text(), re.M)
        self.assertEqual(sorted(includes), sorted(['content_check.h', 'dirent.h', 'errno.h', 'fcntl.h', 'limits.h',
                                                   'stdarg.h', 'stdio.h', 'stdlib.h', 'string.h', 'sys/stat.h',
                                                   'time.h', 'unistd.h']))
        header = (ROOT / 'runtime/content_check.h').read_text()
        self.assertIn('#define P2_CONTENT_STATUS_FILE "portal2-setup-status.json"', header)


class LauncherGateTests(unittest.TestCase):
    """Source contracts: both launchers run the check before the engine starts."""

    def test_visionos_start_requires_complete_content(self):
        source = (ROOT / 'runtime/visionos/game_vision.m').read_text()
        start = source[source.index('int p2_vision_game_start(const char *trigger) {'):]
        self.assertLess(start.index('content_check(documents, &report)'), start.index('dispatch_async('))
        self.assertLess(start.index('return atomic_load(&state) == -1 ? -1 : 0;'), start.index('dispatch_async('))
        self.assertNotIn('fileExistsAtPath:[documents stringByAppendingPathComponent:relative]', source)
        self.assertIn('NSURLVolumeAvailableCapacityForImportantUsageKey', source)
        self.assertIn('p2_content_write_status', source)
        view = (ROOT / 'visionos/Sources/PortalGameView.swift').read_text()
        # The view starts the engine only through the gated call, never directly.
        self.assertEqual(view.count('p2_vision_game_start('), 1)
        self.assertIn('if p2_vision_game_start(trigger) == 0 { return nil }', view)
        self.assertNotIn('engine test', view.lower())
        self.assertIn('Check again', view)

    def test_ios_gate_runs_before_engine(self):
        main = (ROOT / 'ios/main_ios.c').read_text()
        self.assertLess(main.index('rt_ios_content_gate('), main.index('return p2_main('))
        gate = (ROOT / 'runtime/ios/content_gate.m').read_text()
        self.assertIn('while (!gate.passed)', gate)
        self.assertIn('NSURLVolumeAvailableCapacityForImportantUsageKey', gate)
        self.assertIn('tools/ios_device.sh data', gate)

    def test_display_names(self):
        project = (ROOT / 'visionos/project.yml').read_text()
        game = project[project.index('  Portal2Game:'):project.index('  Portal2RendererCheck:')]
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: dev.zschwendi.portal2avp.enginetest', game)  # keeps saves/imports
        self.assertRegex(game, r'(?m)^\s+INFOPLIST_KEY_CFBundleDisplayName: Portal 2$')
        self.assertIn('INFOPLIST_KEY_CFBundleDisplayName: Portal 2 Renderer Check', project)


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple SDKs required')
class LauncherCompileTests(unittest.TestCase):
    def test_ios_gate_compiles(self):
        for sdk_name, triple in (('iphoneos', 'arm64-apple-ios17.0'), ('iphonesimulator', 'arm64-apple-ios17.0-simulator')):
            sdk = sdk_path(sdk_name)
            if not sdk:
                self.skipTest(f'{sdk_name} SDK not installed')
            base = ['xcrun', '--sdk', sdk_name, 'clang', '-fsyntax-only', '-target', triple, '-isysroot', sdk,
                    *WARNINGS, '-I' + str(ROOT / 'runtime'), '-I' + str(ROOT / 'runtime/ios')]
            subprocess.run([*base, '-fobjc-arc', str(ROOT / 'runtime/ios/content_gate.m')], check=True)
            subprocess.run([*base, str(CHECK)], check=True)
            sdl = ROOT / 'deps/ios' / ('device' if sdk_name == 'iphoneos' else 'sim') / 'include/SDL2'
            if (sdl / 'SDL_main.h').exists():
                subprocess.run([*base, '-I' + str(sdl), str(ROOT / 'ios/main_ios.c')], check=True)

    def test_visionos_launcher_compiles(self):
        sdk = sdk_path('xros')
        prefix = ROOT / 'deps/visionos/device/include'
        if not sdk or not (prefix / 'SDL2/SDL.h').exists():
            self.skipTest('visionOS SDK or SDL headers not prepared')
        subprocess.run(['xcrun', '--sdk', 'xros', 'clang', '-fsyntax-only', '-target', 'arm64-apple-xros2.0',
                        '-isysroot', sdk, *WARNINGS, '-DP2_VISION_GAME=1', '-fobjc-arc',
                        '-I' + str(ROOT / 'runtime'), '-I' + str(ROOT / 'runtime/ios'),
                        '-I' + str(ROOT / 'runtime/visionos'), '-I' + str(prefix), '-I' + str(prefix / 'SDL2'),
                        str(ROOT / 'runtime/visionos/game_vision.m')], check=True)
        sources = sorted(str(p) for p in (ROOT / 'visionos/Sources').glob('*.swift'))
        result = subprocess.run(['xcrun', '--sdk', 'xros', 'swiftc', '-typecheck', '-target', 'arm64-apple-xros2.0',
                                 '-swift-version', '6', '-D', 'P2_GAME',
                                 '-import-objc-header', str(ROOT / 'visionos/Portal2XR-Bridging-Header.h'),
                                 '-Xcc', '-DP2_GAME=1', '-Xcc', '-I' + str(prefix), '-Xcc', '-I' + str(prefix / 'SDL2'),
                                 *sources], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('warning:', result.stderr)


if __name__ == '__main__':
    unittest.main()
