# Portal 2 AVP development check

**There is no playable Portal 2 visionOS build yet.** These instructions build
the separate native stereo renderer check. It draws an original calibration
grid and boxes, not Portal 2. Do not list this fork as a working game port.

## Mac prerequisites

- Xcode with visionOS SDK and simulator runtime.
- `xcodegen` (`brew install xcodegen`).
- An Apple signing team only if installing the renderer check on a headset.

From this repo:

```sh
python3 tools/visionos.py --preflight
python3 -m unittest discover -s tests -p test_visionos_xr.py -v
python3 tools/visionos.py --build-renderer-check --target sim
```

Preflight currently exits nonzero for missing implementation and/or game
files even when the renderer check can build. It does not download files or
modify your Steam install.

## Simulator

Choose an available Vision Pro simulator from `xcrun simctl list devices`.
Replace `VISION_PRO_SIMULATOR_UDID` below with that exact identifier:

```sh
xcrun simctl boot VISION_PRO_SIMULATOR_UDID
xcrun simctl bootstatus VISION_PRO_SIMULATOR_UDID -b
xcrun simctl install VISION_PRO_SIMULATOR_UDID build/visionos/sim/DerivedData/Build/Products/Debug-xrsimulator/Portal2RendererCheck.app
xcrun simctl launch VISION_PRO_SIMULATOR_UDID dev.zschwendi.portal2avp.renderercheck --renderer-check
```

Without `--renderer-check`, launch opens a setup window with an Open renderer
check button. With the option, it opens the immersive check automatically.
The app clearly labels the simulator's fixed pose. Native runtime tests
exercise both eye matrices, but the simulator screenshot is not a physical
stereo/head-tracking acceptance test.

Xcode 27 exposes simulator content through Device Hub. Select the exact
simulator there to interact. Close renderer check to leave immersion.

## Device build

Compile only, without signing/installing:

```sh
python3 tools/visionos.py --build-renderer-check --target device
```

For a signed renderer check, supply your own Apple team:

```sh
python3 tools/visionos.py --build-renderer-check --target device --team YOUR_TEAM_ID
```

The tool does not install or launch on a device. Its receipt states whether
the build was signed. The renderer-check identifier is separate from the
eventual game identifier and will not replace existing game apps/saves.

## Owned game files

