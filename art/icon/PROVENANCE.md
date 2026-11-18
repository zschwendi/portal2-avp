# Porcelain Split Oval: app icon provenance

The Portal 2 native Apple port's app icon, for visionOS (layered), iPad/iPhone
and macOS. It is an original work, generated entirely by
`art/icon/generate_icon.swift` from the geometry and colour constants in that
file. It replaces the earlier "Twin Gateways" artwork (two glowing openings in
a panel wall); that version stays available in Git history only.

## Originality statement

- Every shape and colour in the icon is computed by the generator: one analytic
  ellipse, its exact offset band (the rim stroke), two half-plane cuts, a
  radial light falloff and Gaussian/erfc soft shadows.
- No external image, texture, screenshot, model, font, icon set or other
  artwork was read, traced, sampled or used as a reference. The generator
  opens no input files. It imports only Foundation, CoreGraphics, ImageIO,
  UniformTypeIdentifiers and simd, and uses them for maths, PNG encoding and
  compositing the preview sheet. It runs `/usr/bin/iconutil` once to pack its
  own macOS renders.
- The icon contains no text. The contact sheet has no text either.
- Nothing was downloaded. The generator runs offline with the Xcode command
  line tools (Swift 6.4.2, macOS 27).
- The iOS build's original icon, which `tools/build_ios.py` used to extract from
  the player's copy of the game (`portal2/resource/game.icns`), was replaced
  by generated artwork earlier and has not come back.

### Explicitly excluded

The icon does not use, trace, approximate or evoke any of these:

- the Portal or Portal 2 logo or wordmark, or any letterform. The emblem is a
  plain geometric ellipse split along its axis. It is not drawn to match any
  logo, and it has no figure, silhouette or lettering inside or around it;
- the Aperture Science logo, or any iris or shutter-aperture symbol;
- Valve logos;
- Chell, the companion cube or its heart, turrets, GLaDOS or Wheatley;
- the portal gun;
- any in-game screenshot, texture, model or font from the game;
- any third-party artwork or icon set.

The Portal-inspired part is only the generic pairing of a blue half and an
orange half, as recorded in `docs/acceptance.md` (final polish: an original
icon with blue/orange portals). That note also mentions a test-chamber theme.
This simplified design leaves it out on purpose, at the owner's request.

## Design

A porcelain-white field holds one large oval that leans slightly to the right
at the top. The oval is drawn as two open rim strokes: a deep cobalt half on
the left and a saturated warm amber half on the right. The split runs along the
major axis, so a narrow seam of porcelain separates the halves at the top and
bottom ends. The silhouettes are bold and high in contrast, so they stay
legible in a small circle. Dimension is kept subtle: each rim has a softly
rounded cross-section lit from the upper left, with a faint glaze highlight.
The porcelain has a gentle key-light falloff and a very faint ambient relief
around the oval. There are no starfields, holes, panel seams, reflections,
logos, text or other decoration.

The visionOS layers are independent and arranged for parallax:

| Layer | Content | Alpha |
|---|---|---|
| Back | Porcelain field, key-light falloff, faint shared relief under the whole oval | opaque (RGB) |
| Middle | Cobalt left half rim | transparent except the stroke |
| Front | Amber right half rim | transparent except the stroke |

visionOS draws its own shadows between layers, so the colour layers carry none.
The 32 px seams leave room for the halves to shift against each other: the
contact sheet's preview moves Front 8 px relative to Middle, which still leaves
24 px of porcelain in each seam.

The **iPad/iPhone** icon is the same stack flattened with sRGB source-over (the
same compositing the system uses). A soft contact shadow (16 %, σ 9 px, offset
(3, 7)) goes under the halves. It is saved as an opaque 1024 px square with no
baked corner mask; the system applies the mask.

The **macOS** icon renders the same stack natively (not by resampling) into an
824 px rounded square, corner radius 185.4 px, with 100 px transparent padding
on the 1024 canvas. A modest drop shadow sits in the padding (24 %, σ 8 px,
6 px down). Each size from 16 px to 1024 px is rendered at its own resolution
with an analytic, supersampled mask, so the edges stay crisp. `iconutil` packs
them into `art/icon/Portal2.icns`.

## Method

- **Oval frame.** A sample point is rotated into the oval's frame (centre
  (512, 512), tilt 16°: the top of the major axis leans right). Its closest
  point on the ellipse (semi-axes 204 × 334 px, the stroke centreline) is
  found with four fixed-point iterations on the evolute. That gives an exact
  signed distance and the outward normal.
