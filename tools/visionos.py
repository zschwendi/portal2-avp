#!/usr/bin/env python3
"""Inspect visionOS prerequisites or build the explicitly named renderer check.

The renderer check has no game code. The game port is not linked yet; this
tool never presents that diagnostic app as a playable Portal 2 build.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_STEAM = Path.home() / 'Library/Application Support/Steam/steamapps'


def inspect(config_path=None):
    path = config_path or ROOT / 'config/local.json'
    config = json.loads(path.read_text()) if path.is_file() else {}
    if not isinstance(config, dict):
        raise ValueError('config must be a JSON object')
    game = Path(config.get('game_root', DEFAULT_STEAM / 'common/Portal 2')).expanduser()
    linux = Path(config.get('linux_root', DEFAULT_STEAM / 'content/app_620/depot_661')).expanduser()
    checks = []

    def check(name, ready, detail):
        checks.append(dict(name=name, ready=bool(ready), detail=detail))

    check('xcodegen', shutil.which('xcodegen'), 'Install xcodegen with Homebrew if missing.')
    for sdk in ('xros', 'xrsimulator'):
        try:
            result = subprocess.run(['xcrun', '--sdk', sdk, '--show-sdk-path'],
                                    capture_output=True, text=True)
            check(sdk, result.returncode == 0, result.stdout.strip() or result.stderr.strip())
        except FileNotFoundError:
            check(sdk, False, 'Xcode with visionOS SDKs is required.')
    data_ready = (game / 'portal2/gameinfo.txt').is_file() and (game / 'platform').is_dir()
    data_ready = data_ready and any((game / 'portal2').glob('*_dir.vpk'))
    check('retail_content', data_ready, str(game))
    required = ['portal2_linux', 'bin/linux32/libtier0.so', 'bin/linux32/libvstdlib.so',
                'bin/linux32/engine.so', 'bin/linux32/libtogl.so',
                'portal2/bin/linux32/client.so', 'portal2/bin/linux32/server.so']
    missing = [name for name in required if not (linux / name).is_file()]
    check('linux_depot_661', not missing, str(linux) + ('; missing: ' + ', '.join(missing) if missing else ''))
    # These are implementation blockers, not something an input file can fix.
    check('visionos_game_renderer', False,
          'Metal-backed offscreen GL host and engine-test window implemented; pending actual engine execution, paired eye rendering and CompositorServices game submission.')
    check('linux_stereo_hooks', False,
          'Owned-client hash/RTTI audit identifies RenderView; pass-through runtime CViewSetup audit, stereo and player-portal hooks still require execution validation.')
    return dict(game_ready=all(item['ready'] for item in checks),
                renderer_check_ready=all(item['ready'] for item in checks[:3]),
                upstream='kanapitsas/portal2-recomp', checks=checks)


def build_check(target, team=None):
    sdk, destination = ('xrsimulator', 'generic/platform=visionOS Simulator') if target == 'sim' else ('xros', 'generic/platform=visionOS')
    if team and target != 'device':
        raise ValueError('--team applies only to --target device')
    if not shutil.which('xcodegen'):
        raise ValueError('xcodegen is missing; install it before building the renderer check')
    subprocess.run(['xcodegen', 'generate', '--spec', str(ROOT / 'visionos/project.yml')], check=True, cwd=ROOT)
    output = ROOT / 'build/visionos' / target
    output.mkdir(parents=True, exist_ok=True)
    command = ['xcodebuild', '-project', str(ROOT / 'visionos/Portal2AVP.xcodeproj'),
               '-scheme', 'Portal2RendererCheck', '-sdk', sdk, '-destination', destination,
               '-derivedDataPath', str(output / 'DerivedData')]
    if team:
        command += ['-allowProvisioningUpdates', 'DEVELOPMENT_TEAM=' + team]
    else:
        command += ['CODE_SIGNING_ALLOWED=NO']
    command += ['build']
    log = output / 'build.log'
    print(f'Building renderer check only; log: {log}', flush=True)
    with log.open('w') as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    app = output / 'DerivedData/Build/Products' / ('Debug-xrsimulator' if target == 'sim' else 'Debug-xros') / 'Portal2RendererCheck.app'
    receipt = dict(kind='renderer_check', game_attached=False, target=target, signed=bool(team),
                   exit_code=result.returncode, app=str(app), log=str(log))
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--preflight', action='store_true', help='report game and platform blockers (default)')
    mode.add_argument('--build-renderer-check', action='store_true', help='build the calibration app, without game code')
    parser.add_argument('--target', choices=('sim', 'device'), default='sim')
    parser.add_argument('--team', help='Apple team for a signed device renderer check; never installs or launches')
    parser.add_argument('--config', type=Path, help='local game config to inspect; never modified')
    parser.add_argument('--json', action='store_true', help='emit machine-readable preflight results')
    args = parser.parse_args()
    if args.build_renderer_check:
        if args.config or args.json:
            parser.error('--config and --json apply to preflight')
        try:
            return build_check(args.target, args.team)
        except (ValueError, subprocess.CalledProcessError) as error:
            print(error, file=sys.stderr)
            return 1
    if args.team:
        parser.error('--team requires --build-renderer-check')
    try:
        result = inspect(args.config)
    except (OSError, ValueError, TypeError) as error:
        print(f'Invalid local config: {error}', file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for item in result['checks']:
            print(f'{"OK" if item["ready"] else "BLOCKED"}: {item["name"]}: {item["detail"]}')
        print('Game ready: ' + str(result['game_ready']))
        print('Renderer check build prerequisites ready: ' + str(result['renderer_check_ready']))
    return 0 if result['game_ready'] else 1


if __name__ == '__main__':
    sys.exit(main())
