#!/usr/bin/env python3
"""Crée « Portal 2 Natif.app », dont la Bibliothèque s’ouvre depuis le Finder ou le Dock.

L'application ne recopie pas le jeu. Elle démarre build/portal2-native de ce
dépôt, y compris après une recompilation, avec les chemins de config/local.json.
Le bouton Play démarre Steam s'il ne tourne pas et écrit le
journal dans ~/Library/Logs/Portal2Natif.log. Le lanceur terminal reste tools/run_game.py.

    python3 tools/make_app.py                      # ~/Applications
    python3 tools/make_app.py --dest /Applications
    python3 tools/make_app.py -- -game portal2 -novid -windowed -w 2560 -h 1440
"""
import argparse
import json
import os
import platform
import plistlib
import shlex
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

from portal_cloud_signing import CONTAINER, INFO_KEY, authorize_cloud

ROOT = Path(__file__).resolve().parent.parent
NAME = 'Portal 2 Natif'
# Sans -w/-h/-windowed : résolution et mode choisis dans le menu Vidéo du jeu
# (enregistrés dans update/cfg/video.txt) ; Retina selon la résolution.
DEFAULT_ARGS = ['-game', 'portal2', '-novid']
DEFAULT_BUNDLE_ID = 'fr.kanapitsas.portal2-native'

