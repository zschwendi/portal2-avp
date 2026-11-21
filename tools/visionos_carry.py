"""Stage exact held-object call sites in two Vision-only copies of lifted C."""
from dataclasses import dataclass
from pathlib import Path
import struct

from elfprep import Elf
from visionos_hooks import SUPPORTED_CLIENT, SUPPORTED_SERVER, _code, _no_relocation, _sha256


MODULES = {
    'client.so': (0x15500000, SUPPORTED_CLIENT),
    'server.so': (0x17500000, SUPPORTED_SERVER),
}


@dataclass(frozen=True)
class Site:
    name: str
    module: str
    function: int
    rva: int
    signature_rva: int
    signature: str
    callback: str = 'target'
    instruction: str = ''

    @property
    def address(self):
        return MODULES[self.module][0] + self.rva

    def anchor(self, code):
        if self.instruction:
            return self.instruction
        if code[0] != 0xe8:
            raise ValueError(f'{self.name} is no longer a direct i386 call')
        continuation = self.address + 5
        callee = continuation + struct.unpack_from('<i', code, 1)[0]
        return (f'c->flags = f; rt_call_fn(c, fn_{callee:08x}, 0x{callee:08x}u, 0x{continuation:08x}u); '
                f'if (c->eip != 0x{continuation:08x}u) goto resume; goto L{continuation:08x};')


SITES = (
    Site('server_target', 'server.so', 0x5aeb10, 0x5af4c2, 0x5af4b5,
         '680b4000008db4245c01000056e839affdff'),
    Site('client_target', 'client.so', 0x8b7c10, 0x8b83e9, 0x8b83dc,
         '680b4000008db4245c01000056e8d223feff'),
    Site('server_vm_target', 'server.so', 0x5ae050, 0x5ae409, 0x5ae3fc,
         '680b4000028d84242c01000050e8f2bffdff'),
    Site('client_vm_target', 'client.so', 0x8b9b10, 0x8b9f3a, 0x8b9f34,
         '680b40000250e88108fefff30f10b538'),
    Site('server_attach', 'server.so', 0x5ab8a0, 0x5ab9a1, 0x5ab99c,
         'e82febffff8bbb302400008b87e4080000',
         'lifecycle',
         'c->edi = (uint32_t)(R32((uint32_t)(0u+c->ebx+0x2430u))); goto L17aab9a7;'),
    Site('server_detach', 'server.so', 0x5b1e80, 0x5b1e80, 0x5b1e80,
         '5557565381ec4c1000008bbc24601000008bb42464100000',
         'lifecycle',
         'a = ((c->ebp >> 0) & 0xffffffffu); PUSH(c, a); goto L17ab1e81;'),
    Site('server_angles', 'server.so', 0x5aeb10, 0x5afb06, 0x5afafa,
         '83ec088d8424080100005056e885c55b0083c40c', 'angles'),
    Site('client_angles', 'client.so', 0x8b7c10, 0x8b8942, 0x8b8936,
         '83ec088d8424080100005056e879e0570083c40c', 'angles'),
    Site('server_vm_angles', 'server.so', 0x5ae050, 0x5ae79f, 0x5ae793,
         '6a00558d8424800000005056e80cb9ffff83c410', 'angles'),
    Site('client_vm_angles', 'client.so', 0x8b9b10, 0x8ba082, 0x8ba082,
         'f30f10a398000000660fefedf30f10bb9c000000', 'angles',
         '{ uint64_t value = R32((uint32_t)(0u+c->ebx+0x98u)); '
         'c->xmm[4] = (XMM){0}; c->xmm[4].d[0] = value; } goto L15dba08a;'),
)


def _write(path, contents):
    if not path.exists() or path.read_text() != contents:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)


