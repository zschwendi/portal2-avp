"""Local custom chambers (runtime/custom_levels.c, tools/custom_levels.py) and the offline Workshop stub.

Everything runs on synthetic VBSP/VPK files in temporary folders; no game data is read. The C
checks compile the production sources with the host clang (no SDK tools) under ASan/UBSan.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
WARNINGS = ['-Wall', '-Wextra', '-Werror']
spec = importlib.util.spec_from_file_location('custom_levels', ROOT / 'tools/custom_levels.py')
levels = importlib.util.module_from_spec(spec)
spec.loader.exec_module(levels)


def make_bsp(version=21, pakfile=True, fill=0x10):
    header = bytearray(1036)
    header[0:4] = b'VBSP'
    struct.pack_into('<i', header, 4, version)
    body = bytearray()
    for i, lump in enumerate((0, 1, 5, 14, 40) if pakfile else (0, 1, 5, 14)):
        struct.pack_into('<ii', header, 8 + 16 * lump, 1036 + len(body), 16)
        body += bytes([fill + i]) * 16
    struct.pack_into('<i', header, 8 + 64 * 16, 7)
    return bytes(header + body)


def make_vpk(paths):
    """VPK v1 directory with the given 'dir/name.ext' entries (no data)."""
    tree = bytearray()
    by_ext = {}
    for path in paths:
        folder, file = path.rsplit('/', 1)
        name, ext = file.rsplit('.', 1)
        by_ext.setdefault(ext, {}).setdefault(folder, []).append(name)
    for ext, folders in by_ext.items():
        tree += ext.encode() + b'\0'
        for folder, names in folders.items():
            tree += folder.encode() + b'\0'
            for name in names:
                tree += name.encode() + b'\0' + struct.pack('<IHHIIH', 0, 0, 0x7fff, 0, 0, 0xffff)
            tree += b'\0'
        tree += b'\0'
    tree += b'\0'
    return struct.pack('<III', 0x55AA1234, 1, len(tree)) + bytes(tree)


def clang(*args, out):
    subprocess.run(['clang', '-O1', '-g', *WARNINGS, *args, '-o', out], check=True, cwd=ROOT)


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'host clang and sanitizers required')
class NativeChecks(unittest.TestCase):
    def test_runtime_custom_levels(self):
        with tempfile.TemporaryDirectory(prefix='p2-levels-') as temp:
            binary = os.path.join(temp, 'custom-levels-test')
            clang('-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-Iruntime',
                  'runtime/custom_levels.c', 'tests/custom_levels_test.c', out=binary)
            scratch = os.path.join(temp, 'scratch')
            os.mkdir(scratch)
            result = subprocess.run([binary, scratch], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_python_and_native_launch_blocks_interoperate(self):
        driver = r'''
#include "custom_levels.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    p2cl_status s = !strcmp(argv[1], "request") ? p2cl_request_launch(argv[2], argv[3], argv[4]) : p2cl_clear_launch(argv[2]);
    if (s != P2CL_OK) { fprintf(stderr, "%s\n", p2cl_status_text(s)); return 1; }
    return argc < 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='p2-levels-') as temp:
            source, binary = os.path.join(temp, 'driver.c'), os.path.join(temp, 'driver')
            Path(source).write_text(driver)
            clang('-Iruntime', 'runtime/custom_levels.c', source, out=binary)
            game, docs = Path(temp, 'game'), Path(temp, 'docs')
            (game / 'portal2/maps').mkdir(parents=True)
            docs.mkdir()
            chamber = Path(temp, 'chamber.bsp')
            chamber.write_bytes(make_bsp())
            levels.import_source(str(game), str(chamber))
            (docs / 'launch.args').write_text('-condebug\n')
            levels.request_launch(str(docs), str(game), 'chamber')       # Python writes, C clears
            subprocess.run([binary, 'clear', str(docs)], check=True)
            self.assertEqual((docs / 'launch.args').read_text(), '-condebug\n')
            subprocess.run([binary, 'request', str(docs), str(game), 'chamber'], check=True)   # C writes, Python clears
            self.assertEqual(levels._launch_lines(str(docs))[0], '-condebug')
            text = (docs / 'launch.args').read_text().splitlines()
            self.assertEqual(text[1:], [levels.BEGIN, '+map', 'custom/chamber', levels.END])
            levels.clear_launch(str(docs))
            self.assertEqual((docs / 'launch.args').read_text(), '-condebug\n')

    def test_offline_stub_refuses_workshop_without_fake_success(self):
        probe = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
uint64_t SteamAPI_ISteamRemoteStorage_EnumeratePublishedWorkshopFiles(void *, int32_t, uint32_t, uint32_t, uint32_t, void *, void *);
uint64_t SteamAPI_ISteamRemoteStorage_EnumerateUserSharedWorkshopFiles(void *, uint64_t, uint32_t, void *, void *);
bool SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTags(void *, uint64_t, void *);
bool SteamAPI_ISteamUser_BLoggedOn(void *);
int main(void) {
    int tags[2] = {0};
    printf("%llu %llu %d\n", (unsigned long long)SteamAPI_ISteamRemoteStorage_EnumeratePublishedWorkshopFiles(0, 3, 0, 50, 7, tags, 0),
           (unsigned long long)SteamAPI_ISteamRemoteStorage_EnumerateUserSharedWorkshopFiles(0, 1, 0, tags, 0),
           (int)SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTags(0, 5, tags));
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='p2-stub-') as temp:
            source, binary = os.path.join(temp, 'probe.c'), os.path.join(temp, 'probe')
            Path(source).write_text(probe)
            # The stub is iOS/visionOS-only; forcing its branch builds the same source for the host.
            clang('-Wno-macro-redefined', '-DTARGET_OS_IPHONE=1', 'runtime/ios/steam_stub.c',
                  'runtime/ios/steam_stub_generated.c', source, out=binary)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split(), ['0', '0', '0'])   # k_uAPICallInvalid, k_uAPICallInvalid, false
            self.assertEqual(result.stderr.count('[steam-stub] Workshop'), 1)       # logged once


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='p2-levels-')
        self.root = Path(self.temp.name)
        self.game = self.root / 'game'
        (self.game / 'portal2/maps').mkdir(parents=True)
        (self.game / 'portal2/SAVE').mkdir()
        (self.game / 'portal2/maps/sp_a1_intro1.bsp').write_bytes(make_bsp(fill=0x60))
        (self.game / 'portal2/SAVE/quick.sav').write_bytes(b'SAVE-DATA')
        (self.game / 'portal2/pak01_dir.vpk').write_bytes(make_vpk(['materials/metal/wall.vmt', 'scripts/vscripts/stock.nut']))
        (self.game / 'update').mkdir()
        (self.game / 'update/pak01_dir.vpk').write_bytes(make_vpk(['models/props/cube.mdl']))
        self.stock = self.snapshot()

    def tearDown(self):
        self.assertEqual({k: v for k, v in self.snapshot().items() if k in self.stock}, self.stock)   # originals intact
        self.temp.cleanup()

    def snapshot(self):
        result = {}
        for path in sorted(self.game.rglob('*')):
            rel = path.relative_to(self.game).as_posix()
            if path.is_file() and '/maps/custom/' not in '/' + rel and not rel.startswith('portal2/materials/custom'):
                result[rel] = path.read_bytes()
        return result

    def zip_package(self, members, symlink=None, name='package.zip'):
        path = self.root / name
        with zipfile.ZipFile(path, 'w') as archive:
            for member, data in members.items():
                archive.writestr(member, data)
            if symlink:
                info = zipfile.ZipInfo(symlink)
                info.external_attr = (0o120777 << 16)
                archive.writestr(info, '../../portal2/maps/sp_a1_intro1.bsp')
        return path

    def custom(self):
        return sorted(p.name for p in (self.game / 'portal2/maps/custom').iterdir()) if (self.game / 'portal2/maps/custom').exists() else []

    def test_inspect_matches_native_rules(self):
        self.assertTrue(levels.inspect_bsp(make_bsp())['has_pakfile'])
        self.assertFalse(levels.inspect_bsp(make_bsp(pakfile=False))['has_pakfile'])
        for bad, message in [(make_bsp(version=20), 'version'), (b'IBSP' + make_bsp()[4:], 'VBSP'),
                             (make_bsp()[:600], 'truncated'), (make_bsp()[:-1], 'out of range'), (b'VB', 'VBSP')]:
            with self.assertRaisesRegex(levels.LevelError, message):
                levels.inspect_bsp(bad)
        broken = bytearray(make_bsp())
        struct.pack_into('<i', broken, 12 + 16 * 14, 0)
        with self.assertRaisesRegex(levels.LevelError, 'essential'):
            levels.inspect_bsp(bytes(broken))

    def test_single_bsp_import_list_launch_remove(self):
        source = self.root / 'My Chamber.bsp'
        source.write_bytes(make_bsp())
        report = levels.import_source(str(self.game), str(source))
        self.assertEqual(report['maps'][0]['map'], 'custom/my_chamber')
        self.assertEqual((self.game / 'portal2/maps/custom/my_chamber.bsp').read_bytes(), make_bsp())
        with self.assertRaisesRegex(levels.LevelError, 'already exists'):
            levels.import_source(str(self.game), str(source))
        source.write_bytes(make_bsp(fill=0x30))
        levels.import_source(str(self.game), str(source), replace=True)
        self.assertEqual((self.game / 'portal2/maps/custom/my_chamber.bsp').read_bytes(), make_bsp(fill=0x30))
        self.assertEqual([m['name'] for m in levels.list_maps(str(self.game))], ['my_chamber'])
        docs = self.root / 'docs'
        docs.mkdir()
        levels.request_launch(str(docs), str(self.game), 'my_chamber')
        self.assertIn('custom/my_chamber', (docs / 'launch.args').read_text())
        levels.clear_launch(str(docs))
        self.assertEqual((docs / 'launch.args').read_text(), '')
        self.assertEqual(levels.remove_map(str(self.game), 'my_chamber')['removed'], ['maps/custom/my_chamber.bsp'])
        self.assertEqual(levels.list_maps(str(self.game)), [])

    def test_refuses_bad_names_links_and_missing_game(self):
        source = self.root / 'ok.bsp'
        source.write_bytes(make_bsp())
        for name in ('../sp_a1_intro1', 'a/b', 'UPPER', '-x', ''):
            with self.assertRaises(levels.LevelError):
                levels.import_source(str(self.game), str(source), name=name or None) if name else levels.check_name(name)
        link = self.root / 'link.bsp'
        link.symlink_to(source)
        with self.assertRaisesRegex(levels.LevelError, 'symbolic'):
            levels.import_source(str(self.game), str(link))
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        (self.game / 'portal2/maps/custom').symlink_to(elsewhere)
        with self.assertRaisesRegex(levels.LevelError, 'symbolic'):
            levels.import_source(str(self.game), str(source))
        self.assertEqual(list(elsewhere.iterdir()), [])
        with self.assertRaisesRegex(levels.LevelError, 'not found'):
            levels.import_source(str(self.root / 'nogame'), str(source))

    def test_zip_package_with_companions_and_manifest_removal(self):
        package = self.zip_package({
            'Chamber Pack/maps/pack_chamber.bsp': make_bsp(),
            'Chamber Pack/materials/custom/sign.vmt': b'"LightmappedGeneric" {}',
            'Chamber Pack/materials/custom/sign.vtf': b'VTF\0data',
            'Chamber Pack/readme.txt': b'hello',
            'Chamber Pack/cfg/autoexec.cfg': b'sv_cheats 1',
        })
        report = levels.import_source(str(self.game), str(package))
        self.assertEqual([m['name'] for m in report['maps']], ['pack_chamber'])
        self.assertEqual(sorted(report['companions']), ['materials/custom/sign.vmt', 'materials/custom/sign.vtf'])
        self.assertEqual(sorted(report['ignored']), ['cfg/autoexec.cfg', 'readme.txt'])
        self.assertFalse((self.game / 'portal2/cfg').exists())
        manifest = json.loads((self.game / 'portal2/maps/custom/pack_chamber.files.json').read_text())
        self.assertEqual(sorted(manifest['companions']), report['companions'])
        levels.import_source(str(self.game), str(package), replace=True)              # same package again: allowed
        (self.game / 'portal2/materials/custom/sign.vtf').write_bytes(b'edited by the player')
        with self.assertRaisesRegex(levels.LevelError, 'modified since'):
            levels.import_source(str(self.game), str(package), replace=True)
        self.assertEqual((self.game / 'portal2/materials/custom/sign.vtf').read_bytes(), b'edited by the player')
        result = levels.remove_map(str(self.game), 'pack_chamber')
        self.assertEqual(result['kept'], ['materials/custom/sign.vtf'])               # modified: left in place
        self.assertFalse((self.game / 'portal2/materials/custom/sign.vmt').exists())
        self.assertEqual(self.custom(), [])

    def test_package_refuses_shadowing_stock_and_rolls_back(self):
        for stock_path in ('materials/metal/wall.vmt', 'MODELS/props/cube.mdl', 'scripts/vscripts/stock.nut'):
            package = self.zip_package({'maps/shadow.bsp': make_bsp(), stock_path: b'replacement'}, name='shadow.zip')
            with self.assertRaisesRegex(levels.LevelError, 'original game file'):
                levels.import_source(str(self.game), str(package))
            self.assertEqual(self.custom(), [])
        (self.game / 'portal2/materials/loose').mkdir(parents=True)
        (self.game / 'portal2/materials/loose/player.vmt').write_bytes(b'player file')
        package = self.zip_package({'maps/clash.bsp': make_bsp(), 'materials/loose/player.vmt': b'different'}, name='clash.zip')
        with self.assertRaisesRegex(levels.LevelError, 'different content'):
            levels.import_source(str(self.game), str(package))
        self.assertEqual((self.game / 'portal2/materials/loose/player.vmt').read_bytes(), b'player file')
        package = self.zip_package({'maps/same.bsp': make_bsp(), 'materials/loose/player.vmt': b'player file'}, name='same.zip')
        report = levels.import_source(str(self.game), str(package))                   # identical file: shared, untouched
        self.assertEqual((report['companions'], report['shared']), (['materials/loose/player.vmt'], ['materials/loose/player.vmt']))
        levels.remove_map(str(self.game), 'same')
        self.assertEqual((self.game / 'portal2/materials/loose/player.vmt').read_bytes(), b'player file')
        package = self.zip_package({'maps/bad.bsp': make_bsp(version=19), 'materials/custom/x.vmt': b'x'}, name='bad.zip')
        with self.assertRaisesRegex(levels.LevelError, 'version'):
            levels.import_source(str(self.game), str(package))
        self.assertFalse((self.game / 'portal2/materials/custom/x.vmt').exists())   # rolled back with the map
        self.assertEqual(self.custom(), [])

    def test_archive_and_folder_safety(self):
        cases = {
            'traversal.zip': {'maps/ok.bsp': make_bsp(), '../evil.vmt': b'x'},
            'nested.zip': {'maps/ok.bsp': make_bsp(), 'materials/../../evil.vmt': b'x'},
            'absolute.zip': {'maps/ok.bsp': make_bsp(), '/etc/evil.vmt': b'x'},
            'backslash.zip': {'maps/ok.bsp': make_bsp(), 'materials\\..\\evil.vmt': b'x'},
            'duplicate.zip': {'maps/ok.bsp': make_bsp(), 'maps/OK.bsp': make_bsp()},
            'nomap.zip': {'materials/custom/a.vmt': b'x'},
        }
        for name, members in cases.items():
            with self.subTest(name):
                with self.assertRaises(levels.LevelError):
                    levels.import_source(str(self.game), str(self.zip_package(members, name=name)))
                self.assertEqual(self.custom(), [])
        with self.assertRaisesRegex(levels.LevelError, 'symbolic'):
            levels.import_source(str(self.game), str(self.zip_package({'maps/ok.bsp': make_bsp()}, symlink='materials/link.vmt', name='l.zip')))
        folder = self.root / 'folder'
        (folder / 'maps').mkdir(parents=True)
        (folder / 'maps/folder_map.bsp').write_bytes(make_bsp())
        (folder / 'materials').symlink_to(self.game / 'portal2')
        with self.assertRaisesRegex(levels.LevelError, 'symbolic'):
            levels.import_source(str(self.game), str(folder))
        (folder / 'materials').unlink()
        self.assertEqual(levels.import_source(str(self.game), str(folder))['maps'][0]['name'], 'folder_map')
        self.assertFalse(levels.import_source(str(self.game), str(folder), dry_run=True, replace=True)['ignored'])

    def test_member_larger_than_declared_is_refused(self):
        chunks = levels.bounded_chunks(lambda: io.BytesIO(b'x' * 100), 10, 1 << 20)
        with self.assertRaisesRegex(levels.LevelError, 'larger than declared'):
            list(chunks)

    def test_cli_reports_errors_as_json(self):
        result = subprocess.run(['python3', '-I', str(ROOT / 'tools/custom_levels.py'), 'check', str(self.root / 'missing.bsp')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('error', json.loads(result.stderr))


if __name__ == '__main__':
    unittest.main()
