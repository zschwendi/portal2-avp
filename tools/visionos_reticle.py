"""Check the owned Portal 2 guest ABI used by the tracked reticle and stock HUD."""
from pathlib import Path
import struct

from elfprep import Elf
from visionos_hooks import SUPPORTED_CLIENT, SUPPORTED_ENGINE, _code, _no_relocation, _sha256, primary_vtable


SUPPORTED_SURFACE = 'b1eee93d49c743188d7a8bc9a30345fb0ff6d8a1eec77e5528216999ea64c1cd'


def _instruction(module, address, prefix, description):
    signature = bytes.fromhex(prefix)
    if _code(module, address, len(signature)) != signature:
        raise ValueError(f'unexpected {description} at {address:#x}')
    return signature


def audit(linux_root):
    root = Path(linux_root)
    client_path = root / 'portal2/bin/linux32/client.so'
    engine_path = root / 'bin/linux32/engine.so'
    if _sha256(client_path) != SUPPORTED_CLIENT or _sha256(engine_path) != SUPPORTED_ENGINE:
        raise ValueError('unsupported client or engine revision')
    client, engine = Elf(client_path, 0, 1), Elf(engine_path, 0, 1)

    def pointer_operand(address, instruction_prefix, description):
        signature = _instruction(client, address, instruction_prefix, description)
        return struct.unpack('<I', _code(client, address + len(signature), 4))[0]

    def call_target(address):
        _instruction(client, address, 'e8', 'direct call')
        return address + 5 + struct.unpack('<i', _code(client, address + 1, 4))[0]

    portal_query = call_target(0x8abf87)
    filter_constructor = call_target(0x8abe84)
    filter_setup = call_target(0x8abe8c)
    trace_mask = pointer_operand(0x8abf81, '68', 'portal shot collision mask')
    trace_global = pointer_operand(0x892f7b, 'a1', 'client engine trace interface')
    entity_list = pointer_operand(0x79b143, '8b0d', 'client entity list')
    weapon_handle = pointer_operand(0x79b13d, '8b83', 'viewmodel weapon handle')
    owner_handle = pointer_operand(0x79b1df, '8b83', 'viewmodel owner handle')
    portal_environment = pointer_operand(0x8acb49, '8b86', 'player portal environment handle')
    trace_range = pointer_operand(0x8abecb, 'f30f1088', 'portal gun trace range')
    weapon, _ = primary_vtable(client, b'17C_WeaponPortalgun', 6)
    player, slots = primary_vtable(client, b'15C_Portal_Player', 0x4e8 // 4 + 1)
    shoot_position = slots[0x4e8 // 4]
    engine_trace, slots = primary_vtable(engine, b'18CEngineTraceClient', 6)
    trace_ray = slots[5]
    if b'EngineTraceClient004\0' not in engine.data:
        raise ValueError('EngineTraceClient004 is missing')

    code = {
        'query': (client, portal_query, '5589e55731ff565381ec8c0000008b55148b750885d2'),
        'filter_ctor': (client, filter_constructor, '8b4424048b542408c7400c000000008950048b54240c'),
        'filter_setup': (client, filter_setup, '5383ec108b5c2418'),
        'shoot_position': (client, shoot_position, '5383ec108b44241c8b5c24188b105053ff924c03000089d883c4145bc20400'),
        'trace_ray': (engine, trace_ray, '5589e557565381ecec1000008b5d08'),
    }
    signatures = {}
    for name, (module, address, prefix) in code.items():
        signatures[name] = _instruction(module, address, prefix, name)
        _no_relocation(module, ((address, len(signatures[name])),), name)
    values = {'mask': trace_mask, 'trace_global': trace_global, 'entity_list': entity_list,
              'viewmodel_weapon': weapon_handle, 'viewmodel_owner': owner_handle,
              'portal_environment': portal_environment, 'weapon_range': trace_range,
              'weapon_vtable': weapon, 'player_vtable': player, 'engine_trace_vtable': engine_trace}
    values.update({name: address for name, (_, address, _) in code.items()})
    return values, signatures


def audit_hud_surface(linux_root):
    root = Path(linux_root)
    client_path = root / 'portal2/bin/linux32/client.so'
    surface_path = root / 'bin/linux32/vguimatsurface.so'
    if _sha256(client_path) != SUPPORTED_CLIENT or _sha256(surface_path) != SUPPORTED_SURFACE:
        raise ValueError('unsupported client or VGUI material surface revision')
    client, surface = Elf(client_path, 0, 1), Elf(surface_path, 0, 1)

    # GetHudSize and CHudTexture::DrawSelf load the same relocated ISurface pointer.
    _instruction(client, 0xd7ea03, 'a1', 'HUD surface load')
    _instruction(client, 0xb18af2, '8b15', 'HUD texture surface load')
    global_rva = client.u32(0xd7ea04)
    if global_rva != client.u32(0xb18af4):
        raise ValueError('HUD surface loads disagree')

    table, slots = primary_vtable(surface, b'17CMatSystemSurface', 0x1a0 // 4 + 1)
    values = {'global_rva': global_rva, 'vtable_rva': table}
    signatures = {}
    methods = {
        'filled_rect': (0x3c, '5589e557565383ec68'),
        'unicode_char': (0x70, '565383ec348b5c2440807b33007449'),
        'textured_rect': (0x9c, '57565383ec508b5c2460807b2f00751083c4'),
        'screen_size': (0xa8, '5589e55383ec148b450880b8800301000074'),
        'textured_subrect': (0x19c, '57565383ec508b5c2460807b2f00751083c4'),
        'textured_polygon': (0x1a0, '538b54240c8b5c24088b4c24108b44241485'),
    }
    for name, (slot, prefix) in methods.items():
        address = slots[slot // 4]
        values[f'{name}_slot'] = slot
        values[f'{name}_rva'] = address
        signatures[name] = _instruction(surface, address, prefix, name)
        _no_relocation(surface, ((address, len(signatures[name])),), name)

    # The five QuickInfo dots use filled rects and its crescent textures use
    # subrects. Polygons and glyphs also add these fields before clipping.
    x = _instruction(surface, 0x6fbb8, '8b530c', 'subrect x translation')[-1]
    y = _instruction(surface, 0x6fbcf, '8b4310', 'subrect y translation')[-1]
    rect_x = _instruction(surface, 0x72eee, '8b530c', 'filled rect x translation')[-1]
    rect_y = _instruction(surface, 0x72f0c, '8b4310', 'filled rect y translation')[-1]
    polygon = _instruction(surface, 0x70fba, 'ff7310ff730c', 'polygon translation')
    if (x, y) != (rect_x, rect_y) or (x, y) != (polygon[5], polygon[2]):
        raise ValueError('HUD translation fields disagree')
    values.update(translate_x=x, translate_y=y)
    return values, signatures


def write_header(path, linux_root):
    path = Path(path)
    lines = ['#pragma once']
    profiles = (('p2_reticle', 'Reticle collision', audit),
                ('p2_xr_hud_surface', 'Stock HUD translation', audit_hud_surface))
    for prefix, description, inspect in profiles:
        try:
            values, signatures = inspect(linux_root)
        except (OSError, ValueError) as error:
            print(f'[vision-reticle] {description} disabled: {error}', flush=True)
            lines.append(f'#define {prefix.upper()}_PROFILE 0')
            continue
        lines.append(f'#define {prefix.upper()}_PROFILE 1')
        lines += [f'#define {prefix.upper()}_{name.upper()} 0x{value:x}u' for name, value in values.items()]
        for name, signature in signatures.items():
            literals = ', '.join(f'0x{byte:02x}' for byte in signature)
            lines.append(f'static const unsigned char {prefix}_sig_{name}[] = {{{literals}}};')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(lines) + '\n')
