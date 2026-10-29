# Immersive visionOS work

Status date: October 28, 2026 (America/Denver).
Starting commit: `dd7955e` of `kanapitsas/portal2-recomp`.

## Existing work checked

A bounded public search found no published native immersive Portal 2 visionOS
port. This is not a guarantee that nobody has a private or unindexed project.
Queries included `Portal 2 visionOS`, `portal2 CompositorServices`,
`Portal 2 Apple Vision Pro native port`, and GitHub repository searches for
`portal visionos` and `portal2 vision`. The upstream fork list and the
[AVP Ports Index](https://github.com/edgytoast/avp-ports-index) were also checked.

Relevant primary sources:

| Project | What it supplies | Limits for this fork |
| --- | --- | --- |
| [portal2-recomp](https://github.com/kanapitsas/portal2-recomp) | Existing Linux i386 → ARM64 lifter/runtime and Mac/iPhone game path | iPhone renderer depends on EAGL/OpenGLES; iPhone Steam is an offline stub |
| [Portal2VR](https://github.com/Gistix/portal2vr) | Reference for paired RenderView calls, separate eye targets, portal camera correction, controller aiming and UI handling | Windows x86 D3D9/OpenVR hooks and signatures cannot run on visionOS or be copied to Linux offsets |
| [SourceVR](https://github.com/tinsarfal/SourceVR) | Standalone Quest/PICO installation/mod and gameplay reference | Public repo currently publishes documentation/releases rather than engine source; Portal 2 is explicitly highly experimental, not campaign-ready |
| [SDL2](https://github.com/libsdl-org/SDL/tree/release-2.32.10) | Guest ABI, dummy window bookkeeping and virtual gamepad | SwiftUI owns native windows; HIDAPI is disabled on visionOS |
| [ANGLE](https://github.com/google/angle/blob/main/doc/DevSetup.md) | GLES → Metal below the upstream gl4es layer | Current binaries are retargeted iOS builds; simulator execution passes, physical acceptance pending |
| [Apple compositor rendering](https://developer.apple.com/videos/play/wwdc2025/294/) | Native per-eye views, projection and drawable presentation | Needs actual game draw targets and tracking on the headset |

Portal2VR source inspected at `310ac494e26cfac17b86e681e48147532682efca`,
especially `L4D2VR/hooks.cpp:dRenderView`, `dPlayerPortalled`,
`dTraceFirePortal`, and `vr.cpp`. No code or assets from that reference were
copied into the port. Its `VRScale=43.2` is a gameplay calibration choice;
our bridge defaults to the inch-based 39.3700787 Source units/meter and
accepts an explicit scale so physical calibration can change it.

## Implemented here

- `runtime/visionos/p2_xr.{h,c}`: coherent frame/input snapshots, generation
  IDs for space lifetimes, two eye transforms and compositor projections;
  tracking loss and disconnect release all actions. Invalid/out-of-order
  poses do not replace a good pose; loss explicitly invalidates it.
- Tracking-space to Source-space conversion, yaw/translation recentering
  that preserves pitch and roll, and full rigid portal transforms applied
  to the tracking origin. This is math support, **not yet a hooked player
  portal event or verified portal collision handling**.
- `visionos/`: a full immersive CompositorServices layer, predicted ARKit
  head anchor, separate per-eye Metal projection, reverse-depth rendering,
  clear-only fallback when headset tracking is absent, frame cancellation
  handling, and explicit array-slice handling.
- An original calibration grid and boxes exercise this path without Valve
  data. The simulator may use a fixed diagnostic pose; it never publishes
  that pose to the game bridge as tracked.
- GameController snapshots: left stick movement, right stick turn,
  right/left triggers blue/orange, A jump, B crouch, X use, Menu pause,
  left stick click recenter. These actions are captured at the boundary;
  an SDL virtual gamepad now exposes them to the guest's existing input ABI.
  A synthetic route test verifies axes, trigger polarity and disconnect;
  **physical game controls remain unverified**.
- `tools/visionos.py`: reports both missing data and missing implementation;
  builds the named renderer check. It does not substitute that check for a
  Portal 2 build or install anything on the headset.

## Native host checkpoint

The owner is signed into Steam; retail content and supported Linux depot
manifest `8940703274703023246` are installed locally. The Mac baseline compiled
and its real menu was observed. The owner reported stutter/hang; this is not
accepted gameplay and the Mac test has been stopped. Vision Pro is the target.

- `tools/mobile_deps.py` builds pinned SDL2, FreeType, gl4es and visionOS OpenAL
  dependencies, preserving notices and writing local receipts. Both simulator
  dependency prefixes have been built. See `visionos/deps/README.md`.
- `runtime/visionos/gl_vision.m` provides ANGLE Metal GLES contexts with a
  leased IOSurface pool, GPU synchronization and safe surface resizing. The
  fork's existing iOS shader/sRGB fixes remain above that backend. The native
  simulator GPU probe verifies pixels before/after resize and physical row
  orientation; no game data is involved in that probe.
- `PortalGameView` is a native Metal window for real engine frames. The full
  visionOS simulator game builds and launches; its real menu and opening
  campaign room have been visually observed. The full iOS simulator and
  visionOS device engines also compile. An isolated iPad simulator rendered
  the opening room through the inherited UIKit/EAGL path. Physical gameplay
  acceptance remains open, following the [windowed-first gates](acceptance.md).
- `tools/visionos_hooks.py` verifies the owned client SHA-256 and derives its
  `CViewRender` table from RTTI. `view_vision.c` optionally installs a
  `RenderView` hook with loaded-byte and camera-layout checks. The 260-byte
  Linux camera layout has been exercised in the real campaign. An optional
  fixed-separation diagnostic calls the original renderer twice and captures
  each final target into separate IOSurfaces; it never claims physical
  tracking. No Windows hook offsets are used. Physical tracked stereo,
  portal crossings and clipping still require acceptance.
- PSVR2 Sense uses fixed hardware chirality, two independent GameController
  profiles and ARKit-predicted aim/grip poses at the headset presentation time.
  Duplicate hand identities and orientation-only tracking are rejected.
  Tracking loss releases held controls. This code builds against the SDK;
  **controller poses, aiming and gameplay have not been accepted on hardware**.
- Window input sessions do not invent a head pose or require accessory motion
  permission. The immersive session requires tracked headset/eye data. Session
  retirement prevents an old window or render thread from publishing controls.
- A real-engine synthetic input audit caught a detached native SDL pad after
  engine input startup. The host now safely reopens/reattaches it by instance
  ID. Guest joystick/controller handles also reject stale native instances
  across SDL teardown. The corrected audit moves the actual player, changes
  pitch/yaw, pauses and resumes; save/reload has also run. Warm simulator
  rendering held roughly 60 fps for several minutes, with long cold-loading
  stalls still present. Neither hardware controls nor smooth performance on
  Vision Pro is established by these results.
- Immersive entry is opt-in through `--immersive-test` during development.
  The normal candidate opens windowed so controller acceptance can come first.

Current Python/native suite: 47 tests pass, including UBSan XR math/session
checks. Native runtime: 59 source units compile with warnings treated as
errors. The offscreen GPU/SDL input probe passes. These are component checks,
not campaign, stereo, device or performance acceptance.
Focused guest SDL handle/refcount and restart checks also pass AddressSanitizer
and UBSan. The broader native ABI run currently fails an existing SDL event
timestamp assertion against Homebrew's SDL2 compatibility library; that suite
is not reported as passing. The mobile targets use the pinned SDL2 source.

## Work needed for a playable build

1. Finish and exercise the full visionOS engine build against the owned
   content. Diagnose startup, rendering, audio, input and sustained timing.
2. Extend the working offscreen host from a single game surface to paired
   engine eye targets and submit them with matching poses/projections and
   correct depth conventions to CompositorServices.
3. Resolve engine RenderView/CViewSetup and player-portal hooks against the
   **owned Linux binary** with symbol/byte/layout checks. Preserve the
   original single-view code as fallback. Update simulation once, render
   each eye from the same game state, retain per-eye asymmetric frusta,
   handle recursive portal views and near-wall/crossing eye clipping, and
   use the engine's actual portal transformation for head/body/gun state.
4. Integrate thread ownership. The existing SDL bridge requires the main
   thread and the guest runtime uses a guest lock. SwiftUI/CompositorServices
   must continue to run while the guest loop renders; never call arbitrary
   guest functions concurrently from the compositor thread.
5. Feed bridge input into the existing guest SDL/controller interfaces;
   add snap-turn/recenter/menu focus rules. Start with a gamepad. Tracked
   Sense/hand aiming needs separate device/input work, not fabricated poses.
6. Prove campaign startup, save/reload, portal crossing (including floor
   portals), lasers, gels, funnels, menus/pause, audio, transitions, and
   sustained frame timing on physical Vision Pro. Build/simulator success
   does not satisfy these checks.

## Compatibility goals and current limits

| Feature | Current evidence / next gate |
| --- | --- |
| Native fully immersive gameplay | Paired capture and game compositor integration in development; physical stereo, aiming, portal behavior and performance pending |
| Windowed visionOS; iPhone/iPad | VisionOS simulator real movement/look/pause and save/reload exercised; native iPad simulator room observed; physical controls/playability pending |
| DualSense / PSVR2 Sense | Native input/pose adapters and synthetic SDL route pass; hardware controls and game aiming unverified |
| Original campaign/physics/saves | Aim to retain original recompiled code and content; visionOS behavior untested |
| Content mods/custom maps | Preserve the retail filesystem and archives; actual mounting and playthrough untested |
| Workshop subscriptions/downloads | Not available through upstream iOS Steam stubs; manual owned content is the first candidate |
| DLL/native-code mods | PC DLLs cannot execute directly on visionOS; require compatible rebuilt/lifted modules and ABI checks |
| LAN co-op | Runtime has POSIX socket bridges, but this does not prove Portal 2 co-op works with its Steam dependencies |
| Steam matchmaking/online co-op | Separate major work: iOS stub returns no networking/lobby/auth/UGC service. No online identity or authentication success is invented |
| PC parity | Long-term goal, not a supported feature list |

## Verification at the first checkpoint

- Python suite: 47 tests run, 46 passed and one upstream test skipped.
  The new native XR contract runs with UBSan and includes a concurrent
  publication check.
- `Portal2RendererCheck` builds for both `xrsimulator` and `xros` with
  Xcode 27.1 / SDK 27.0; device build is unsigned and not installed.
- Vision Pro simulator: installed, launched, immersive space opened, and
  calibration grid/blue and orange boxes visually verified. Metal completion
  status was 4 (completed). The simulator supplied **one view**, not two;
  no physical stereo, physical head tracking or gameplay was verified.
  The check deliberately uses a fixed pose on the simulator and never marks
  that pose as physically tracked, even if ARKit supplies a software anchor.
- Local evidence is ignored under `build/`: `python-tests.log`,
  `visionos/{sim,device}/receipt.json`, `visionos-simulator-xr.log`,
  and `visionos-renderer-immersive.png`.
- Steam installed from Valve's official Mac installer and updated locally;
  owner subsequently signed in and both retail content and depot 661 completed.

Generated C, game binaries, depots, VPKs and signed game apps stay local.
Retain upstream GPLv3 and attribution; use only the owner's original game data.
