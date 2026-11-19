"""Check the owned Portal 2 client/engine ABI used by the non-firing reticle."""
from pathlib import Path
import struct

from elfprep import Elf
from visionos_hooks import SUPPORTED_CLIENT, SUPPORTED_ENGINE, _code, _no_relocation, _sha256, primary_vtable


def audit(linux_root):
    root = Path(linux_root)
    client_path = root / 'portal2/bin/linux32/client.so'
    engine_path = root / 'bin/linux32/engine.so'
    if _sha256(client_path) != SUPPORTED_CLIENT or _sha256(engine_path) != SUPPORTED_ENGINE:
        raise ValueError('unsupported client or engine revision')
    client, engine = Elf(client_path, 0, 1), Elf(engine_path, 0, 1)

    def instruction(module, address, prefix, description):
        signature = bytes.fromhex(prefix)
        if _code(module, address, len(signature)) != signature:
            raise ValueError(f'unexpected {description} at {address:#x}')
        return signature

    def pointer_operand(address, instruction_prefix, description):
        signature = instruction(client, address, instruction_prefix, description)
        return struct.unpack('<I', _code(client, address + len(signature), 4))[0]

    def call_target(address):
        instruction(client, address, 'e8', 'direct call')
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
        signatures[name] = instruction(module, address, prefix, name)
        _no_relocation(module, ((address, len(signatures[name])),), name)
    values = {'mask': trace_mask, 'trace_global': trace_global, 'entity_list': entity_list,
              'viewmodel_weapon': weapon_handle, 'viewmodel_owner': owner_handle,
              'portal_environment': portal_environment, 'weapon_range': trace_range,
              'weapon_vtable': weapon, 'player_vtable': player, 'engine_trace_vtable': engine_trace}
    values.update({name: address for name, (_, address, _) in code.items()})
    return values, signatures


def write_header(path, linux_root):
    path = Path(path)
    lines = ['#pragma once']
    try:
        values, signatures = audit(linux_root)
    except (OSError, ValueError) as error:
        print(f'[vision-reticle] Reticle disabled: {error}', flush=True)
        lines += ['#define P2_RETICLE_PROFILE 0']
    else:
        lines += ['#define P2_RETICLE_PROFILE 1']
        lines += [f'#define P2_RETICLE_{name.upper()} 0x{value:x}u' for name, value in values.items()]
        for name, signature in signatures.items():
            literals = ', '.join(f'0x{byte:02x}' for byte in signature)
            lines.append(f'static const unsigned char p2_reticle_sig_{name}[] = {{{literals}}};')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(lines) + '\n')
