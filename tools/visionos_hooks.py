#!/usr/bin/env python3
"""Audit the supported owned Linux client/engine/server and derive the visionOS hooks.

Only hashes, offsets and short validation signatures are emitted, never game
code. This does not install a hook or claim the renderer, head aim or
controller aim has been exercised. The engine (head aim) and server
(controller portal aim) parts fail closed: without them the header disables
that feature and the stereo view keeps working.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import tempfile

from elfprep import Elf

ROOT = Path(__file__).resolve().parent.parent
SUPPORTED_CLIENT = '9dd3792c3a12eeb9bfa6b6befe6340da20820287c9ac06189755515555fa8143'
RENDER_PREFIX = bytes.fromhex('5589e557565383ec648b45086a008b5d0c')
SUPPORTED_ENGINE = '3bdd4bf75ed7e03e7795dc0ad12128ad7549852b5f15053e9d54a164df74a199'
ENGINE_CLIENT_INTERFACE = 'VEngineClient015'
# IVEngineClient GetViewAngles/SetViewAngles(QAngle &), Linux i386 cdecl with
# `this` on the stack. Slot indices agree with p2sr/SourceAutoRecord (MIT,
# 228b1668bdf5) Portal 2 offsets; everything below re-derives them from the
# owned binary rather than trusting them.
GET_VIEW_ANGLES_SLOT, SET_VIEW_ANGLES_SLOT = 18, 19
# push ebx; sub esp,0x14; mov ebx,[esp+0x20] (QAngle*); push -1 (active
# split-screen slot); call: then three movss loads from the client state.
GET_VIEW_ANGLES_PREFIX = bytes.fromhex('5383ec148b5c24206affe8')
# push edi; mov edx,0x7f800000 (Inf/NaN exponent test of each component).
SET_VIEW_ANGLES_PREFIX = bytes.fromhex('57ba0000807f565383ec10')
SET_VIEW_ANGLES_MESSAGE = b'CEngineClient::SetViewAngles:  rejecting invalid value'
GET_SIGNATURE_LENGTH, SET_SIGNATURE_LENGTH, FUNCTION_SCAN = 23, 25, 0x100

# ---- Tracked controller portal aim (fail closed) ----------------------------
SUPPORTED_SERVER = 'cf5326a75931256500afc870af767c5a4bf2fc9e41ced337171e1e13cd96b6f0'
# CWeaponPortalgun::TraceFirePortal(this, const Vector &start, const Vector
# &direction, bool portal2, PortalPlacedBy_t, TracePortalPlacementData_t &),
# Linux i386 cdecl with every argument on the stack. The server prefix is the
# p2sr/SourceAutoRecord (MIT, 228b1668bdf5) Linux locator; the client keeps a
# prediction copy (C_WeaponPortalgun) compiled with other registers. Each is a
# non-virtual function reached by one direct call, so tools/lift.py
# NATIVE_OVERRIDES (not a vtable patch) rewrites its ray. These prefixes must
# equal the lifter entries (tests/test_native_overrides.py).
SERVER_TRACE_PREFIX = bytes.fromhex('5589e557568db5f4f8ffff5381ec300700008b45146a008b5d0cff7508568985d0f8ffff')
CLIENT_TRACE_PREFIX = bytes.fromhex('5589e55756538d9df4f8ffff81ec300700008b45146a008b750cff7508538985d0f8ffff')
# The six argument pushes and the call, ending at the return address:
# ..., push edi (placed-by), ..., push ebx (this), call rel32.
TRACE_CALL_SITE_LENGTH = 26
# mov edi,1 ... sbb edi,-1: placed-by = 1 + (a player owns the gun), so
# PORTAL_PLACED_BY_PLAYER is 2 (1 is a pedestal).
PLACED_BY_SELECTOR = (bytes.fromhex('bf01000000'), bytes.fromhex('83dfff'))
PORTAL_PLACED_BY_PLAYER = 2
# C_BaseViewModel::CalcViewModelView(this, owner, const Vector &eye, const
# QAngle &angles), shared by C_PredictedViewModel; C_BasePlayer calls it
# through this slot. Slot 287 is CalcViewModelLag, identified by
# SourceAutoRecord's (MIT) Linux signature.
VIEWMODEL_CLASSES = (b'15C_BaseViewModel', b'20C_PredictedViewModel')
CALC_VIEWMODEL_LAG_SLOT, CALC_VIEWMODEL_VIEW_SLOT = 287, 288
# push ebp; mov ebp,esp; push edi/esi/ebx; sub esp,0x8c;
# mov edx,[ebp+0x14] (angles); mov eax,[ebp+0x10] (eye); mov ebx,[ebp+8] (this)
CALC_VIEWMODEL_VIEW_PREFIX = bytes.fromhex('5589e557565381ec8c0000008b55148b45108b5d08')
CALC_VIEWMODEL_LAG_SIGNATURE = ('5653 83ec24 8b742430 8b5c2434 6a00 6a00 8d44241c 50 ff742444 e8???????? '
                                'a1???????? 83c410 660fefc9')
# CalcViewModelView ends SetLocalOrigin(this, &origin); SetLocalAngles(this, &angles).
VIEWMODEL_TAIL = re.compile(rb'\x57\x53\xe8(.{4})\x58\x5a\x56\x53\xe8(.{4})\x83\xc4\x10', re.S)
# push esi/ebx; sub esp,4; this; value; compare with m_vecOrigin (+0x94) or
# m_angRotation (+0xb8); InvalidatePhysicsRecursive(POSITION 1 / ANGLES 2).
SET_LOCAL_ORIGIN_PREFIX = bytes.fromhex('565383ec048b5c24108b742414f30f10060f2e8394000000')
SET_LOCAL_ANGLES_PREFIX = bytes.fromhex('565383ec048b5c24108b742414f30f10060f2e83b8000000')
SET_LOCAL_INVALIDATE = (bytes.fromhex('6a0153e8'), bytes.fromhex('6a0253e8'))
VIEWMODEL_SCAN = 0x400


def _sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _address(elf, offset):
    return next((p[2] + offset - p[1] for p in elf.loads if p[1] <= offset < p[1] + p[4]), None)


def _sites(elf, value):
    word = struct.pack('<I', value)
    offset = 0
    while True:
        offset = elf.data.find(word, offset)
        if offset < 0:
            return
        yield offset
        offset += 1


def _executable(elf, value):
    return any(p[6] & 1 and p[2] <= value < p[2] + p[4] for p in elf.loads)


def primary_vtable(elf, rtti_name, entries):
    """The one vtable with offset-to-top 0 for an RTTI name, and its first entries."""
    name_offset = elf.data.find(rtti_name + b'\0')
    while name_offset > 0 and elf.data[name_offset - 1] != 0:
        name_offset = elf.data.find(rtti_name + b'\0', name_offset + 1)
    if name_offset < 0:
        raise ValueError(f'{rtti_name.decode()} RTTI name is absent')
    name_address = _address(elf, name_offset)
    if name_address is None:
        raise ValueError(f'{rtti_name.decode()} RTTI name is not loaded')
    candidates = []
    for name_pointer in _sites(elf, name_address):
        typeinfo = _address(elf, name_pointer - 4)
        if typeinfo is None:
            continue
        for info_pointer in _sites(elf, typeinfo):
            table = _address(elf, info_pointer + 4)
            if table is None or info_pointer < 4 or struct.unpack_from('<i', elf.data, info_pointer - 4)[0] != 0:
                continue
            values = struct.unpack_from(f'<{entries}I', elf.data, info_pointer + 4)
            if all(_executable(elf, value) for value in values):
                candidates.append((table, values))
    if len(candidates) != 1:
        raise ValueError(f'Expected one primary {rtti_name.decode()} vtable, found {len(candidates)}')
    return candidates[0]


def audit(path):
    digest = _sha256(path)
    if digest != SUPPORTED_CLIENT:
        raise ValueError('Unsupported client.so SHA-256; refusing to infer hook offsets for a different build')
    elf = Elf(path, 0, 1)
    table, entries = primary_vtable(elf, b'11CViewRender', 12)
    render = entries[6]
    offset = elf.v2o(render)
    if elf.data[offset:offset + len(RENDER_PREFIX)] != RENDER_PREFIX:
        raise ValueError('RenderView entry signature mismatch')
    return dict(client_sha256=digest, vtable_rva=table, render_view_slot=6,
                render_view_rva=render, signature=RENDER_PREFIX.hex(),
                setup_size=260, fov_offset=104, origin_offset=112, angles_offset=124,
                aspect_offset=152, offcenter_top_offset=240, offcenter_flags_offset=256,
                abi_layout_source='p2sr/SourceAutoRecord src/Utils/SDK/CViewSetup.hpp',
                # fov: horizontal across the full width at aspect = width/height
                # (runtime log: 93.695 for 90-at-4:3 on 1024x720, aspect 1.422).
                fov_semantics='horizontal_full_width',
                runtime_validated=False)


def derive_engine(elf):
    """Head-aim entries from engine.so bytes; raises ValueError on any doubt."""
    if elf.data.find(ENGINE_CLIENT_INTERFACE.encode() + b'\0') < 0:
        raise ValueError(f'{ENGINE_CLIENT_INTERFACE} interface name is absent')
    table, entries = primary_vtable(elf, b'13CEngineClient', SET_VIEW_ANGLES_SLOT + 1)
    get, put = entries[GET_VIEW_ANGLES_SLOT], entries[SET_VIEW_ANGLES_SLOT]
    get_code = bytes(elf.data[elf.v2o(get):elf.v2o(get) + FUNCTION_SCAN])
    set_code = bytes(elf.data[elf.v2o(put):elf.v2o(put) + FUNCTION_SCAN])
    if not get_code.startswith(GET_VIEW_ANGLES_PREFIX) or not set_code.startswith(SET_VIEW_ANGLES_PREFIX):
        raise ValueError('GetViewAngles/SetViewAngles entry signature mismatch')
    # Getter: movss xmm0,[eax+field] right after the client-state call.
    if get_code[15:19] != bytes.fromhex('f30f1080'):
        raise ValueError('GetViewAngles does not load the client view angles')
    field = struct.unpack_from('<I', get_code, 19)[0]
    for code, name in ((get_code, 'GetViewAngles'), (set_code, 'SetViewAngles')):
        if any(struct.pack('<I', field + 4 * i) not in code for i in range(3)):
            raise ValueError(f'{name} does not access the shared QAngle field {field:#x}')
    message = elf.data.find(SET_VIEW_ANGLES_MESSAGE)
    if message < 0 or b'\x68' + struct.pack('<I', _address(elf, message)) not in set_code:
        raise ValueError('SetViewAngles does not report its own invalid-value message')
    # Signatures are compared with loaded guest memory: no relocation may
    # rewrite those bytes at load time.
    spans = ((get, GET_SIGNATURE_LENGTH), (put, SET_SIGNATURE_LENGTH))
    for offset, _, _ in elf.rels():
        if any(start - 3 <= offset < start + length for start, length in spans):
            raise ValueError(f'Relocation at {offset:#x} inside a view-angle signature')
    return dict(interface=ENGINE_CLIENT_INTERFACE, vtable_rva=table,
                get_view_angles_slot=GET_VIEW_ANGLES_SLOT, set_view_angles_slot=SET_VIEW_ANGLES_SLOT,
                get_view_angles_rva=get, set_view_angles_rva=put, view_angles_field=field,
                get_signature=get_code[:GET_SIGNATURE_LENGTH].hex(),
                set_signature=set_code[:SET_SIGNATURE_LENGTH].hex(),
                slot_source='p2sr/SourceAutoRecord (MIT) Portal 2 offsets, re-derived locally',
                runtime_validated=False)


def audit_engine(path):
    digest = _sha256(path)
    if digest != SUPPORTED_ENGINE:
        raise ValueError('Unsupported engine.so SHA-256; refusing to infer head-aim offsets for a different build')
    return dict(engine_sha256=digest, **derive_engine(Elf(path, 0, 1)))


def _code_ranges(elf):
    return [(p[1], p[1] + p[4], p[2]) for p in elf.loads if p[6] & 1]


def _code(elf, address, length):
    offset = elf.v2o(address)
    if offset is None or not _executable(elf, address) or not _executable(elf, address + length - 1):
        raise ValueError(f'{address:#x} is not loaded code')
    return bytes(elf.data[offset:offset + length])


def _code_matches(elf, pattern):
    """Loaded code addresses where a byte string or compiled regex matches."""
    found = []
    for start, end, address in _code_ranges(elf):
        if isinstance(pattern, bytes):
            offset = elf.data.find(pattern, start, end)
            while offset >= 0:
                found.append(address + offset - start)
                offset = elf.data.find(pattern, offset + 1, end)
        else:
            found += [address + m.start() for m in pattern.finditer(elf.data, start, end)]
    return found


def _direct_branches(elf, target):
    """Every call/jmp rel32 in loaded code that lands on target, as (site, opcode)."""
    found = []
    data = elf.data
    for start, end, address in _code_ranges(elf):
        for opcode in (0xe8, 0xe9):
            offset = data.find(opcode, start, end - 4)
            while offset >= 0:
                relative = struct.unpack_from('<i', data, offset + 1)[0]
                if address + offset - start + 5 + relative == target:
                    found.append((address + offset - start, opcode))
                offset = data.find(opcode, offset + 1, end - 4)
    return sorted(found)


def _no_relocation(elf, spans, what):
    """Signatures are compared with loaded guest memory: no relocation may rewrite them."""
    for offset, _, _ in _relocations(elf):
        if any(start - 3 <= offset < start + length for start, length in spans):
            raise ValueError(f'Relocation at {offset:#x} inside the {what} signature')


def _relocations(elf):
    if not hasattr(elf, '_relocation_cache'):
        elf._relocation_cache = elf.rels()
    return elf._relocation_cache


def _not_address_taken(elf, target, what):
    """A non-virtual function: no relocated word, symbol or GOT offset names it.
    (A raw byte match without a relocation, e.g. inside a call rel32, is not a
    pointer in a shared object.)"""
    for offset, kind, _ in _relocations(elf):
        location = elf.v2o(offset)
        if kind in (1, 8) and location is not None and struct.unpack_from('<I', elf.data, location)[0] == target:
            raise ValueError(f'{what} address is stored at {offset:#x}: not a direct-call-only function')
    if any(symbol['value'] == target for symbol in elf.dynsyms + elf.symtab):
        raise ValueError(f'{what} has a symbol: other modules could call it')
    got = elf.dyn.get(3)
    if got is not None and _code_matches(elf, struct.pack('<i', target - got)):
        raise ValueError(f'{what} may be addressed relative to the GOT')


def derive_trace_fire_portal(elf, prefix):
    """TraceFirePortal entry, its single caller and that caller's argument pushes."""
    entries = _code_matches(elf, prefix)
    if len(entries) != 1:
        raise ValueError(f'Expected one TraceFirePortal signature, found {len(entries)}')
    entry = entries[0]
    _not_address_taken(elf, entry, 'TraceFirePortal')
    branches = _direct_branches(elf, entry)
    if len(branches) != 1 or branches[0][1] != 0xe8:
        raise ValueError(f'Expected one direct call to TraceFirePortal, found {len(branches)} branches')
    site = branches[0][0]
    back = site + 5
    call_site = _code(elf, back - TRACE_CALL_SITE_LENGTH, TRACE_CALL_SITE_LENGTH)
    if call_site[-6:-5] != b'\x53' or b'\x57' not in call_site[:-6]:
        raise ValueError('TraceFirePortal caller does not push this (ebx) and placed-by (edi)')
    selector = _code(elf, back - TRACE_CALL_SITE_LENGTH - FUNCTION_SCAN, FUNCTION_SCAN)
    if not all(part in selector for part in PLACED_BY_SELECTOR):
        raise ValueError('TraceFirePortal caller does not select placed-by as 1 + player')
    _no_relocation(elf, ((entry, len(prefix)), (back - TRACE_CALL_SITE_LENGTH, TRACE_CALL_SITE_LENGTH)), 'TraceFirePortal')
    return dict(trace_fire_portal_rva=entry, call_rva=site, return_rva=back,
                signature=prefix.hex(), call_site=call_site.hex(),
                placed_by_player=PORTAL_PLACED_BY_PLAYER, runtime_validated=False)


