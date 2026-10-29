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
