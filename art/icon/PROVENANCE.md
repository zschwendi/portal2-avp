# Twin Gateways: app icon provenance

The Portal 2 native Apple port's app icon, for visionOS (layered) and
iPad/iPhone. It is an original work, generated entirely by
`art/icon/generate_icon.swift` from procedural geometry and colour constants
in that file.

## Originality statement

- Every shape and colour in the icon is computed by the generator: analytic
  ellipses, a pinhole-camera projection of a flat panel wall, exponential and
  Gaussian light falloffs, a seeded pseudo-random starfield, and a hash for
  panel tone variation.
- No external image, texture, screenshot, model, font, icon set or other
  artwork was read, traced, sampled or used as a reference. The generator
  opens no input files. It imports only Foundation, CoreGraphics, ImageIO,
  UniformTypeIdentifiers and simd, and uses them for maths, PNG encoding and
  compositing the preview sheet.
- The icon contains no text. The contact sheet has no text either.
- Nothing was downloaded. The generator runs offline with the Xcode command
  line tools (Swift 6.4.2, macOS 27).
- This replaces the iOS build's previous icon, which `tools/build_ios.py`
  extracted at build time from the player's own copy of the game
  (`portal2/resource/game.icns`). That extraction has been removed.

### Explicitly excluded

The icon does not use, trace, approximate or evoke any of these:

- the Portal or Portal 2 logo or wordmark, including any stylised letter "O" ring;
- the Aperture Science logo, or any iris or shutter-aperture symbol;
- Valve logos;
- Chell, the companion cube or its heart, turrets, GLaDOS or Wheatley;
- the portal gun;
- any in-game screenshot, texture, model or font from the game;
- any third-party artwork or icon set.

The "Portal-inspired" element is the generic idea of two linked, glowing
gateways: one cyan, one amber, as recorded in `docs/acceptance.md` (final
polish: an original icon with blue/orange portals and a test-chamber theme).
The test-chamber reference is a plain, generic grid of square wall panels. It
has no signage, markings or game textures. The rims are smooth, analytic light
profiles, not particle or flame effects.

## Design

Two identical elliptical openings are cut through a clean, softly lit panel
wall. The wall is seen at an angle, so its seams run toward a vanishing point
off to the right. The near opening is cyan, at lower left. The far opening is
amber, at upper right, and looks smaller and narrower because it is farther
away. That staggered placement keeps the pair from reading like a face at
small sizes. Through both openings you see a deep night field: navy fading to
black, faint wisps and sparse stars. Far inside each opening is a faint glow
in the other opening's colour, a quiet hint that the two are linked. Each rim
has a white-hot core line, a saturated colour band and a soft halo. The halo
spills coloured light onto the wall and into the opening as haze.

The visionOS layers are arranged for parallax:

| Layer | Content | Alpha |
|---|---|---|
| Back | Deep field seen through the openings (gradient, wisps, stars, far glows) | opaque (RGB) |
| Middle | Panel wall with the two openings cut out, light spill, distance haze | transparent openings |
| Front | Luminous rims, outer halo, inner haze | transparent except the light |

When the system shifts the layers, the deep field slides behind the openings
like a real hole in a wall, and the rims float just above the wall. The iOS
icon is the same three layers flattened with sRGB source-over, the same
compositing the system uses, and saved opaque.

## Method

- **Camera and wall.** A pinhole camera (focal length 1000 px, principal
  point (512, 470)) looks at a vertical wall turned 30° about the vertical
  axis. Each sample is ray-cast to the wall to find its wall coordinates
  (u, v) and depth.
