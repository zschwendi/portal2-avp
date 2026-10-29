#!/usr/bin/env python3
"""Build an offscreen GPU probe; run explicitly with simctl spawn. No game code."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    prefix = ROOT / 'deps/visionos/sim'
    app = ROOT / 'build/visionos/gl-probe/Portal2GLProbe.app'
    app.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'xrsimulator', '--show-sdk-path'], text=True).strip()
    flags = ['-target', 'arm64-apple-xros2.0-simulator', '-isysroot', sdk, '-O1', '-g',
             '-Iruntime/visionos', '-I' + str(prefix / 'include'),
             '-I' + str(prefix / 'include/SDL2'), '-I' + str(prefix / 'include/gl4es')]
    sources = ['tests/visionos_gl_probe.m', 'runtime/visionos/gl_vision.m',
               'runtime/visionos/sdl_vision.c', 'runtime/ios/gl_ios.m',
               'runtime/ios/essl3.c', 'runtime/ios/srgb.c',
               'runtime/visionos/p2_xr.c','runtime/visionos/input_vision.c']
    objects = []
    for source in sources:
        obj = app.parent / (Path(source).stem + '.o')
        subprocess.run(['xcrun', 'clang', '-c', *flags,
                        *(['-fobjc-arc'] if source.endswith('.m') else []),
                        source, '-o', str(obj)], check=True, cwd=ROOT)
        objects.append(str(obj))
    frameworks = ['Foundation','UIKit','IOSurface','Metal','QuartzCore','CoreGraphics','CoreVideo',
                  'GameController','CoreHaptics','CoreMotion','AVFoundation','AudioToolbox','CoreAudio',
                  'CoreBluetooth','CoreText']
    subprocess.run(['xcrun','clang', *flags, *objects,
                    str(prefix / 'lib/libSDL2.a'), str(prefix / 'lib/libgl4es.a'),
                    '-liconv', *[x for f in frameworks for x in ('-framework',f)],
                    '-F' + str(prefix / 'Frameworks'), '-framework','libGLESv2',
                    '-Wl,-rpath,@executable_path/Frameworks', '-o',str(app / 'probe')], check=True, cwd=ROOT)
    for name in ('libEGL','libGLESv2'):
        shutil.copytree(prefix / 'Frameworks' / (name + '.framework'),
                        app / 'Frameworks' / (name + '.framework'), dirs_exist_ok=True)
    with (app / 'Info.plist').open('wb') as stream:
        plistlib.dump(dict(CFBundleIdentifier='dev.zschwendi.portal2avp.glprobe',
                           CFBundleExecutable='probe', CFBundleName='Portal2GLProbe',
                           CFBundlePackageType='APPL'), stream)
    print(json.dumps(dict(kind='offscreen_gl_probe', game_attached=False, app=str(app),
                         executable=str(app / 'probe')), indent=2))


if __name__ == '__main__':
    main()