def _header(out, supported):
    lines = ['#pragma once', f'#define P2_XR_CARRY_PROFILE {int(supported)}']
    if supported:
        for module, (base, _) in MODULES.items():
            lines.append(f'#define P2_XR_CARRY_{Path(module).stem.upper()}_BASE 0x{base:08x}u')
        for site in SITES:
            prefix = f'P2_XR_CARRY_{site.name.upper()}'
            lines.extend((f'#define {prefix}_SITE 0x{site.address:08x}u',
                          f'#define {prefix}_RVA 0x{site.rva:x}u',
                          f'#define {prefix}_SIG_RVA 0x{site.signature_rva:x}u'))
            signature = ', '.join(f'0x{byte:02x}' for byte in bytes.fromhex(site.signature))
            lines.append(f'static const unsigned char p2_xr_carry_sig_{site.name}[] = {{{signature}}};')
    _write(Path(out) / 'xr-carry-profile.h', '\n'.join(lines) + '\n')


def disable(out):
    """A runtime-only build has no lifted sites to invoke carry hooks."""
    _header(out, False)


def _audit(linux_root, layout):
    entries = {module['name']: module for module in layout['modules']}
    for module, (base, digest) in MODULES.items():
        original_path = Path(linux_root) / 'portal2/bin/linux32' / module
        entry = entries.get(module)
        if not entry or entry['base'] != base or _sha256(original_path) != digest:
            raise ValueError(f'unsupported {module} revision or load base')
        original = Elf(original_path, 0, entry['modid'])
        prepared = Elf(entry['image'], 0, entry['modid'])
        for site in SITES:
            if site.module != module:
                continue
            signature = bytes.fromhex(site.signature)
            rva, length = site.signature_rva, len(signature)
            if _code(original, rva, length) != signature or _code(prepared, rva, length) != signature:
                raise ValueError(f'{site.name} bytes differ in the owned or relocated image')
            _no_relocation(original, ((rva, length),), site.name)


def _inject(source, shards):
    replacements = {}
    for site in SITES:
        function = MODULES[site.module][0] + site.function
        names = [name for name, functions in shards.items() if function in functions]
        if len(names) != 1:
            raise ValueError(f'expected one lifted shard for {site.name}, found {len(names)}')
        name = names[0]
        if name not in replacements:
            replacements[name] = (source / name).read_text()
        current = replacements[name]
        label = f'L{site.address:08x}: '
        offset = site.rva - site.signature_rva
        anchor = f'\n{label}{site.anchor(bytes.fromhex(site.signature)[offset:])}\n'
        if current.count(f'\n{label}') != 1 or current.count(anchor) != 1:
            raise ValueError(f'generated instruction for {site.name} differs')
        callback = f'p2_vision_carry_{site.callback}'
        replacement = f'\n{label}{callback}(c, 0x{site.address:08x}u); {anchor[1 + len(label):]}'
        replacements[name] = current.replace(anchor, replacement, 1)

    include = '#include "rt.h"\n'
    declarations = ('void p2_vision_carry_angles(CPU *, uint32_t);\n'
                    'void p2_vision_carry_target(CPU *, uint32_t);\n'
                    'void p2_vision_carry_lifecycle(CPU *, uint32_t);\n')
    for name, contents in replacements.items():
        if contents.count(include) != 1:
            raise ValueError(f'{name} is missing the lifted runtime include')
        replacements[name] = contents.replace(include, include + declarations, 1)
    return replacements


def stage(out, linux_root, layout, manifest, source):
    """Return staged replacements keyed by their original shard filename."""
    out, source = Path(out), Path(source)
    try:
        _audit(linux_root, layout)
        replacements = _inject(source, manifest['shards'])
    except (OSError, ValueError) as error:
        print(f'[vision-carry] Held-object tracking disabled: {error}', flush=True)
        disable(out)
        return {}

    staged = {name: out / 'carry-generated' / name for name in replacements}
    for name, contents in replacements.items():
        _write(staged[name], contents)
    _header(out, True)
    print(f'[vision-carry] Verified {len(SITES)} sites in {len(staged)} lifted shards', flush=True)
    return staged