def audit_server(path):
    digest = _sha256(path)
    if digest != SUPPORTED_SERVER:
        raise ValueError('Unsupported server.so SHA-256; refusing to infer the portal trace for a different build')
    return dict(server_sha256=digest, **derive_trace_fire_portal(Elf(path, 0, 1), SERVER_TRACE_PREFIX),
                slot_source='p2sr/SourceAutoRecord (MIT) Linux TraceFirePortal locator, re-derived locally')


def class_vtable(elf, rtti_name, entries):
    """Primary vtable of an RTTI class name. Unlike primary_vtable, accepts a
    name the linker tail-merged into a longer string (e.g. a pointer type)."""
    candidates = []
    offset = elf.data.find(rtti_name + b'\0')
    while offset >= 0:
        name_address = _address(elf, offset)
        for name_pointer in (_sites(elf, name_address) if name_address is not None else ()):
            typeinfo = _address(elf, name_pointer - 4)
            for info_pointer in (_sites(elf, typeinfo) if typeinfo is not None else ()):
                table = _address(elf, info_pointer + 4)
                if table is None or info_pointer < 4 or struct.unpack_from('<i', elf.data, info_pointer - 4)[0] != 0:
                    continue
                values = struct.unpack_from(f'<{entries}I', elf.data, info_pointer + 4)
                if all(_executable(elf, value) for value in values):
                    candidates.append((table, values))
        offset = elf.data.find(rtti_name + b'\0', offset + 1)
    if len(candidates) != 1:
        raise ValueError(f'Expected one primary {rtti_name.decode()} vtable, found {len(candidates)}')
    return candidates[0]


