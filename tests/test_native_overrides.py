"""tools/lift.py NATIVE_OVERRIDES: wrapper generation, runtime definitions and
prefixes against the owned Linux binaries (skipped when they are absent).

Only the lifter's own short validation prefixes appear here, never game code.
"""
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('lift', ROOT / 'tools/lift.py')
lift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lift)
import visionos_hooks  # noqa: E402
from elfprep import Elf  # noqa: E402

TRACE = ('server.so', 0x5a2250)
CLIENT_TRACE = ('client.so', 0x8abe60)


def expected_length(prefix):
    return len(re.sub(r'\(\.\{(\d+)\}\)', lambda m: 'x' * int(m.group(1)), prefix)) // 2


def owned_binary(name):
    config = ROOT / 'config/local.json'
    if not config.is_file():
        return None
    root = Path(json.loads(config.read_text()).get('linux_root', ''))
    return next((path for path in (root / 'bin/linux32' / name, root / 'portal2/bin/linux32' / name)
                 if path.is_file()), None)


class OverrideTableTests(unittest.TestCase):
    def test_trace_entries_match_the_audited_profile(self):
        # The lifter and the visionOS profile must describe the same bytes.
        self.assertEqual(lift.NATIVE_OVERRIDES[TRACE],
                         ('rt_native_trace_fire_portal', 'TRACE_FIRE_PORTAL', visionos_hooks.SERVER_TRACE_PREFIX.hex()))
        self.assertEqual(lift.NATIVE_OVERRIDES[CLIENT_TRACE],
                         ('rt_native_trace_fire_portal_client', 'TRACE_FIRE_PORTAL_CLIENT',
                          visionos_hooks.CLIENT_TRACE_PREFIX.hex()))

    def test_runtime_defines_every_override_on_every_platform(self):
        # Generated C is shared by the Mac, iPhone and visionOS builds; each
        # links runtime/native.c, so every replacement is defined there.
        source = (ROOT / 'runtime/native.c').read_text()
        for function, name, _ in lift.NATIVE_OVERRIDES.values():
            self.assertRegex(source, rf'\nint {function}\(CPU \*c, uint32_t entry\) {{')
            self.assertLessEqual(len('P2_NATIVE_' + name), 63)  # rt_native_enabled's buffer

    def test_wrapper_runs_the_guest_trace_unless_replaced(self):
        prefix = lift.NATIVE_OVERRIDES[TRACE][2]
        base, entry = 0x17500000, 0x17500000 + TRACE[1]
        with tempfile.TemporaryDirectory(prefix='portal2-native-override-') as directory:
            image = Path(directory) / 'server.so'
            code = bytearray(0x1000)
            code[0x250:0x250 + len(prefix) // 2] = bytes.fromhex(prefix)
            image.write_bytes(bytes(code))
            module = dict(name='server.so', base=base, image=str(image),
                          loads=[dict(vaddr=entry - 0x250, off=0, filesz=len(code), flags=5)])
            layout = dict(modules=[module])
            body = f'void fn_{entry:x}(CPU *restrict c) {{\n    c->eax = 1;\n}}'
            wrapper = lift.native_override(layout, entry, body, log=self.fail)
            self.assertIn(f'static void fn_{entry:x}_guest(CPU *restrict c) {{', wrapper)
            self.assertIn('int rt_native_trace_fire_portal(CPU *c, uint32_t entry);', wrapper)
            self.assertIn(f'if (!rt_native_enabled("TRACE_FIRE_PORTAL", &state) || '
                          f'!rt_native_trace_fire_portal(c, {entry:#x}u)) fn_{entry:x}_guest(c);', wrapper)
            # Another build of the game: nothing is replaced.
            code[0x250 + 12] ^= 1
            image.write_bytes(bytes(code))
            messages = []
            self.assertIsNone(lift.native_override(layout, entry, body, log=messages.append))
            self.assertIn('rt_native_trace_fire_portal', messages[0])


class OwnedPrefixTests(unittest.TestCase):
    def test_prefixes_match_owned_binaries(self):
        checked = 0
        for (name, rva), (function, _, prefix) in lift.NATIVE_OVERRIDES.items():
            path = owned_binary(name)
            if path is None:
                continue
            elf = Elf(path, 0, 1)
            length = expected_length(prefix)
            offset = elf.v2o(rva)
            self.assertIsNotNone(offset, f'{name} {rva:#x}')
            self.assertRegex(bytes(elf.data[offset:offset + length]).hex(), f'^(?:{prefix})$', function)
            checked += 1
        if not checked:
            self.skipTest('owned Linux Portal 2 binaries not configured')

    def test_trace_prefixes_are_not_relocated(self):
        # The lifter compares relocated image bytes: a relocation inside the
        # prefix would make the match depend on the load address.
        for name, rva in (TRACE, CLIENT_TRACE):
            path = owned_binary(name)
            if path is None:
                self.skipTest('owned Linux Portal 2 binaries not configured')
            length = expected_length(lift.NATIVE_OVERRIDES[(name, rva)][2])
            relocated = [offset for offset, _, _ in Elf(path, 0, 1).rels() if rva - 3 <= offset < rva + length]
            self.assertEqual(relocated, [], name)

    def test_prefixes_match_prepared_images(self):
        # What the lifter itself reads (build/game/prep relocated copies).
        layout_path = ROOT / 'build/game/prep/layout.json'
        if not layout_path.is_file():
            self.skipTest('no prepared game layout')
        layout = json.loads(layout_path.read_text())
        for module in layout['modules']:
            module['image'] = str(ROOT / module['image']) if not Path(module['image']).is_absolute() else module['image']
        modules = {module['name']: module for module in layout['modules']}
        checked = 0
        for (name, rva), (function, _, prefix) in lift.NATIVE_OVERRIDES.items():
            module = modules.get(name)
            if module is None or not Path(module['image']).is_file():
                continue
            entry = module['base'] + rva
            self.assertIs(lift.owner(layout, entry), module, function)
            self.assertRegex(lift.guest_bytes(module, entry, expected_length(prefix)).hex(), f'^(?:{prefix})$', function)
            checked += 1
        if not checked:
            self.skipTest('prepared images absent')


if __name__ == '__main__':
    unittest.main()