- **Openings.** Each opening is defined on the wall as an ellipse (wall units).
  Its exact screen-space ellipse is found by transforming the conic through
  the camera homography (C' = H^-T C H^-1). The wall mask uses the wall-space
  test, and the rim glow uses the screen-space ellipse, so they line up exactly.
- **Wall shading.** Albedo, then per-panel tone jitter from an integer hash,
  seams (a Gaussian core plus a soft ambient-occlusion falloff), a small
  bevel highlight on each panel's top edge and a shadow on its bottom edge, a
  Gaussian key-light pool at the upper left, a gentle top-to-bottom gradient,
  coloured spill from each opening (an exponential in ellipse radii), and
  exponential distance haze.
- **Rims.** These use the approximate signed distance to the screen ellipse,
  scaled by depth: core `exp(-(d/3.3)^2)`, band `exp(-(d/13)^2)`, outer halo
  `0.50 e^(-d/30) + 0.20 e^(-d/125)` and inner haze
  `0.55 e^(d/34) + 0.12 e^(d/115)`. A three-harmonic angular shimmer
  modulates the band (`1 + 0.16 sin 3φ + 0.09 sin 5φ + 0.05 sin 9φ`, with
  per-portal phases). Weights: core 1.9, band 1.45 × shimmer, halo
  0.85 + 0.15 × shimmer. Emitted
  light is converted to an over-layer with alpha = max channel.
- **Deep field.** A radial gradient, five rotated anisotropic Gaussian wisps,
  and a faint far glow per opening in the linked colour (0.08 and 0.05 at
  σ = 80 and 190 px over depth, offset toward the vanishing point). Stars
  come from 230 splatted Gaussians from a seeded LCG (Knuth MMIX constants,
  seed `0x5EED2B1C0DE5`), with brightness `0.12 + 1.6 m^7`.
- **Sampling.** Supersampled at 2×2 (Back), 4×4 (Middle) and 3×3 (Front).
  Lighting is computed in linear light and encoded to 8-bit sRGB. The opaque
  outputs get a ±0.5 LSB triangular hash dither against banding.
- **Determinism.** No clocks or system randomness affect pixels. Two
  consecutive runs produced byte-identical PNG, JSON and SVG files.

All named parameters are constants at the top of `generate_icon.swift`. The
generator also writes them, with the derived screen-space ellipses, to
`art/icon/parameters.json`. `art/icon/twin-gateways.svg` is a vector reference
of the same geometry (seams, ellipses, gradients, blurred rim strokes) for
review. The shipped PNGs are the per-pixel renders.

### Key parameters (see `parameters.json` for the full set)

| Group | Values |
|---|---|
| Canvas | 1024 × 1024 px |
| Camera | focal 1000 px, wall yaw 30°, distance 1, principal (512, 470) |
| Wall | square panels 0.25, seam 0.0034, albedo `#D3DAE3`, ambient `#F2F5FA`, haze `#161D2C`, key light at (−0.62, 0.42), radius 0.70 |
| Cyan opening | wall centre (−0.215, −0.100), semi-axes (0.130, 0.215); rim `#2CC6FF`, glow `#1690FF`, core `#E9FBFF`, far light `#FFA24A` |
| Amber opening | wall centre (0.370, 0.060), semi-axes (0.130, 0.215); rim `#FFA11F`, glow `#FF5A0A`, core `#FFF6E6`, far light `#45C8FF` |
| Screen ellipses (derived) | cyan centre (293.0, 582.6), radii 142.0 × 241.8; amber centre (778.0, 419.2), radii 80.4 × 181.7 |
| Deep field | `#0D1F4C` to `#02040C`, centre (560, 470), radius 760 px; 230 stars |

## Outputs and wiring

| Output | Used by |
|---|---|
| `visionos/GameAssets.xcassets/AppIcon.solidimagestack/{Back,Middle,Front}.solidimagestacklayer/Content.imageset/*.png` | Portal2Game target only (`visionos/project.yml`: source `GameAssets.xcassets`, `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`) |
| `ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | `tools/build_ios.py` (`app_icon`): `xcrun actool` compiles it into `Portal2.app` and the partial plist's `CFBundleIcons` / `CFBundleIcons~ipad` go into `Info.plist`. If actool is unavailable, it falls back to loose PNGs made with `sips` |
| `art/icon/twin-gateways.svg`, `art/icon/parameters.json` | review and audit |
| `build/icon-preview/contact-sheet.png` (not versioned) | owner preview |

The contact sheet layout:

- Top left: the iOS squircle at 1024 px, over a split light and dark backdrop.
- Top right: the visionOS circular mask at 520 px.
- Middle right: the Back, Middle and Front layers. Middle and Front are shown over a checkerboard.
- Lower right: simulated parallax (look left, rest, look right).
- Bottom: two strips, light then dark. Each shows the squircle and then the circle at 180, 120, 87, 60, 40 and 29 px, at 1:1 pixels.

## Regenerate

From the repository root (no network; takes about 4 s):

```sh
xcrun swiftc -O art/icon/generate_icon.swift -o "${TMPDIR:-/tmp}/p2-icongen" && "${TMPDIR:-/tmp}/p2-icongen"
# add --no-preview to skip build/icon-preview/contact-sheet.png
python3 -m unittest tests.test_app_icon
```

To validate the catalogs without a full build, use `actool` into any scratch
directory:

```sh
xcrun actool visionos/GameAssets.xcassets --compile OUT/xros --platform xros \
  --minimum-deployment-target 2.0 --app-icon AppIcon --target-device vision \
  --output-partial-info-plist OUT/xros/partial.plist --errors --warnings --notices
xcrun actool ios/Assets.xcassets --compile OUT/iphoneos --platform iphoneos \
  --minimum-deployment-target 17.0 --app-icon AppIcon --target-device iphone --target-device ipad \
  --output-partial-info-plist OUT/iphoneos/partial.plist --errors --warnings --notices
```