def _signature_regex(text):
    hexadecimal = text.replace(' ', '')
    return re.compile(b''.join(b'.' if hexadecimal[i] == '?' else re.escape(bytes.fromhex(hexadecimal[i:i + 2]))
                               for i in range(0, len(hexadecimal), 2)), re.S)


def derive_viewmodel(elf):
    """Viewmodel placement entries from client.so bytes; raises ValueError on any doubt."""
    tables = [class_vtable(elf, name, CALC_VIEWMODEL_VIEW_SLOT + 1) for name in VIEWMODEL_CLASSES]
    view = tables[0][1][CALC_VIEWMODEL_VIEW_SLOT]
    if any(entries[CALC_VIEWMODEL_VIEW_SLOT] != view for _, entries in tables):
        raise ValueError('Viewmodel classes do not share CalcViewModelView')
    lag = tables[0][1][CALC_VIEWMODEL_LAG_SLOT]
    if not _signature_regex(CALC_VIEWMODEL_LAG_SIGNATURE).match(_code(elf, lag, 64)):
        raise ValueError('Slot 287 is not CalcViewModelLag: the viewmodel slot layout differs')
    code = _code(elf, view, VIEWMODEL_SCAN)
    if not code.startswith(CALC_VIEWMODEL_VIEW_PREFIX):
        raise ValueError('CalcViewModelView entry signature mismatch')
    if b'\xff\x90' + struct.pack('<I', CALC_VIEWMODEL_LAG_SLOT * 4) not in code:
        raise ValueError('CalcViewModelView does not call CalcViewModelLag through its slot')
    tails = list(VIEWMODEL_TAIL.finditer(code))
    if len(tails) != 1:
        raise ValueError('CalcViewModelView does not end by setting the local origin and angles')
    tail = view + tails[0].start()
    set_origin = tail + 7 + struct.unpack('<i', tails[0][1])[0]
    set_angles = tail + 16 + struct.unpack('<i', tails[0][2])[0]
    for address, prefix, invalidate, name in ((set_origin, SET_LOCAL_ORIGIN_PREFIX, SET_LOCAL_INVALIDATE[0], 'SetLocalOrigin'),
                                              (set_angles, SET_LOCAL_ANGLES_PREFIX, SET_LOCAL_INVALIDATE[1], 'SetLocalAngles')):
        body = _code(elf, address, 0x60)
        if not body.startswith(prefix) or invalidate not in body:
            raise ValueError(f'{name} signature mismatch')
    _no_relocation(elf, ((view, len(CALC_VIEWMODEL_VIEW_PREFIX)), (set_origin, len(SET_LOCAL_ORIGIN_PREFIX)),
                         (set_angles, len(SET_LOCAL_ANGLES_PREFIX))), 'viewmodel')
    return dict(vtable_rva=tables[0][0], predicted_vtable_rva=tables[1][0],
                calc_viewmodel_view_slot=CALC_VIEWMODEL_VIEW_SLOT, calc_viewmodel_view_rva=view,
                calc_viewmodel_lag_rva=lag, set_local_origin_rva=set_origin, set_local_angles_rva=set_angles,
                view_signature=CALC_VIEWMODEL_VIEW_PREFIX.hex(), set_origin_signature=SET_LOCAL_ORIGIN_PREFIX.hex(),
                set_angles_signature=SET_LOCAL_ANGLES_PREFIX.hex(),
                slot_source='RTTI vtables; slot 287 by p2sr/SourceAutoRecord (MIT) CalcViewModelLag Linux signature',
                runtime_validated=False)