LAUNCHER = '''#!/bin/bash
# Worker de lancement produit par tools/make_app.py.
LOG="$HOME/Library/Logs/Portal2Natif.log"
mkdir -p "$(dirname "$LOG")" || exit 1
exec >"$LOG" 2>&1
fail() {{ printf '%s\\n' "$1" >&2; exit 1; }}
if [ ! -x {binary} ]; then fail "Exécutable introuvable. Lancer tools/build_game.py --release."; fi
if [ ! -d {game_dir} ]; then fail "Données du jeu introuvables. Le disque du jeu est peut-être débranché."; fi
# L'API Steam a besoin du client Steam ouvert et connecté.
if ! /usr/bin/pgrep -qx steam_osx; then
    /usr/bin/open -ga Steam
    for _ in $(seq 60); do /usr/bin/pgrep -qx steam_osx && break; sleep 0.5; done
    sleep 5
fi
export SteamAppId=620 SteamGameId=620
mkdir -p {user_dir} || exit 1
# Langue : P2_LANGUAGE, "language" de config/local.json, Steam, système (tools/language.py).
# Un -language passé au lanceur l'emporte ; en cas d'échec, le jeu reste en anglais.
LANGUAGE_ARGS=$(/usr/bin/python3 {language_script} -- {game_args} "$@" 2>/dev/null)
exec {binary} --images {images} --game-dir {game_dir} --linux-root {linux_root} \\
    --user-dir {user_dir} -- {game_args} $LANGUAGE_ARGS "$@"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dest', type=Path, default=Path.home() / 'Applications')
    parser.add_argument('--bundle-id', default=DEFAULT_BUNDLE_ID)
    parser.add_argument('--cloud-signing-identity', help='Developer ID Application signing identity')
    parser.add_argument('--cloud-provisioning-profile', type=Path,
                        help='macOS App ID profile authorizing the Portal 2 iCloud Documents container')
    parser.add_argument('game_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if bool(args.cloud_signing_identity) != bool(args.cloud_provisioning_profile):
        parser.error('Provide both cloud signing identity and provisioning profile.')
    game_args = args.game_args[1:] if args.game_args[:1] == ['--'] else args.game_args
    config = json.loads((ROOT / 'config/local.json').read_text())
    binary = ROOT / 'build/portal2-native'
    paths = {
        'binary': binary, 'images': ROOT / 'build/game/prep', 'game_dir': Path(config['game_root']),
        'linux_root': Path(config['linux_root']), 'user_dir': Path(config.get('user_dir') or ROOT / '../work/portal2-userdata').expanduser().resolve(),
    }

    args.dest.mkdir(parents=True, exist_ok=True)
    app = args.dest / f'{NAME}.app'
    with tempfile.TemporaryDirectory(prefix='.portal2-launcher-', dir=args.dest) as temporary:
        staging = Path(temporary)
        staged_app = staging / app.name
        build_bundle(staged_app, paths, game_args or DEFAULT_ARGS, bundle_id=args.bundle_id,
                     cloud_identity=args.cloud_signing_identity, cloud_profile=args.cloud_provisioning_profile)
        # Conserver le précédent paquet tant que la nouvelle version ne compile pas.
        previous = staging / 'previous.app'
        if app.exists() or app.is_symlink():
            app.rename(previous)
        try:
            staged_app.rename(app)
        except OSError:
            if previous.exists() or previous.is_symlink():
                previous.rename(app)
            raise
    print(app)


def build_bundle(app, paths, game_args, *, bundle_id=DEFAULT_BUNDLE_ID,
                 cloud_identity=None, cloud_profile=None):
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()

    worker = resources / 'launch-game'
    worker.write_text(LAUNCHER.format(
        language_script=shlex.quote(str(ROOT / 'tools/language.py')), game_args=shlex.join(game_args),
        **{key: shlex.quote(str(value)) for key, value in paths.items()}))
    worker.chmod(worker.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    manifest = {
        'engine': str(paths['binary']), 'images': str(paths['images']), 'game': str(paths['game_dir']),
        'depot': str(paths['linux_root']), 'saves': str(paths['user_dir']),
        'log': str(Path.home() / 'Library/Logs/Portal2Natif.log'),
    }
    (resources / 'launch.json').write_text(json.dumps(manifest, indent=2) + '\n')

    subprocess.run([
        'xcrun', '--sdk', 'macosx', 'swiftc', '-O', '-parse-as-library',
        '-target', f'{platform.machine()}-apple-macos13.0', '-swift-version', '6',
        str(ROOT / 'macos/Portal2Launcher.swift'), str(ROOT / 'macos/PortalSaveWriterLease.swift'),
        *map(str, sorted((ROOT / 'apple/Saves').glob('*.swift'))),
        '-o', str(macos / 'launcher'),
    ], check=True)

    icon = ROOT / 'art/icon/Portal2.icns'
    if not icon.is_file():
        icon = paths['game_dir'] / 'portal2/resource/game.icns'
    if icon.exists(): shutil.copy(icon, resources / 'portal2.icns')
    plist = {
        'CFBundleName': NAME, 'CFBundleDisplayName': NAME, 'CFBundleIdentifier': bundle_id,
        'CFBundleExecutable': 'launcher', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0', 'CFBundleIconFile': 'portal2', 'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.games',
    }
    entitlements = None
    if cloud_profile:
        contents = subprocess.check_output(['security', 'cms', '-D', '-i', str(cloud_profile)])
        profile = plistlib.loads(contents)
        team = profile['TeamIdentifier'][0]
        app_id = profile['Entitlements'].get('com.apple.application-identifier', '')
        if app_id != f'{team}.{bundle_id}':
            raise ValueError(f'Provisioning profile must authorize {team}.{bundle_id}')
        container = os.environ.get('P2_ICLOUD_CONTAINER', CONTAINER)
        entitlements = authorize_cloud(profile['Entitlements'], container)
        entitlements.update({'com.apple.application-identifier': app_id,
                             'com.apple.developer.team-identifier': team})
        plist[INFO_KEY] = container
        shutil.copyfile(cloud_profile, app / 'Contents/embedded.provisionprofile')
    with (app / 'Contents/Info.plist').open('wb') as f:
        plistlib.dump(plist, f)
    subprocess.run(['/usr/bin/xattr', '-cr', str(app)], check=True)
    with tempfile.NamedTemporaryFile(suffix='.plist') as signed_entitlements:
        options = []
        if entitlements:
            plistlib.dump(entitlements, signed_entitlements)
            signed_entitlements.flush()
            options = ['--timestamp', '--options', 'runtime', '--entitlements', signed_entitlements.name]
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', cloud_identity or '-', *options, str(app)],
                       check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)


if __name__ == '__main__':
    main()
