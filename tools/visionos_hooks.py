#!/usr/bin/env python3
"""Audit the supported owned Linux client and derive the CViewRender hook.

Only hashes, offsets and a short validation signature are emitted, never game
code. This does not install a hook or claim the renderer has been exercised.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from elfprep import Elf

ROOT = Path(__file__).resolve().parent.parent
SUPPORTED_CLIENT = '9dd3792c3a12eeb9bfa6b6befe6340da20820287c9ac06189755515555fa8143'
RENDER_PREFIX = bytes.fromhex('5589e557565383ec648b45086a008b5d0c')


def audit(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != SUPPORTED_CLIENT:
        raise ValueError('Unsupported client.so SHA-256; refusing to infer hook offsets for a different build')
    elf = Elf(path, 0, 1)

    def address(offset):
        return next((p[2] + offset - p[1] for p in elf.loads if p[1] <= offset < p[1] + p[4]), None)

    def sites(value):
        word = struct.pack('<I', value)
        offset = 0
        while True:
            offset = elf.data.find(word, offset)
            if offset < 0:
                return
            yield offset
            offset += 1

    def executable(value):
        return any(p[6] & 1 and p[2] <= value < p[2] + p[4] for p in elf.loads)

    name_offset = elf.data.find(b'11CViewRender\0')
    if name_offset < 0:
        raise ValueError('CViewRender RTTI name is absent')
    name_address = address(name_offset)
    candidates = []
    for name_pointer in sites(name_address):
        typeinfo = address(name_pointer - 4)
        if typeinfo is None:
            continue
        for info_pointer in sites(typeinfo):
            table = address(info_pointer + 4)
            if table is None or info_pointer < 4 or struct.unpack_from('<i', elf.data, info_pointer - 4)[0] != 0:
                continue
            entries = struct.unpack_from('<12I', elf.data, info_pointer + 4)
            if all(executable(value) for value in entries):
                candidates.append((table, entries))
    if len(candidates) != 1:
        raise ValueError(f'Expected one primary CViewRender vtable, found {len(candidates)}')
    table, entries = candidates[0]
    render = entries[6]
    offset = elf.v2o(render)
    if elf.data[offset:offset + len(RENDER_PREFIX)] != RENDER_PREFIX:
        raise ValueError('RenderView entry signature mismatch')
    return dict(client_sha256=digest, vtable_rva=table, render_view_slot=6,
                render_view_rva=render, signature=RENDER_PREFIX.hex(),
                setup_size=260, fov_offset=104, origin_offset=112, angles_offset=124,
                aspect_offset=152, offcenter_top_offset=240, offcenter_flags_offset=256,
                abi_layout_source='p2sr/SourceAutoRecord src/Utils/SDK/CViewSetup.hpp',
                runtime_validated=False)


def write_header(path, result):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#pragma once\n' +
        f'#define P2_XR_CLIENT_VTABLE_RVA 0x{result["vtable_rva"]:x}u\n' +
        f'#define P2_XR_RENDER_VIEW_RVA 0x{result["render_view_rva"]:x}u\n' +
        f'#define P2_XR_VIEW_SETUP_SIZE {result["setup_size"]}u\n' +
        'static const unsigned char p2_xr_render_signature[] = {' +
        ','.join('0x'+result['signature'][i:i+2] for i in range(0,len(result['signature']),2))+'};\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT/'config/local.json')
    parser.add_argument('--out', type=Path, default=ROOT/'build/visionos/hook-audit.json')
    parser.add_argument('--header', type=Path, help='optional local validated profile header')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    result = audit(Path(config['linux_root'])/'portal2/bin/linux32/client.so')
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(result,indent=2)+'\n')
    if args.header:
        write_header(args.header, result)
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    main()