def aim_profile(linux_root, log=print):
    """Fail-closed controller-aim entries. The server trace gates everything:
    without it portals keep following the head, so neither the client
    prediction copy nor the viewmodel may move to the controller."""
    root = Path(linux_root)
    result = dict(server_trace=None, client_trace=None, viewmodel=None)
    try:
        result['server_trace'] = audit_server(root / 'portal2/bin/linux32/server.so')
        client = root / 'portal2/bin/linux32/client.so'
        if _sha256(client) != SUPPORTED_CLIENT:
            raise ValueError('Unsupported client.so SHA-256')
        elf = Elf(client, 0, 1)
    except (OSError, ValueError) as error:
        log(f'[visionos-hooks] Controller portal aim disabled (fail closed): {error}')
        return dict(server_trace=None, client_trace=None, viewmodel=None)
    for key, what, derive in (('client_trace', 'Client portal-trace prediction aim',
                               lambda: derive_trace_fire_portal(elf, CLIENT_TRACE_PREFIX)),
                              ('viewmodel', 'Viewmodel at the controller', lambda: derive_viewmodel(elf))):
        try:
            result[key] = derive()
        except (OSError, ValueError) as error:
            log(f'[visionos-hooks] {what} disabled (fail closed): {error}')
    return result


def profile(linux_root, log=print):
    """Required client profile plus the fail-closed engine (head aim) profile."""
    client = audit(Path(linux_root) / 'portal2/bin/linux32/client.so')
    try:
        engine = audit_engine(Path(linux_root) / 'bin/linux32/engine.so')
    except (OSError, ValueError) as error:
        log(f'[visionos-hooks] Head aim disabled (fail closed): {error}')
        engine = None
    return client, engine


