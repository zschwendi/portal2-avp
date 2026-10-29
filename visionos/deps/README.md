# Mobile host dependencies

Builds and source caches stay under ignored `/deps`. No Valve data is downloaded.

```sh
python3 tools/mobile_deps.py --platform visionos --target sim --jobs 3
python3 tools/mobile_deps.py --platform ios --target sim --jobs 3
```

Use `--target device` for each platform's physical SDK. Required tools: Xcode,
Python 3.12+, CMake, Ninja, Git and `patch`. Downloaded archives and the ANGLE
framework files are SHA-256 checked; gl4es is pinned to a Git commit. Source
patches are checked before application. A source-cache lock prevents concurrent
dependency mutations. Each platform uses its own build/output directories.

- SDL 2.32.10: visionOS uses dummy video for worker-side bookkeeping. SwiftUI
  and CompositorServices own native presentation. Virtual joysticks are enabled
  independently of HIDAPI; GameController owns real hardware input.
- FreeType 2.14.3 and the upstream fontconfig shim retain font handling.
- gl4es at `a025615bc79ac43ec911dced8fe5b8eb45a0b72d`, using the fork's existing
  `ios/deps/gl4es-ios.patch`. The wrapper changes build output placement only.
  No upstream contribution is submitted.
- OpenAL Soft 1.25.2 supplies visionOS audio. SDK 27's new CoreAudio callback
  effect warning is demoted for that source file only; audio timing needs tests.
- Experimental ANGLE frameworks come from the pinned
  [avp-craft dependency snapshot](https://github.com/zschwendi/avp-craft/tree/8e8b9a388c323af6ff7dadc19600bee7c7289d93/vendor/out).
  These are ARM64 iOS binaries retargeted to visionOS, **not a fresh visionOS
  source build**. The simulator GPU probe executes their Metal backend, but
  physical-device and distribution acceptance remain separate requirements.

License notices are copied into each prefix's `licenses/` directory. Keep those
notices and the relevant upstream source/build instructions with any permitted
dependency distribution. The generated game itself remains local.

`dependency-receipt.json` records the SDK, prefix, pinned revisions and explicit
unverified gameplay status. A dependency receipt is not proof of a working game.
