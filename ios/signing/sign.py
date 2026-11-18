#!/usr/bin/env python3
"""Signe un paquet .app iOS pour un appareil réel.

Prend le profil de provisionnement le plus récent obtenu par Xcode pour le
CFBundleIdentifier du paquet (voir ios/signing/project.yml), l'embarque et
signe avec l'identité « Apple Development » de son équipe et les droits du
profil.

    python3 ios/signing/sign.py build/ios/device/Portal2.app
"""
import hashlib
import plistlib
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from portal_cloud_signing import INFO_KEY, authorize_cloud, cloud_entitlements

PROFILES = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
            Path.home() / 'Library/MobileDevice/Provisioning Profiles']


def decode(profile):
    raw = subprocess.run(['security', 'cms', '-D', '-i', str(profile)], capture_output=True, check=True).stdout
    return plistlib.loads(raw)


def find_profile(bundle_id, container=None):
    best = None
    for folder in PROFILES:
        for path in folder.glob('*.mobileprovision') if folder.is_dir() else []:
            data = decode(path)
            app_id = data['Entitlements'].get('application-identifier', '')
            if app_id.split('.', 1)[-1] != bundle_id:
                continue
            if data['ExpirationDate'].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
                continue
            if container:
                try:
                    authorize_cloud(data['Entitlements'], container)
                except ValueError:
                    continue
            if best is None or data['CreationDate'] > best[1]['CreationDate']:
                best = (path, data)
    if not best:
        service = f' autorisant iCloud Documents pour {container}' if container else ''
        sys.exit(f'aucun profil pour {bundle_id}{service} : voir ios/signing/project.yml')
    return best


def identity(team, certificates):
    found = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                           capture_output=True, text=True, check=True).stdout
    allowed = {hashlib.sha1(certificate).hexdigest().upper() for certificate in certificates}
    for line in found.splitlines():
        if '"Apple Development' in line and line.split()[1] in allowed:
            return line.split()[1]
    sys.exit(f'aucune identité Apple Development pour l\'équipe {team}')


def main():
    app = Path(sys.argv[1])
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle_id = info['CFBundleIdentifier']
    container = info.get(INFO_KEY)
    path, data = find_profile(bundle_id, container)
    team = data['TeamIdentifier'][0]
    (app / 'embedded.mobileprovision').write_bytes(path.read_bytes())
    entitlements = data['Entitlements'].copy()
    for key in cloud_entitlements(container):
        entitlements.pop(key, None)
    if container:
        entitlements.update(authorize_cloud(data['Entitlements'], container))
    with tempfile.NamedTemporaryFile(suffix='.plist') as f:
        plistlib.dump(entitlements, f)
        f.flush()
        subprocess.run(['codesign', '-f', '-s', identity(team, data['DeveloperCertificates']),
                        '--entitlements', f.name, '--generate-entitlement-der', str(app)], check=True)
    print(f'{app} signé ({bundle_id}, équipe {team}, profil expirant le {data["ExpirationDate"]:%Y-%m-%d})')


if __name__ == '__main__':
    main()