def _bytes(name, text):
    return (f'static const unsigned char {name}[] = {{' +
            ','.join('0x' + text[i:i + 2] for i in range(0, len(text), 2)) + '};\n')


def header_source(result, engine=None, aim=None):
    source = ('#pragma once\n' +
        f'#define P2_XR_CLIENT_VTABLE_RVA 0x{result["vtable_rva"]:x}u\n' +
        f'#define P2_XR_RENDER_VIEW_RVA 0x{result["render_view_rva"]:x}u\n' +
        f'#define P2_XR_VIEW_SETUP_SIZE {result["setup_size"]}u\n' +
        _bytes('p2_xr_render_signature', result['signature']))
    if not engine:
        source += '#define P2_XR_HEAD_AIM_PROFILE 0 /* engine.so audit failed: head aim off */\n'
    else:
        source += ('#define P2_XR_HEAD_AIM_PROFILE 1\n' +
            f'#define P2_XR_ENGINE_CLIENT_INTERFACE "{engine["interface"]}"\n' +
            f'#define P2_XR_ENGINE_CLIENT_VTABLE_RVA 0x{engine["vtable_rva"]:x}u\n' +
            f'#define P2_XR_GET_VIEW_ANGLES_SLOT {engine["get_view_angles_slot"]}u\n' +
            f'#define P2_XR_SET_VIEW_ANGLES_SLOT {engine["set_view_angles_slot"]}u\n' +
            f'#define P2_XR_GET_VIEW_ANGLES_RVA 0x{engine["get_view_angles_rva"]:x}u\n' +
            f'#define P2_XR_SET_VIEW_ANGLES_RVA 0x{engine["set_view_angles_rva"]:x}u\n' +
            _bytes('p2_xr_get_view_angles_signature', engine['get_signature']) +
            _bytes('p2_xr_set_view_angles_signature', engine['set_signature']))
    return source + aim_header_source(aim)


