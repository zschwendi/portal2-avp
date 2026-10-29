#!/usr/bin/env python3
"""Build pinned SDL2/FreeType/gl4es host dependencies for iOS or visionOS.

No Valve files are fetched. visionOS uses experimental, pinned ANGLE binaries
retargeted from iOS; the GPU probe and actual device acceptance remain required.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / 'deps/visionos'
GL4ES_COMMIT = 'a025615bc79ac43ec911dced8fe5b8eb45a0b72d'
ANGLE_COMMIT = '8e8b9a388c323af6ff7dadc19600bee7c7289d93'
ARCHIVES = {
    'SDL2-2.32.10': ('https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz',
                      '5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165'),
    'freetype-VER-2-14-3': ('https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-14-3',
                           'dc49de6b01a266eef4876a4dd34d9842c475d3e28ff2eff63bd2fb760ab56261'),
    'openal-soft-1.25.2': ('https://codeload.github.com/kcat/openal-soft/tar.gz/refs/tags/1.25.2',
                          'fb27e5839aa11f0e5b9d33756965291fad5d6909ab928ea1f796f4a1a6877894'),
}
ANGLE_HASHES = {
    'LICENSE': 'bf4da21bd20bcfb5b60b7ecc67fa864a79be049e21d6178076887f178dd6c71a',
    'xros/libEGL.framework/Info.plist': 'f99d81d672bdde1d5ba62f571cb24a50125de2b671a8421b9d88217b16668583',
    'xros/libEGL.framework/libEGL': '2c0b97395e75c38a4e0c491f45fb61d265fcdbe7241e8655f835a18e41fb6bd1',
    'xros/libGLESv2.framework/Info.plist': '904d36ed34a414ac0124b19cb397f7b0200f054a7ab331650416b706badd19e3',
    'xros/libGLESv2.framework/libGLESv2': '4dad972e8ec6e034b2af8b9446abc0c73a3e1f6392faf3be77989439a1c6d483',
    'xrsim/libEGL.framework/Info.plist': '7d8a2fbd2cdd90e47c0c3b47e0ddabb467a2fc269f62990ad5869f71aa50e5b6',
    'xrsim/libEGL.framework/libEGL': '4f0d9a68d33b0d93007db145821e91a5fe0beefbcb5d57f1929155b5da09fdb0',
    'xrsim/libGLESv2.framework/Info.plist': '00c38a285be2e6b498bfd016b8abe06064ae73127f730364805bce3dc4f5f967',
    'xrsim/libGLESv2.framework/libGLESv2': 'ca755f46b36d226325d0c9f602335dc3bab9aaadfbd35ec42287044638f5748f',
}


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def fetch(url, destination, digest):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == digest:
        return
    if destination.exists():
        raise ValueError(f'Preserving unexpected cached file with a hash mismatch: {destination}')
    temporary = destination.with_suffix(destination.suffix + '.download')
    with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as stream:
        shutil.copyfileobj(response, stream)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
        raise ValueError(f'Download hash mismatch; preserved for inspection: {temporary}')
    temporary.replace(destination)


def source(name):
    url, digest = ARCHIVES[name]
    archive = CACHE / (name + '.tar.gz')
    fetch(url, archive, digest)
    destination = CACHE / 'archive-src' / name
    if not destination.exists():
        with tarfile.open(archive) as data:
            data.extractall(destination.parent, filter='data')
    if not (destination / 'CMakeLists.txt').is_file():
        raise ValueError(f'Expected source tree missing after extraction: {destination}')
    return destination


def apply_patch(source_root, patch):
    result = subprocess.run(['patch','-C','-R','-p1','-F0','-i',str(patch)], cwd=source_root,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        run('patch','-C','-p1','-F0','-i',patch,cwd=source_root)
        run('patch','-p1','-F0','-i',patch,cwd=source_root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('visionos','ios'), default='visionos')
    parser.add_argument('--target', choices=('sim','device'), default='sim')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    if args.jobs < 1: parser.error('--jobs must be positive')
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / '.build.lock').open('w') as guard:
        try: fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: parser.error('A mobile dependency build already owns the source cache')
        build(args)


def build(args):
    vision = args.platform == 'visionos'
    sdk = ('xrsimulator' if args.target == 'sim' else 'xros') if vision else (
        'iphonesimulator' if args.target == 'sim' else 'iphoneos')
    prefix = ROOT / 'deps' / args.platform / args.target
    build_root = ROOT / 'deps' / args.platform / ('build-' + args.target)
    common = ['-G','Ninja','-DCMAKE_SYSTEM_NAME=' + ('visionOS' if vision else 'iOS'),
        '-DCMAKE_OSX_SYSROOT=' + sdk, '-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + ('2.0' if vision else '17.0'),
        '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
        '-DCMAKE_INSTALL_PREFIX=' + str(prefix)]

    def cmake(name, src, options=(), install=True):
        directory = build_root / name
        run('cmake','-S',src,'-B',directory,*common,*options)
        run('cmake','--build',directory,'--parallel',args.jobs)
        if install: run('cmake','--install',directory)
        return directory

    sdl = source('SDL2-2.32.10')
    apply_patch(sdl, ROOT / 'visionos/deps/sdl2-dummy.patch')
    options = ['-DSDL_SHARED=OFF','-DSDL_STATIC=ON','-DSDL_TEST=OFF','-DSDL_VIRTUAL_JOYSTICK=ON']
    if vision:
        options += ['-DP2_SDL_DUMMY_ONLY=ON','-DSDL_RENDER=OFF','-DSDL_OPENGLES=OFF',
            '-DSDL_OPENGL=OFF','-DSDL_METAL=OFF','-DSDL_OFFSCREEN=OFF','-DSDL_VULKAN=OFF',
            '-DSDL_HIDAPI=OFF','-DSDL_HIDAPI_JOYSTICK=OFF',
            '-DCMAKE_C_FLAGS=-DSDL_PLATFORM_VISIONOS=1','-DCMAKE_OBJC_FLAGS=-DSDL_PLATFORM_VISIONOS=1']
    cmake('SDL2',sdl,options)
    freetype = source('freetype-VER-2-14-3')
    cmake('freetype-host',freetype,['-DBUILD_SHARED_LIBS=OFF',*['-DFT_DISABLE_'+d+'=ON' for d in
          ('ZLIB','BZIP2','PNG','HARFBUZZ','BROTLI')]])
    gl4es = CACHE / 'sparse-gl4es'
    if not gl4es.exists():
        run('git','init',gl4es)
        run('git','-C',gl4es,'remote','add','origin','https://github.com/ptitSeb/gl4es.git')
        run('git','-C',gl4es,'sparse-checkout','set','src','include','system')
        run('git','-C',gl4es,'fetch','--depth=1','--filter=blob:none','origin',GL4ES_COMMIT)
        run('git','-C',gl4es,'checkout','--detach',GL4ES_COMMIT)
    head = subprocess.check_output(['git','-C',str(gl4es),'rev-parse','HEAD'],text=True).strip()
    if head != GL4ES_COMMIT: raise ValueError('Preserving gl4es cache at an unexpected revision')
    apply_patch(gl4es,ROOT/'ios/deps/gl4es-ios.patch')
    directory = cmake('gl4es-host',ROOT/'visionos/deps/gl4es',
                      ['-DP2_GL4ES_SOURCE='+str(gl4es)],install=False)
    (prefix/'lib').mkdir(parents=True,exist_ok=True)
    shutil.copyfile(directory/'out/libGL.a',prefix/'lib/libgl4es.a')
    shutil.copytree(gl4es/'include',prefix/'include/gl4es',dirs_exist_ok=True)
    notices = prefix/'licenses'
    notices.mkdir(parents=True,exist_ok=True)
    for label, src in [('SDL2',sdl/'LICENSE.txt'),('FreeType',freetype/'docs/FTL.TXT'),('gl4es',gl4es/'LICENSE')]:
        shutil.copyfile(src,notices/(label+'.txt'))
    if vision:
        openal = source('openal-soft-1.25.2')
        cmake('openal-host',ROOT/'visionos/deps/openal',['-DP2_OPENAL_SOURCE='+str(openal)])
        shutil.copyfile(openal/'COPYING',notices/'OpenAL-Soft.txt')
        for header in ('EGL','GLES2','KHR'):
            shutil.copytree(sdl/'src/video/khronos'/header,prefix/'include'/header,dirs_exist_ok=True)
        # SDL2 carries its GLES3 header under GLES2's sibling only in newer
        # snapshots. Use the Khronos-generated headers pinned in SDL3 instead.
        headers = {'gl3.h':'d2f93787d1493c0cd4ca15382b77355d1c248bb8d2af9f4f3e0a54cf6fb018c3',
                   'gl3platform.h':'a9e060dae5a2b11c5a889b679692b7089a10a7e03ebfbb6cf28217f6e322fb08'}
        for header, digest in headers.items():
            url='https://raw.githubusercontent.com/libsdl-org/SDL/147a8ee32dbf9ac02f3794964490687b6bbda1bc/src/video/khronos/GLES3/'+header
            fetch(url,prefix/'include/GLES3'/header,digest)
        platform = 'xrsim' if args.target == 'sim' else 'xros'
        base='https://raw.githubusercontent.com/zschwendi/avp-craft/'+ANGLE_COMMIT+'/vendor/out/'
        for name, digest in ANGLE_HASHES.items():
            if name == 'LICENSE': target=notices/'ANGLE.txt'
            elif name.startswith(platform+'/'): target=prefix/'Frameworks'/name.removeprefix(platform+'/')
            else: continue
            fetch(base+name,target,digest)
    receipt=dict(platform=args.platform,target=args.target,sdk=sdk,prefix=str(prefix),
                 gl4es_commit=GL4ES_COMMIT,angle_commit=ANGLE_COMMIT if vision else None,
                 angle_retargeted_from_ios=vision,gameplay_verified=False)
    (prefix/'dependency-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))


if __name__ == '__main__':
    main()
