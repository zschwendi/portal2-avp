"""visionOS hook profile: fail-closed header and owned-binary derivation.

Checks against the owned client.so/engine.so/server.so skip when they are
absent. No game bytes are stored here beyond the tool's own short validation
prefixes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import struct
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import visionos_hooks  # noqa: E402
from elfprep import Elf  # noqa: E402

CLIENT = dict(vtable_rva=0x1000, render_view_rva=0x2000, setup_size=260, signature='5589e5')
ENGINE = dict(interface='VEngineClient015', vtable_rva=0x3000, get_view_angles_slot=18,
              set_view_angles_slot=19, get_view_angles_rva=0x4000, set_view_angles_rva=0x5000,
              get_signature='5383ec', set_signature='57ba00')
TRACE = dict(trace_fire_portal_rva=0x6000, return_rva=0x6abc, signature='5589e5', call_site='5753e8',
             placed_by_player=2)
VIEWMODEL = dict(vtable_rva=0x7000, predicted_vtable_rva=0x7400, calc_viewmodel_view_slot=288,
                 calc_viewmodel_view_rva=0x8000, set_local_origin_rva=0x9000, set_local_angles_rva=0x9100,
                 view_signature='5589e5', set_origin_signature='5653', set_angles_signature='5653')
AIM = dict(server_trace=TRACE, client_trace=dict(TRACE, trace_fire_portal_rva=0x6100), viewmodel=VIEWMODEL)
SERVER_TRACE, SERVER_RETURN = 0x5a2250, 0x5a2c2c
CLIENT_TRACE, CLIENT_RETURN = 0x8abe60, 0x8ac869


def owned_root():
    config = ROOT / 'config/local.json'
    if not config.is_file():
        return None
    root = Path(json.loads(config.read_text()).get('linux_root', ''))
    needed = (root / 'bin/linux32/engine.so', root / 'portal2/bin/linux32/client.so',
              root / 'portal2/bin/linux32/server.so')
    return root if all(path.is_file() for path in needed) else None


class HeaderTests(unittest.TestCase):
    def test_header_fails_closed_without_engine(self):
        source = visionos_hooks.header_source(CLIENT)
        self.assertIn('#define P2_XR_HEAD_AIM_PROFILE 0', source)
        self.assertNotIn('VIEW_ANGLES', source)
        self.assertIn('P2_XR_RENDER_VIEW_RVA 0x2000u', source)

    def test_head_aim_header(self):
        source = visionos_hooks.header_source(CLIENT, ENGINE)
        for line in ('#define P2_XR_HEAD_AIM_PROFILE 1', '#define P2_XR_ENGINE_CLIENT_INTERFACE "VEngineClient015"',
                     '#define P2_XR_SET_VIEW_ANGLES_SLOT 19u', '#define P2_XR_GET_VIEW_ANGLES_RVA 0x4000u',
                     'p2_xr_set_view_angles_signature[] = {0x57,0xba,0x00};'):
            self.assertIn(line, source)

    def test_aim_header_fails_closed(self):
        for aim in (None, dict(server_trace=None, client_trace=TRACE, viewmodel=VIEWMODEL)):
            source = visionos_hooks.header_source(CLIENT, ENGINE, aim)
            for line in ('#define P2_XR_PORTAL_AIM_PROFILE 0', '#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 0',
                         '#define P2_XR_VIEWMODEL_PROFILE 0'):
                self.assertIn(line, source)
            self.assertNotIn('TRACE_FIRE_PORTAL_RVA', source)  # no server: nothing moves to the controller
        source = visionos_hooks.header_source(CLIENT, None, dict(AIM, client_trace=None, viewmodel=None))
        for line in ('#define P2_XR_PORTAL_AIM_PROFILE 1', '#define P2_XR_SERVER_TRACE_FIRE_PORTAL_RVA 0x6000u',
                     '#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 0', '#define P2_XR_VIEWMODEL_PROFILE 0',
                     '#define P2_XR_HEAD_AIM_PROFILE 0'):
            self.assertIn(line, source)

    def test_aim_header(self):
        source = visionos_hooks.header_source(CLIENT, ENGINE, AIM)
        for line in ('#define P2_XR_PORTAL_AIM_PROFILE 1', '#define P2_XR_PORTAL_PLACED_BY_PLAYER 2u',
                     '#define P2_XR_SERVER_TRACE_FIRE_PORTAL_RETURN_RVA 0x6abcu',
                     'p2_xr_server_trace_call_site[] = {0x57,0x53,0xe8};',
                     '#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 1', '#define P2_XR_CLIENT_TRACE_FIRE_PORTAL_RVA 0x6100u',
                     '#define P2_XR_VIEWMODEL_PROFILE 1', '#define P2_XR_CALC_VIEWMODEL_VIEW_SLOT 288u',
                     '#define P2_XR_PREDICTED_VIEWMODEL_VTABLE_RVA 0x7400u', '#define P2_XR_SET_LOCAL_ANGLES_RVA 0x9100u'):
            self.assertIn(line, source)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple clang required')
    def test_headers_compile(self):
        program = ('#include "xr-profile.h"\n#include <stddef.h>\n'
                   'size_t probe(void) { size_t n = sizeof(p2_xr_render_signature) + P2_XR_VIEW_SETUP_SIZE;\n'
                   '#if P2_XR_HEAD_AIM_PROFILE\n'
                   ' n += sizeof(P2_XR_ENGINE_CLIENT_INTERFACE) + sizeof(p2_xr_get_view_angles_signature) +\n'
                   '  sizeof(p2_xr_set_view_angles_signature) + P2_XR_GET_VIEW_ANGLES_SLOT + P2_XR_SET_VIEW_ANGLES_RVA;\n'
                   '#endif\n'
                   '#if P2_XR_PORTAL_AIM_PROFILE\n'
                   ' n += sizeof(p2_xr_server_trace_signature) + sizeof(p2_xr_server_trace_call_site) +\n'
                   '  P2_XR_SERVER_TRACE_FIRE_PORTAL_RVA + P2_XR_SERVER_TRACE_FIRE_PORTAL_RETURN_RVA + P2_XR_PORTAL_PLACED_BY_PLAYER;\n'
                   '#endif\n'
                   '#if P2_XR_CLIENT_PORTAL_AIM_PROFILE\n'
                   ' n += sizeof(p2_xr_client_trace_signature) + sizeof(p2_xr_client_trace_call_site) +\n'
                   '  P2_XR_CLIENT_TRACE_FIRE_PORTAL_RVA + P2_XR_CLIENT_TRACE_FIRE_PORTAL_RETURN_RVA;\n'
                   '#endif\n'
                   '#if P2_XR_VIEWMODEL_PROFILE\n'
                   ' n += sizeof(p2_xr_calc_viewmodel_view_signature) + sizeof(p2_xr_set_local_origin_signature) +\n'
                   '  sizeof(p2_xr_set_local_angles_signature) + P2_XR_VIEWMODEL_VTABLE_RVA + P2_XR_PREDICTED_VIEWMODEL_VTABLE_RVA +\n'
                   '  P2_XR_CALC_VIEWMODEL_VIEW_SLOT + P2_XR_CALC_VIEWMODEL_VIEW_RVA + P2_XR_SET_LOCAL_ORIGIN_RVA + P2_XR_SET_LOCAL_ANGLES_RVA;\n'
                   '#endif\n return n; }\n')
        for engine, aim in ((None, None), (ENGINE, None), (ENGINE, AIM), (None, dict(AIM, client_trace=None, viewmodel=None))):
            with tempfile.TemporaryDirectory(prefix='portal2-xr-profile-') as directory:
                visionos_hooks.write_header(Path(directory) / 'xr-profile.h', CLIENT, engine, aim)
                (Path(directory) / 'probe.c').write_text(program)
                subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fsyntax-only', '-Wall', '-Wextra', '-Werror',
                                str(Path(directory) / 'probe.c')], check=True)

    def test_server_failure_disables_all_controller_aim(self):
        messages = []
        with mock.patch.object(visionos_hooks, 'audit_server', side_effect=ValueError('Unsupported server.so SHA-256')), \
             mock.patch.object(visionos_hooks, 'derive_viewmodel') as viewmodel:
            aim = visionos_hooks.aim_profile('/nonexistent', log=messages.append)
        self.assertEqual(aim, dict(server_trace=None, client_trace=None, viewmodel=None))
        viewmodel.assert_not_called()
        self.assertIn('fail closed', messages[0])

    def test_unsupported_server_rejected(self):
        with tempfile.TemporaryDirectory(prefix='portal2-xr-server-') as directory:
            path = Path(directory) / 'server.so'
            path.write_bytes(b'\x7fELF' + bytes(60))
            with self.assertRaisesRegex(ValueError, 'Unsupported server.so SHA-256'):
                visionos_hooks.audit_server(path)

    def test_engine_failure_keeps_client_profile(self):
        messages = []
        with mock.patch.object(visionos_hooks, 'audit', return_value=CLIENT), \
             mock.patch.object(visionos_hooks, 'audit_engine', side_effect=ValueError('Unsupported engine.so SHA-256')):
            client, engine = visionos_hooks.profile('/nonexistent', log=messages.append)
        self.assertIs(client, CLIENT)
        self.assertIsNone(engine)
        self.assertIn('fail closed', messages[0])
        with mock.patch.object(visionos_hooks, 'audit', side_effect=ValueError('Unsupported client.so SHA-256')):
            with self.assertRaises(ValueError):  # the RenderView hook itself stays mandatory
                visionos_hooks.profile('/nonexistent', log=messages.append)

    def test_unsupported_engine_rejected(self):
        with tempfile.TemporaryDirectory(prefix='portal2-xr-engine-') as directory:
            path = Path(directory) / 'engine.so'
            path.write_bytes(b'\x7fELF' + bytes(60))
            with self.assertRaisesRegex(ValueError, 'Unsupported engine.so SHA-256'):
                visionos_hooks.audit_engine(path)


@unittest.skipUnless(owned_root(), 'owned Linux Portal 2 binaries not configured')
class OwnedBinaryTests(unittest.TestCase):
    def test_owned_client_profile_unchanged(self):
        result = visionos_hooks.audit(owned_root() / 'portal2/bin/linux32/client.so')
        self.assertEqual((result['vtable_rva'], result['render_view_rva']), (0x142c5a0, 0xda6230))
        self.assertFalse(result['runtime_validated'])

    def test_owned_engine_profile(self):
        result = visionos_hooks.audit_engine(owned_root() / 'bin/linux32/engine.so')
        self.assertEqual(result['interface'], 'VEngineClient015')
        self.assertEqual((result['get_view_angles_slot'], result['set_view_angles_slot']), (18, 19))
        self.assertEqual((result['vtable_rva'], result['get_view_angles_rva'], result['set_view_angles_rva']),
                         (0x74e464, 0x38ae80, 0x38bd90))
        self.assertEqual(result['view_angles_field'], 0x4a44)
        self.assertTrue(result['get_signature'].startswith(visionos_hooks.GET_VIEW_ANGLES_PREFIX.hex()))
        self.assertTrue(result['set_signature'].startswith(visionos_hooks.SET_VIEW_ANGLES_PREFIX.hex()))
        self.assertFalse(result['runtime_validated'])

    def test_engine_derivation_rejects_tampering(self):
        path = owned_root() / 'bin/linux32/engine.so'
        get, put = 0x38ae80, 0x38bd90

        def tampered(change):
            elf = Elf(path, 0, 1)
            change(elf)
            with self.assertRaises(ValueError):
                visionos_hooks.derive_engine(elf)

        def replace(old, new):
            def change(elf):
                offset = elf.data.find(old)
                self.assertGreaterEqual(offset, 0)
                elf.data[offset:offset + len(new)] = new
            return change

        def poke(address, value):
            def change(elf):
                elf.data[elf.v2o(address)] ^= value
            return change

        tampered(replace(b'VEngineClient015\0', b'VEngineClient099\0'))
        tampered(replace(visionos_hooks.SET_VIEW_ANGLES_MESSAGE, b'X' * 13))
        tampered(poke(put + 3, 0x01))   # setter prefix
        tampered(poke(get + 19, 0x10))  # getter reads another field
        tampered(poke(get + 9, 0x01))   # getter prefix

    def test_owned_server_trace_profile(self):
        result = visionos_hooks.audit_server(owned_root() / 'portal2/bin/linux32/server.so')
        self.assertEqual(result['server_sha256'], visionos_hooks.SUPPORTED_SERVER)
        self.assertEqual((result['trace_fire_portal_rva'], result['call_rva'], result['return_rva']),
                         (SERVER_TRACE, 0x5a2c27, SERVER_RETURN))
        self.assertEqual(result['signature'], visionos_hooks.SERVER_TRACE_PREFIX.hex())
        self.assertEqual(len(bytes.fromhex(result['call_site'])), visionos_hooks.TRACE_CALL_SITE_LENGTH)
        self.assertEqual(result['placed_by_player'], 2)
        self.assertFalse(result['runtime_validated'])

    def test_owned_client_aim_profile(self):
        aim = visionos_hooks.aim_profile(owned_root(), log=self.fail)
        client = aim['client_trace']
        self.assertEqual((client['trace_fire_portal_rva'], client['call_rva'], client['return_rva']),
                         (CLIENT_TRACE, 0x8ac864, CLIENT_RETURN))
        self.assertEqual(client['signature'], visionos_hooks.CLIENT_TRACE_PREFIX.hex())
        viewmodel = aim['viewmodel']
        self.assertEqual((viewmodel['vtable_rva'], viewmodel['predicted_vtable_rva'], viewmodel['calc_viewmodel_view_slot'],
                          viewmodel['calc_viewmodel_view_rva'], viewmodel['calc_viewmodel_lag_rva'],
                          viewmodel['set_local_origin_rva'], viewmodel['set_local_angles_rva']),
                         (0x11ec41c, 0x120c404, 288, 0x79afc0, 0x79aa60, 0x999c50, 0x999d70))
        self.assertFalse(viewmodel['runtime_validated'])

    def test_trace_derivation_rejects_tampering(self):
        path = owned_root() / 'portal2/bin/linux32/server.so'
        prefix = visionos_hooks.SERVER_TRACE_PREFIX

        def tampered(change, message):
            elf = Elf(path, 0, 1)
            change(elf)
            with self.assertRaisesRegex(ValueError, message):
                visionos_hooks.derive_trace_fire_portal(elf, prefix)

        def poke(address, value):
            def change(elf):
                elf.data[elf.v2o(address)] ^= value
            return change

        def second_call(elf):  # another caller of TraceFirePortal (here, right after the real one)
            site = SERVER_RETURN + 3
            elf.data[elf.v2o(site)] = 0xe8
            struct.pack_into('<i', elf.data, elf.v2o(site) + 1, SERVER_TRACE - (site + 5))

        def stored_pointer(elf):  # its address in relocated data: a function pointer
            offset = next(o for o, kind, _ in elf.rels() if kind == 8 and elf.v2o(o) is not None)
            struct.pack_into('<I', elf.data, elf.v2o(offset), SERVER_TRACE)

        tampered(poke(SERVER_TRACE + 20, 0x01), 'Expected one TraceFirePortal signature')
        tampered(second_call, 'Expected one direct call')
        tampered(stored_pointer, 'not a direct-call-only function')
        tampered(poke(SERVER_RETURN - 6, 0x01), 'does not push this')          # push ebx -> other register
        tampered(poke(SERVER_RETURN - 22, 0x01), 'does not push this')         # push edi (placed-by) gone
        tampered(lambda elf: elf.data.__setitem__(slice(elf.v2o(0x5a2b54), elf.v2o(0x5a2b54) + 5), b'\x90' * 5),
                 'placed-by')                                                    # mov edi,1 gone

    def test_viewmodel_derivation_rejects_tampering(self):
        path = owned_root() / 'portal2/bin/linux32/client.so'

        def tampered(change, message):
            elf = Elf(path, 0, 1)
            change(elf)
            with self.assertRaisesRegex(ValueError, message):
                visionos_hooks.derive_viewmodel(elf)

        def slot(table, index, value):
            def change(elf):
                struct.pack_into('<I', elf.data, elf.v2o(table + index * 4), value)
            return change

        def poke(address, value):
            def change(elf):
                elf.data[elf.v2o(address)] ^= value
            return change

        tampered(slot(0x120c404, 288, 0x79aa00), 'do not share')                 # predicted class overrides it
        tampered(poke(0x79aa60, 0x01), 'not CalcViewModelLag')                    # slot layout moved
        tampered(poke(0x79afc0 + 13, 0x01), 'entry signature')                     # reads other arguments
        tampered(poke(0x79b294 + 2, 0x04), 'does not call CalcViewModelLag')       # lag call through another slot
        tampered(poke(0x999d70 + 0x5c, 0x03), 'SetLocalAngles')                    # invalidates other flags


if __name__ == '__main__':
    unittest.main()