def aim_header_source(aim):
    """Controller-aim part of the profile header; every piece fails closed."""
    aim = aim or {}
    server = aim.get('server_trace')
    if not server:
        return ('#define P2_XR_PORTAL_AIM_PROFILE 0 /* server.so audit failed: portals follow the head */\n'
                '#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 0\n#define P2_XR_VIEWMODEL_PROFILE 0\n')
    source = ('#define P2_XR_PORTAL_AIM_PROFILE 1\n' +
        f'#define P2_XR_PORTAL_PLACED_BY_PLAYER {server["placed_by_player"]}u\n' +
        f'#define P2_XR_SERVER_TRACE_FIRE_PORTAL_RVA 0x{server["trace_fire_portal_rva"]:x}u\n' +
        f'#define P2_XR_SERVER_TRACE_FIRE_PORTAL_RETURN_RVA 0x{server["return_rva"]:x}u\n' +
        _bytes('p2_xr_server_trace_signature', server['signature']) +
        _bytes('p2_xr_server_trace_call_site', server['call_site']))
    client = aim.get('client_trace')
    if client:
        source += ('#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 1\n' +
            f'#define P2_XR_CLIENT_TRACE_FIRE_PORTAL_RVA 0x{client["trace_fire_portal_rva"]:x}u\n' +
            f'#define P2_XR_CLIENT_TRACE_FIRE_PORTAL_RETURN_RVA 0x{client["return_rva"]:x}u\n' +
            _bytes('p2_xr_client_trace_signature', client['signature']) +
            _bytes('p2_xr_client_trace_call_site', client['call_site']))
    else:
        source += '#define P2_XR_CLIENT_PORTAL_AIM_PROFILE 0 /* client prediction keeps the head ray */\n'
    viewmodel = aim.get('viewmodel')
    if not viewmodel:
        return source + '#define P2_XR_VIEWMODEL_PROFILE 0 /* viewmodel stays head-locked */\n'
    return (source + '#define P2_XR_VIEWMODEL_PROFILE 1\n' +
        f'#define P2_XR_VIEWMODEL_VTABLE_RVA 0x{viewmodel["vtable_rva"]:x}u\n' +
        f'#define P2_XR_PREDICTED_VIEWMODEL_VTABLE_RVA 0x{viewmodel["predicted_vtable_rva"]:x}u\n' +
        f'#define P2_XR_CALC_VIEWMODEL_VIEW_SLOT {viewmodel["calc_viewmodel_view_slot"]}u\n' +
        f'#define P2_XR_CALC_VIEWMODEL_VIEW_RVA 0x{viewmodel["calc_viewmodel_view_rva"]:x}u\n' +
        f'#define P2_XR_SET_LOCAL_ORIGIN_RVA 0x{viewmodel["set_local_origin_rva"]:x}u\n' +
        f'#define P2_XR_SET_LOCAL_ANGLES_RVA 0x{viewmodel["set_local_angles_rva"]:x}u\n' +
        _bytes('p2_xr_calc_viewmodel_view_signature', viewmodel['view_signature']) +
        _bytes('p2_xr_set_local_origin_signature', viewmodel['set_origin_signature']) +
        _bytes('p2_xr_set_local_angles_signature', viewmodel['set_angles_signature']))


def write_header(path, result, engine=None, aim=None):
    source = header_source(result, engine, aim)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text() == source:
        return
    with tempfile.NamedTemporaryFile(mode='w',dir=path.parent,prefix='.xr-profile-',delete=False) as temporary:
        temporary.write(source)
    Path(temporary.name).replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT/'config/local.json')
    parser.add_argument('--out', type=Path, default=ROOT/'build/visionos/hook-audit.json')
    parser.add_argument('--header', type=Path, help='optional local validated profile header')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    result, engine = profile(config['linux_root'])
    aim = aim_profile(config['linux_root'])
    report = dict(result, engine=engine or dict(head_aim=False),
                  controller_aim={key: value or dict(enabled=False) for key, value in aim.items()})
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(report,indent=2)+'\n')
    if args.header:
        write_header(args.header, result, engine, aim)
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
