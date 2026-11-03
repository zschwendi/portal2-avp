"""Owned-content completeness gate (runtime/content_check.c) and its launchers.

The C checks build small synthetic VPK directory files, archives and content
manifests in a temporary folder; no game data is read or needed.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / 'runtime/content_check.c'
WARNINGS = ['-Wall', '-Wextra', '-Werror']
spec = importlib.util.spec_from_file_location('owned_content_manifest', ROOT / 'tools/serve_owned_content.py')
server_api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_api)


def sdk_path(name):
    result = subprocess.run(['xcrun', '--sdk', name, '--show-sdk-path'], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple clang and sanitizers required')
class ContentCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='p2-content-')
        cls.binary = str(Path(cls.temp.name) / 'content-check')
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-O1', '-g', *WARNINGS,
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        '-I' + str(ROOT / 'runtime'), str(CHECK), str(ROOT / 'tests/content_check_test.c'),
                        '-o', cls.binary], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_synthetic_vpk_trees(self):
        with tempfile.TemporaryDirectory(prefix='p2-content-') as directory:
            binary = self.binary
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
            # No manifest in that tree: the weaker check, its sentinel map present.
            self.assertEqual((status['manifest'], status['manifest_bad'], status['maps_missing']), (False, False, False))
            self.assertEqual((status['manifest_files'], status['manifest_missing'], status['manifest_wrong_size']), (0, 0, 0))
            self.assertLess(len((status_folder / 'portal2-setup-status.json').read_bytes()), 2048)

            listed = json.loads((scratch / 'status-manifest/portal2-setup-status.json').read_text())
            self.assertIs(listed['complete'], False)
            self.assertEqual((listed['manifest'], listed['manifest_bad'], listed['maps_missing']), (True, False, False))
            self.assertEqual((listed['manifest_files'], listed['manifest_missing'], listed['manifest_wrong_size']), (10, 1, 0))
            self.assertEqual((listed['missing_archives'], listed['missing_bytes_estimate']), (0, 70))
            self.assertEqual(listed['missing_names'], ['game/portal2/maps/sp_a2_laser_intro.bsp'])
            self.assertEqual(sorted(listed), sorted(status))

    def check(self, documents):
        status = Path(documents).parent / 'check-status.json'
        result = subprocess.run([self.binary, '--check', str(documents), str(status)], capture_output=True, text=True,
                                timeout=60)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        report = json.loads(status.read_text())
        self.assertEqual(report['complete'], result.returncode == 0)
        return report

    def test_python_manifest_writer_matches_gate(self):
        """tools/serve_owned_content.py --write-content-manifest output, read by the C gate."""
        with tempfile.TemporaryDirectory(prefix='p2-content-manifest-') as directory:
            documents = Path(directory) / 'Documents'
            files = {
                'prep/layout.json': b'{}',
                'linux/portal2_linux': b'\x7fELF' + bytes(60),
                # Smallest valid VPK directory: v1 header and an empty tree.
                'game/portal2/pak01_dir.vpk': struct.pack('<III', 0x55aa1234, 1, 1) + b'\0',
                'game/portal2/maps/sp_a1_intro1.bsp': b'map' * 20,
                'game/portal2/maps/sp_a2_laser_intro.bsp': b'map' * 30,
                'game/portal2/maps/empty.txt': b'',
                'game/bin/library.so': b'x' * 7,
            }
            for name, data in files.items():
                (documents / name).parent.mkdir(parents=True, exist_ok=True)
                (documents / name).write_bytes(data)
            (documents / 'game/portal2/.DS_Store').write_bytes(b'skipped')
            manifest = documents / server_api.CONTENT_MANIFEST_NAME
            roots = server_api.source_roots(documents / 'game', documents / 'linux', documents / 'prep')
            self.assertEqual(server_api.write_content_manifest(manifest, roots),
                             (len(files), sum(len(data) for data in files.values())))
            lines = manifest.read_text().splitlines()
            self.assertEqual(lines[0], 'P2-CONTENT-MANIFEST 1')
            self.assertEqual(sorted(lines[1:]), sorted(f'{len(data)}\t{name}' for name, data in files.items()))
            self.assertEqual([p.name for p in documents.iterdir() if p.name.endswith('.tmp')], [])

            report = self.check(documents)
            self.assertIs(report['complete'], True)
            self.assertEqual((report['manifest'], report['manifest_bad'], report['manifest_files']), (True, False, len(files)))
            # A campaign map still copying: the archive checks pass, the manifest does not.
            (documents / 'game/portal2/maps/sp_a2_laser_intro.bsp').unlink()
            report = self.check(documents)
            self.assertIs(report['complete'], False)
            self.assertEqual((report['manifest_missing'], report['missing_archives'], report['missing_bytes_estimate']),
                             (1, 0, 90))
            self.assertEqual(report['missing_names'], ['game/portal2/maps/sp_a2_laser_intro.bsp'])
            (documents / 'game/portal2/maps/sp_a2_laser_intro.bsp').write_bytes(b'map' * 29)
            report = self.check(documents)
            self.assertEqual((report['complete'], report['manifest_missing'], report['manifest_wrong_size']), (False, 0, 1))
            (documents / 'game/portal2/maps/sp_a2_laser_intro.bsp').write_bytes(b'map' * 30)
            # CRLF and no final line break read the same.
            manifest.write_bytes(manifest.read_bytes().replace(b'\n', b'\r\n').rstrip(b'\r\n'))
            self.assertIs(self.check(documents)['complete'], True)
            manifest.write_bytes(b'P2-CONTENT-MANIFEST 1\n1\tgame/portal2/../../escape\n')
            report = self.check(documents)
            self.assertEqual((report['complete'], report['manifest_bad'], report['manifest_files']), (False, True, 0))
            # Without a manifest: archives plus the sentinel map.
            manifest.unlink()
            self.assertEqual(self.check(documents)['manifest'], False)
            self.assertIs(self.check(documents)['complete'], True)
            (documents / 'game/portal2/maps/sp_a1_intro1.bsp').unlink()
            report = self.check(documents)
            self.assertEqual((report['complete'], report['maps_missing']), (False, True))

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
        self.assertIn('game files are missing', view)
        self.assertIn('the campaign maps (game/portal2/maps) are missing', view)

    def test_importer_writes_manifest_last(self):
        source = (ROOT / 'visionos/Sources/PortalContentImporter.swift').read_text()
        header = (ROOT / 'runtime/content_check.h').read_text()
        for name in ('P2_CONTENT_MANIFEST_FILE "portal2-content-manifest.txt"',
                     'P2_CONTENT_MANIFEST_HEADER "P2-CONTENT-MANIFEST 1"'):
            self.assertIn(name, header)
            self.assertIn(name.split(' ', 1)[1], source)
        self.assertEqual(server_api.CONTENT_MANIFEST_HEADER, 'P2-CONTENT-MANIFEST 1')
        self.assertEqual(server_api.CONTENT_MANIFEST_NAME, 'portal2-content-manifest.txt')
        perform = source[source.index('private func perform('):source.index('nonisolated static let retryDelays')]
        # Built (and its paths checked) before any download; written only after the loop over every file.
        self.assertLess(perform.index('contentManifestText(manifest)'), perform.index('for (index, (file, dest))'))
        self.assertLess(perform.rindex('completedBytes = done\n        }'), perform.index('writeContentManifest('))
        self.assertEqual(source.count('writeContentManifest(gateManifest'), 1)
        writer = source[source.index('static func writeContentManifest('):source.index('static func rejectLinks(')]
        self.assertIn('O_EXCL', writer)
        self.assertIn('rename(temporary.path, destination.path)', writer)
        self.assertNotIn('removeItem', writer)

    def test_ios_gate_runs_before_engine(self):
        main = (ROOT / 'ios/main_ios.c').read_text()
        self.assertLess(main.index('rt_ios_content_gate('), main.index('return p2_main('))
        gate = (ROOT / 'runtime/ios/content_gate.m').read_text()
        self.assertIn('while (!gate.passed)', gate)
        # Default Documents roots get the manifest check; explicit roots keep the archive check.
        self.assertIn('if (_documentsLayout) p2_content_check(_roots[3], &_report);', gate)
        self.assertIn('else p2_content_check_roots(_roots[0], _roots[1], _roots[2], &_report);', gate)
        self.assertIn('game files are missing', gate)
        self.assertIn('the campaign maps (game/portal2/maps) are missing', gate)
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
