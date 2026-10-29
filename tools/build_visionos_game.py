#!/usr/bin/env python3
"""Compile the real recompiled runtime/game for visionOS. Outputs stay local.

--runtime-only audits the host closure before compiling the generated game.
The resulting archive is not an installed app or proof of immersive gameplay.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace

import build_game
import visionos_hooks

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=('sim', 'device'), default='sim')
    parser.add_argument('--jobs', type=int, default=3)
    parser.add_argument('--opt', choices=('0','1','2'), default='1')
    parser.add_argument('--runtime-only', action='store_true')
    args = parser.parse_args()
    os.chdir(ROOT)
    sdk_name, triple = ('xrsimulator', 'arm64-apple-xros2.0-simulator') if args.target == 'sim' else ('xros', 'arm64-apple-xros2.0')
    sdk = subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'], text=True).strip()
    prefix = ROOT / 'deps/visionos' / args.target
    needed = ['lib/libSDL2.a','lib/libgl4es.a','lib/libfreetype.a','lib/libopenal.a',
              'include/AL/al.h','include/GLES3/gl3.h',
              'Frameworks/libEGL.framework/libEGL','Frameworks/libGLESv2.framework/libGLESv2']
    missing = [name for name in needed if not (prefix / name).exists()]
    if missing:
        parser.error('visionOS host dependencies missing under ' + str(prefix) + ': ' + ', '.join(missing))
    # Refuse stale offsets before compiling a hook into the host. The emitted
    # header contains a short validation signature and offsets, never game C.
    config = json.loads((ROOT / 'config/local.json').read_text())
    profile = visionos_hooks.audit(Path(config['linux_root']) / 'portal2/bin/linux32/client.so')
    visionos_hooks.write_header(ROOT / 'build/visionos/xr-profile.h', profile)
    base = ['-target',triple,'-isysroot',sdk]
    runtime = [*base,'-O2','-g',*build_game.WARNINGS,'-DRT_FAST_MEMORY','-DP2_VISION_GAME=1','-Iruntime','-Iruntime/ios',
               '-Iruntime/visionos','-I' + str(prefix / 'include'),
               '-I' + str(prefix / 'include/SDL2'),'-I' + str(prefix / 'include/gl4es'),
               '-I' + str(prefix / 'include/freetype2')]
    generated = [*base,'-O' + args.opt,'-gline-tables-only',*build_game.WARNINGS,'-DRT_FAST_MEMORY','-Iruntime']
    generated_units = []
    if not args.runtime_only:
        layout = Path('build/game/prep/layout.json')
        data = json.loads(layout.read_text())
        manifest, _ = build_game.generate(SimpleNamespace(layout=layout,all=True,jobs=args.jobs), data, build_game.roots(data))
        source = Path('build/game/gen/src')
        generated_units += [(str(source / name),generated) for name in sorted(manifest['shards'])]
        generated_units.append((str(source / 'dispatch.c'),generated))
        plugins, _ = build_game.generate_plugins(Path('config/local.json'))
        generated_units += [(str(p),generated) for p in plugins]
    identity = subprocess.check_output(['clang','--version'],text=True)
    out = ROOT / 'build/visionos' / (('runtime-audit-' if args.runtime_only else 'game-') + args.target)
    out.mkdir(parents=True,exist_ok=True)
    print(f'Compiling {len(generated_units)} generated units for {triple}, runtime_only={args.runtime_only}',flush=True)
    game_objects, count, cpu = build_game.compile_units(generated_units,out/'obj',args.jobs,identity)
    # Plan host sources after the long generated-code phase. This captures
    # host edits/new units made during that phase instead of attaching a stale
    # source-cache key to code read by clang much later.
    units = [(str(p), runtime) for p in sorted(Path('runtime').glob('*.c'))]
    units += [(str(Path('runtime/ios') / name), runtime) for name in
              ('essl3.c','srgb.c','case_path.c','fontconfig_min.c','game_state.c','steam_stub.c','steam_stub_generated.c')]
    units += [('runtime/ios/gl_ios.m',runtime + ['-fobjc-arc'])]
    units += [(str(p), runtime + (['-fobjc-arc'] if p.suffix == '.m' else []))
              for p in sorted(Path('runtime/visionos').glob('*')) if p.suffix in ('.c','.m')]
    units.append(('src/main.c',runtime + ['-Dmain=p2_main']))
    print(f'Compiling {len(units)} current host/runtime units',flush=True)
    runtime_objects, runtime_count, runtime_cpu = build_game.compile_units(units,out/'obj',args.jobs,identity)
    objects = runtime_objects + game_objects
    count += runtime_count
    cpu += runtime_cpu
    archive = out / ('libportal2-runtime.a' if args.runtime_only else 'libportal2-game.a')
    response = out / ('runtime-objects.txt' if args.runtime_only else 'game-objects.txt')
    response.write_text('\n'.join(str(p) for p in objects) + '\n')
    subprocess.run(['xcrun','libtool','-static','-o',str(archive),'-filelist',str(response)],check=True)
    result = dict(target=triple,runtime_only=args.runtime_only,compiled=count,units=len(units)+len(generated_units),cpu_seconds=cpu,
                  archive=str(archive),generated_game_included=not args.runtime_only)
    (out / ('runtime-receipt.json' if args.runtime_only else 'game-receipt.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)


if __name__ == '__main__':
    main()