- **Halves.** Each half is the band |d| ≤ stroke/2 (88 px stroke), intersected
  with its side of the major axis, minus half the seam (32 px gap in total).
  The four cut corners are rounded with an 8 px radius-rounded intersection of
  signed distance fields. Coverage is analytic (`clamp(0.5 − sdf/footprint)`)
  at every supersample, which keeps the edges crisp at every size.
- **Rim shading.** The cross-section is tilted by up to `bevel` = 0.60 at the
  rim edges. Lambert lighting relative to a flat face (light direction
  (−0.42, −0.58, 0.70)) mixes the half's `base` colour toward `deep` (gain 0.9)
  or `lit` (gain 1.6). A Blinn glaze highlight (white, strength 0.30,
  exponent 60) is added on top.
- **Porcelain.** A radial blend from `lit` to `base` to `edge` around a key light
  at (400, 330), radius 820 px. The relief multiplies the field by
  `1 − 0.05 exp(−out²/2·28²)`, where `out` is the distance outside the full rim
  band, offset (4, 9) px. Set `Field.reliefStrength` to 0 to remove it.
- **Sampling.** Supersampled at 4×4 (Middle, Front, mask), 3×3 (Back) and 2×2
  (shadows). macOS sizes of 64 px and below use 6×6. Shading is computed in
  linear light and encoded to 8-bit sRGB. Opaque outputs get a ±0.5 LSB
  triangular hash dither against banding.
- **Determinism.** No clocks or randomness affect any pixel.

All parameters are constants near the top of `generate_icon.swift`, grouped by
layer: `Field` (Back), `Emblem` (shared oval geometry and light), `Glaze`,
`halves` (per-half layer, side, colours and preview shift), `FlatShadow` and
`Mac`. Each layer's geometry and colours can be adjusted independently there.
The generator writes them, with the derived outer extent, to
`art/icon/parameters.json`. `art/icon/split-oval.svg` is an editable vector
reference of the same stack, with one group per visionOS layer and exact
stroked ellipses clipped at the seams. It omits the shading, rounded cut
corners, relief and contact shadow. The shipped PNGs are the per-pixel renders.

### Key parameters (see `parameters.json` for the full set)

| Group | Values |
|---|---|
| Canvas | 1024 × 1024 px |
| Oval | centre (512, 512), semi-axes 204 × 334 px, tilt 16°, stroke 88 px, seam 32 px, corner radius 8 px; outer extent 378 px from the centre (visionOS circle radius 512) |
| Cobalt half (Middle) | base `#1646C4`, deep `#0A2675`, lit `#4A80F0` |
| Amber half (Front) | base `#F7860F`, deep `#C24C06`, lit `#FFB54A` |
| Porcelain (Back) | lit `#FCFBF8`, base `#F1EFEA`, edge `#DCD9D3`; relief 0.05, σ 28 px |
| Preview parallax | Back −6, Middle +4, Front +12 px per unit of look |

## Outputs and wiring

| Output | Used by |
|---|---|
| `visionos/GameAssets.xcassets/AppIcon.solidimagestack/{Back,Middle,Front}.solidimagestacklayer/Content.imageset/*.png` | Portal2Game target only (`visionos/project.yml`: source `GameAssets.xcassets`, `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`) |
| `ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | `tools/build_ios.py` (`app_icon`): `xcrun actool` compiles it into `Portal2.app`, and the partial plist's `CFBundleIcons` / `CFBundleIcons~ipad` go into `Info.plist`. If actool is unavailable, it falls back to loose PNGs made with `sips` |
| `art/icon/Portal2.icns` | macOS packaging input |
| `art/icon/split-oval.svg`, `art/icon/parameters.json` | review and audit |
| `build/porcelain-icon/Portal2.iconset/` (not versioned) | iconutil input |
| `build/icon-preview/contact-sheet.png` (not versioned) | owner preview |

The generator writes only the files above. It does not touch the asset
catalogs' `Contents.json` files; it checks that they exist and stops otherwise.

The contact sheet layout:

- Top: heroes over split light and dark grounds. From left: the iPad squircle,
  the visionOS circle and the macOS rounded square (with its own padding and
  shadow), each 620 px.
- Middle: the Back, Middle and Front layers (Middle and Front over a
  checkerboard). Next to them, simulated parallax in the circle: look left,
  up, rest, down, right.
- Bottom: two strips, light then dark. Each shows squircles and then circles at
  180, 120, 87, 60, 40 and 29 px, then native macOS renders at 128, 64, 32 and
  16 px, all at 1:1 pixels.

## Regenerate

From the repository root (no network; takes about 3 s):

```sh
xcrun swift -O art/icon/generate_icon.swift
# or compiled: xcrun swiftc -O art/icon/generate_icon.swift -o "${TMPDIR:-/tmp}/p2-icongen" && "${TMPDIR:-/tmp}/p2-icongen"
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
