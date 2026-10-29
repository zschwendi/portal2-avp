#!/usr/bin/env python3
"""Install/launch the local engine test on one explicitly selected simulator.

Uses links to the owner's content, never duplicates the retail install, and
refuses to replace different existing Documents paths. No headset deployment.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'dev.zschwendi.portal2avp.enginetest'


def command(*arguments, capture=False, **kwargs):
    return subprocess.run([str(a) for a in arguments], check=True,
                          capture_output=capture,text=True,**kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim',required=True,help='exact available Vision Pro simulator UDID')
    parser.add_argument('--audit-render-view',action='store_true',help='enable the pass-through Linux camera audit')
    parser.add_argument('--audio',action='store_true',help='allow simulator audio on this Mac')
    parser.add_argument('--map',help='owned campaign map for this simulator run; preserves launch.args')
    parser.add_argument('--input-audit',action='store_true',help='synthetic SDL gameplay input audit (requires --map)')
    parser.add_argument('--frame-audit',action='store_true',help='log five-second engine frame timing intervals')
    parser.add_argument('--stereo-audit',action='store_true',help='diagnostic fixed-separation pair; not tracked stereo')
    parser.add_argument('--immersive-test',action='store_true',help='expose the immersive development button after windowed acceptance')
    parser.add_argument('--app',type=Path,default=ROOT/'build/visionos/GameApp/Build/Products/Debug-xrsimulator/Portal2Game.app')
    args = parser.parse_args()
    inventory = json.loads(command('xcrun','simctl','list','devices','available','--json',capture=True).stdout)
    matches = [(runtime,device) for runtime,devices in inventory['devices'].items()
               for device in devices if device['udid'] == args.sim]
    if len(matches) != 1 or 'xrOS' not in matches[0][0]:
        parser.error('--sim must identify one available visionOS simulator; other simulators are preserved')
    if not (args.app/'Portal2Game').is_file(): parser.error('Build the Portal2Game Xcode scheme first')
    config = json.loads((ROOT/'config/local.json').read_text())
    sources = {'game':Path(config['game_root']),'linux':Path(config['linux_root']),'prep':ROOT/'build/game/prep'}
    if not all(path.is_dir() for path in sources.values()): parser.error('Owned content/Linux/prepared roots are missing')
    if args.input_audit and not args.map: parser.error('--input-audit requires an explicit --map')
    if args.map and (not args.map.replace('_','').isalnum() or
                     not (sources['game']/'portal2/maps'/(args.map+'.bsp')).is_file()):
        parser.error('--map must name a map in the owned retail maps directory')
    if matches[0][1]['state'] != 'Booted': command('xcrun','simctl','boot',args.sim)
    command('xcrun','simctl','bootstatus',args.sim,'-b')
    command('xcrun','simctl','install',args.sim,args.app)
    container = Path(command('xcrun','simctl','get_app_container',args.sim,BUNDLE,'data',capture=True).stdout.strip())
    documents = container/'Documents'
    documents.mkdir(parents=True,exist_ok=True)
    for name,source in sources.items():
        destination = documents/name
        source = source.resolve()
        if destination.exists() or destination.is_symlink():
            if destination.resolve() != source:
                parser.error('Preserving different existing content path: '+str(destination))
        else: destination.symlink_to(source,target_is_directory=True)
    env = dict(os.environ)
    env['SIMCTL_CHILD_P2_XR_HOOK_AUDIT'] = '1' if args.audit_render_view else '0'
    env['SIMCTL_CHILD_P2_VISION_STEREO_AUDIT'] = '1' if args.stereo_audit else '0'
    env['SIMCTL_CHILD_P2_VISION_INPUT_AUDIT'] = '1' if args.input_audit else '0'
    env['SIMCTL_CHILD_P2_VISION_FRAME_AUDIT'] = '1' if args.frame_audit else '0'
    env['SIMCTL_CHILD_P2_VISION_TEST_MAP'] = args.map or ''
    if not args.audio:
        env['SIMCTL_CHILD_SDL_AUDIODRIVER'] = 'dummy'
        env['SIMCTL_CHILD_ALSOFT_DRIVERS'] = 'null'
    # Explicit development test identifier only; app data and saves survive.
    launch = ['--engine-test'] + (['--immersive-test'] if args.immersive_test else [])
    command('xcrun','simctl','launch','--terminate-running-process',args.sim,BUNDLE,*launch,env=env)
    print(json.dumps(dict(kind='engine_test',immersive_gameplay_verified=False,
                          simulator=args.sim,documents=str(documents),game_log=str(documents/'game.log')),
                     indent=2))


if __name__ == '__main__':
    main()
