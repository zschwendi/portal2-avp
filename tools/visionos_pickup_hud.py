"""Verify the guest ABI for the Vision Pro pickup caption."""
from pathlib import Path
import struct
import tempfile

from elfprep import Elf
from visionos_hooks import SUPPORTED_CLIENT, _code, _no_relocation, _sha256, primary_vtable
from visionos_reticle import SUPPORTED_SURFACE


SUPPORTED_LOCALIZE = '5cf81780f8f890325c3e77568be9330ab198e1451ba78576d27a1d2175bca2a9'


def audit(linux_root):
    root = Path(linux_root)

    def owned(path, digest):
        if _sha256(path) != digest:
            raise ValueError(f'unsupported {path.name} revision')
        return Elf(path, 0, 1)

    client = owned(root / 'portal2/bin/linux32/client.so', SUPPORTED_CLIENT)
    surface = owned(root / 'bin/linux32/vguimatsurface.so', SUPPORTED_SURFACE)
    localize = owned(root / 'bin/linux32/localize.so', SUPPORTED_LOCALIZE)
    signatures = {}

    def check(module, address, hex_bytes, name=None):
        expected = bytes.fromhex(hex_bytes)
        if _code(module, address, len(expected)) != expected:
            raise ValueError(f'unexpected instruction at {address:#x}')
        if name is not None:
            _no_relocation(module, ((address, len(expected)),), name)
            signatures[name] = expected

    # This RTTI name follows other .rodata rather than a NUL separator.
    # Validate the complete primary vtable's RTTI and its per-hint Paint slot.
    table, target_slot = 0x12c0c0c, 0x3b4
    typeinfo = client.u32(table - 4)
    rtti = b'13CLocatorPanel\0'
    name = client.u32(typeinfo + 4)
    if client.u32(table - 8) != 0 or name != 0x12c0344 or client.data[name:name + len(rtti)] != rtti:
        raise ValueError('CLocatorPanel RTTI changed')
    target_paint = client.u32(table + target_slot)
    check(client, target_paint, '565383ec1c8b7424288b5c242c5356', 'target_paint')
    check(client, 0xb494bb, '5056ff92b4030000')  # panel, target
    check(client, 0xb476c4, '8d58018d2c9d00000000')  # UTF-32 count includes NUL
    check(client, 0xb47720, '899f50010000')  # target caption vector count
    check(client, 0xb452c0, 'ffb74401000050ff9208020000')  # target caption pointer
    check(client, 0xb4541c, 'ff5270')
    check(client, 0xb476f2, '83ec085650ff5228')  # localize Find(this, token)
    check(client, 0xb44bdf, '8dbb2801000083ec0c57e8a273e6ff')
    check(client, 0x9abf90, '83ec248b4424280fb7006689442416', 'symbol_text')

    surface_table, surface_slots = primary_vtable(surface, b'17CMatSystemSurface', 0x208 // 4 + 1)
    localize_table, localize_slots = primary_vtable(localize, b'9CLocalize', 0x28 // 4 + 1)
    find = localize_slots[0x28 // 4]
    check(localize, find, '5383ec108b5c24188b03ff74241c53ff5038', 'find')
    methods = {
        'color': (0x34, '8b442404660fefc0f30f2a'),
        'color_value': (0x38, '5756538b4424108b542414'),
        'text': (0x208, '565383ec048b5c2410807b33007423'),
        'character': (0x70, '565383ec348b5c2440807b33007449'),
        'glyph_info': (0x1b4, '8b4424048b4c240c8b542408c6412c00'),
        'draw_glyph': (0x1b8, '5756538b5c24148b742410807b2c00'),
    }
    values = {
        'target_slot': table + target_slot,
        'target_paint': target_paint,
        'surface_table': surface_table,
        'surface_global': struct.unpack('<I', _code(client, 0xb45217, 4))[0],
        'localize_table': localize_table,
        'localize_global': struct.unpack('<I', _code(client, 0xb475bb, 4))[0],
        'find': find,
        'caption': 0x144,
        'caption_count': 0x150,
        'caption_char_return': 0xb4541f,
        'icon_symbol': 0x128,
        'symbol_text': 0x9abf90,
    }
    if values['surface_global'] != 0x1999bfc or values['localize_global'] != 0x1999bf0:
        raise ValueError('client surface or localization global changed')
    for name, (slot, prefix) in methods.items():
        address = surface_slots[slot // 4]
        check(surface, address, prefix, name)
        values[name + '_slot'] = slot
        values[name] = address
    # Text position, panel translation and CharRenderInfo's vertex pointer.
    check(surface, 0x75364, '8b463489018b4638894104')
    check(surface, 0x754c7, '894308')
    check(surface, 0x7580d, '8b470c0347348945a88b4710034738')
    check(surface, 0x6a2bc, '88502f')
    return values, signatures


def write_header(path, linux_root):
    path = Path(path)
    lines = ['#pragma once']
    try:
        values, signatures = audit(linux_root)
    except (OSError, ValueError) as error:
        print(f'[vision-pickup-hud] Profile disabled: {error}', flush=True)
        lines.append('#define P2_XR_PICKUP_HUD_PROFILE 0')
    else:
        lines.append('#define P2_XR_PICKUP_HUD_PROFILE 1')
        lines.extend(f'#define P2_XR_PICKUP_HUD_{key.upper()} 0x{value:x}u'
                     for key, value in values.items())
        for key, signature in signatures.items():
            literals = ', '.join(f'0x{byte:02x}' for byte in signature)
            lines.append(f'static const unsigned char pickup_hud_sig_{key}[] = {{{literals}}};')
    source = '\n'.join(lines) + '\n'
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text() == source:
        return
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent,
                                     prefix='.xr-pickup-hud-', delete=False) as temporary:
        temporary.write(source)
    Path(temporary.name).replace(path)
