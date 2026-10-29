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

## Game files for later integration

The base recomp needs a complete owned Portal 2 content folder and the Linux
depot 661. The [upstream README](README.md#upstream-portal-2-statically-recompiled-for-apple-silicon-macos-and-iphone)
documents the supported build. Steam console's `download_depot 620 661`
requires an entitled signed-in account. Installing Steam on a modern Mac
does not make the original 32-bit Mac game executable compatible; only the
retail content and supported Linux binaries are required for recompilation.
Do not obtain them from third-party repacks.

See [docs/visionos.md](docs/visionos.md) for the remaining game-renderer,
input, mod, and multiplayer work.