The base recomp needs a complete owned Portal 2 content folder and the Linux
depot 661. The [upstream README](README.md#upstream-portal-2-statically-recompiled-for-apple-silicon-macos-and-iphone)
documents the supported build. Steam console's `download_depot 620 661`
requires an entitled signed-in account. Installing Steam on a modern Mac
does not make the original 32-bit Mac game executable compatible; only the
retail content and supported Linux binaries are required for recompilation.
Do not obtain them from third-party repacks.

## Native engine test (development)

This second app hosts the actual recompiled engine in a window. It is still
being validated and is **not an immersive stereo game release**. Keep an owned
retail content folder and the supported Linux manifest in ignored
`config/local.json`, then:

```sh
python3 tools/mobile_deps.py --platform visionos --target sim --jobs 3
python3 tools/gameprep.py
python3 tools/build_visionos_game.py --target sim --jobs 3
xcodegen generate --spec visionos/project.yml
xcodebuild -project visionos/Portal2AVP.xcodeproj -scheme Portal2Game -sdk xrsimulator -destination 'generic/platform=visionOS Simulator' -derivedDataPath build/visionos/GameApp CODE_SIGNING_ALLOWED=NO build
python3 tools/run_visionos_game.py --sim VISION_PRO_SIMULATOR_UDID --audit-render-view
```

The launch helper links content/prepared images into this app's Documents,
preserves different existing paths and keeps saves in its separate user folder.
It restarts only the development engine-test identifier. Simulator audio is
muted unless `--audio` is passed. See its printed path for `Documents/game.log`.
The optional RenderView hook is a hash-checked, pass-through layout audit; it
does not change the camera or enable stereo.

For a **synthetic simulator input** and frame-timing check on an owned map:

```sh
python3 tools/run_visionos_game.py --sim VISION_PRO_SIMULATOR_UDID --map sp_a2_laser_intro --input-audit --frame-audit
```

This leaves `Documents/launch.args` intact. It stops injecting input if a real
controller connects. The audit is disabled on device builds and does not
establish physical DualSense or PSVR2 Sense support. `--stereo-audit` separately
requests a fixed-separation diagnostic pair without a tracked headset pose.
Follow the [acceptance order](docs/acceptance.md) before immersive testing.
The immersive development button is hidden unless `--immersive-test` is
passed. It does not indicate that tracked gameplay or mode switching has
passed acceptance.

For a full device compile and a normal Xcode signing attempt:

```sh
python3 tools/mobile_deps.py --platform visionos --target device --jobs 3
python3 tools/build_visionos_game.py --target device --opt 2 --jobs 3
xcodebuild -project visionos/Portal2AVP.xcodeproj -scheme Portal2Game -sdk xros -destination 'generic/platform=visionOS' -derivedDataPath build/visionos/DeviceGame -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

The game target requests Apple's
[increased memory limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
entitlement. Provisioning requires a profile with that capability and a
developer account in good standing. A successful device build and signature
remain separate from installation, owned-content transfer and hardware play.

### Headset content import

The engine-test app includes a developer importer for the owned files in
`config/local.json`. It copies files onto the headset; the Mac does not render
or stream the game. Prepare the Linux images with `tools/gameprep.py` first.
On the Mac, start a temporary source with its private LAN address and hostname:

```sh
python3 tools/serve_owned_content.py --bind YOUR_MAC_LAN_IP --advertise-host YOUR_MAC.local --ttl 7200 --output build/visionos/content-source.json
```

The command hashes the prepared images, Linux depot and supported game-content
directories. It writes a private receipt containing a temporary manifest URL;
keep that URL private. The source exports a fixed file map, offers no directory
listing or writes, and stops after the selected lifetime. Leave it running
during import. `build/visionos/content-source.activity.json` reports transfer
counts without including the URL.

Install the signed `Portal2Game.app` with Xcode or `devicectl`. To launch this
development app with the receipt, substitute the exact physical headset UDID
below. This restarts only the engine-test app, preserving its Documents/saves:

```sh
python3 - PHYSICAL_HEADSET_UDID <<'PY'
import json, subprocess, sys
from pathlib import Path
source = json.loads(Path('build/visionos/content-source.json').read_text())
subprocess.run([
    'xcrun', 'devicectl', 'device', 'process', 'launch',
    '--device', sys.argv[1], '--terminate-existing',
    'dev.zschwendi.portal2avp.enginetest', '--',
    '--import-content', source['manifest_url'], '--engine-test',
], check=True)
PY
```

Keep the headset awake and allow its Local Network prompt. The window shows
file and byte progress and starts the engine only after import succeeds.
Existing matching files are reused after SHA-256 verification; different
files are preserved under `Documents/Portal2 Import Backups`. Saves in
`portal2-userdata` are outside the import allowlist. A failed import keeps
completed files; relaunch with a current receipt to retry. A partially
downloaded file starts again. There is no general game library/import UI yet.
The protocol and Swift importer pass fixture tests; physical import throughput
and gameplay remain separate acceptance steps.

For the fork's iPhone/iPad path:

```sh
python3 tools/mobile_deps.py --platform ios --target sim --jobs 3
python3 tools/build_ios.py --target sim --deps deps/ios/sim --opt 1 --fast-memory --jobs 3
```

This compiles the same generated game C for iOS using the existing UIKit/EAGL
host and touch controls. Installation, physical input and gameplay acceptance
remain separate. Keep device data/saves intact when following upstream device
instructions. All generated C/apps/assets remain local.

See [docs/visionos.md](docs/visionos.md) for the remaining game-renderer,
input, mod, and multiplayer work.
