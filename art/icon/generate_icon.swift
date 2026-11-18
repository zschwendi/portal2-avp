// Porcelain Split Oval: original app icon generator for the Portal 2 native Apple port.
//
// Every pixel written by this program is computed from the geometry and colour
// constants below: a porcelain-white field and one tilted oval drawn as two open
// rim strokes, a cobalt half and an amber half, separated by two narrow seams.
// It reads no image, font, texture, model or other artwork. See PROVENANCE.md.
//
// Regenerate from the repository root (no network, Xcode command line tools only):
//
//   xcrun swift -O art/icon/generate_icon.swift
//   (or compiled: xcrun swiftc -O art/icon/generate_icon.swift -o "${TMPDIR:-/tmp}/p2-icongen" && "${TMPDIR:-/tmp}/p2-icongen")
//
// Writes only these files (relative to the repository root):
//   visionos/GameAssets.xcassets/AppIcon.solidimagestack/{Back,Middle,Front}.solidimagestacklayer/Content.imageset/*.png
//   ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png      opaque flattened square, no corner mask
//   art/icon/Portal2.icns                                   rounded-square macOS icon (iconutil)
//   art/icon/split-oval.svg                                 editable vector reference of the layer stack
//   art/icon/parameters.json                                every parameter and the derived extents
//   build/porcelain-icon/Portal2.iconset/                   iconutil input (not versioned)
//   build/icon-preview/contact-sheet.png                    masks, layers, parallax and small sizes (not versioned)
// The asset catalogs' Contents.json files are not touched. Pass --no-preview to skip the contact sheet.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>

// MARK: - Colour helpers (sRGB transfer function, linear-light maths)

func toLinear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
func toSRGB(_ c: Float) -> Float {
    let c = max(0, min(1, c))
    return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
}
func hex(_ v: UInt32) -> V3 {
    V3(toLinear(Float((v >> 16) & 255) / 255), toLinear(Float((v >> 8) & 255) / 255), toLinear(Float(v & 255) / 255))
}
func hexString(_ v: UInt32) -> String { String(format: "#%06X", v) }
func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}
/// Pixel coverage of a signed distance field over a sample footprint.
@inline(__always) func coverage(_ sdf: Float, _ footprint: Float) -> Float { max(0, min(1, 0.5 - sdf / footprint)) }
/// Coverage of a Gaussian-blurred edge: a soft shadow from a signed distance.
@inline(__always) func soft(_ sdf: Float, _ sigma: Float) -> Float { 0.5 * erfcf(sdf / (sigma * 1.414_213_6)) }

/// Integer hash to [0, 1): quantisation dither.
func hash3(_ a: Int32, _ b: Int32, _ c: Int32) -> Float {
    var h = UInt32(bitPattern: a) &* 0x9E37_79B1
    h ^= UInt32(bitPattern: b) &* 0x85EB_CA77
    h ^= UInt32(bitPattern: c) &* 0xC2B2_AE3D
    h ^= h >> 15; h &*= 0x2C1B_3C6D
    h ^= h >> 12; h &*= 0x297A_2D39
    h ^= h >> 15
    return Float(h >> 8) / Float(1 << 24)
}

// MARK: - Parameters (icon space is 1024 x 1024 px, origin top-left, y down)

let size = 1024

/// Back layer: opaque porcelain field with a soft key light and a faint shared relief under the oval.
enum Field {
    static let lit: UInt32 = 0xFCFBF8             // glaze under the key light
    static let base: UInt32 = 0xF1EFEA            // porcelain white
    static let edge: UInt32 = 0xDCD9D3            // gentle falloff toward the corners
    static let lightCentre = V2(400, 330)
    static let lightRadius: Float = 820
    static let reliefStrength: Float = 0.05       // ambient occlusion around the whole oval; 0 disables
    static let reliefSigma: Float = 28
    static let reliefOffset = V2(4, 9)
    static let previewShift: Float = -6           // contact sheet parallax, px per unit of look
}

/// The oval both halves are cut from. The major axis is the split line; the seams sit at its two ends.
enum Emblem {
    static let centre = V2(512, 512)
    static let semiAxes = V2(204, 334)            // across, along the major axis (centreline of the stroke)
    static let tiltDegrees: Float = 16            // major axis leans right at the top
    static let stroke: Float = 88                 // rim width
    static let seam: Float = 32                   // gap between the halves, at both ends of the major axis
    static let cornerRadius: Float = 8            // softening of the four cut corners
    static let bevel: Float = 0.60                // cross-section tilt at the rim edges (0 flat, 1 round tube)
    static let light = simd_normalize(V3(-0.42, -0.58, 0.70))   // from upper left, toward the viewer
    static var tilt: Float { tiltDegrees * .pi / 180 }
}

/// Soft porcelain-glaze highlight on both rims.
enum Glaze {
    static let colour: UInt32 = 0xFFFFFF
    static let strength: Float = 0.30
    static let exponent: Float = 60
}

struct Half {
    let name: String
    let layer: String
    let side: Float          // -1: left of the major axis, +1: right
    let base: UInt32         // face colour
    let deep: UInt32         // turned away from the light
    let lit: UInt32          // turned toward the light
    let previewShift: Float  // contact sheet parallax, px per unit of look
}

let halves = [
    Half(name: "blue", layer: "Middle", side: -1, base: 0x1646C4, deep: 0x0A2675, lit: 0x4A80F0, previewShift: 4),
    Half(name: "orange", layer: "Front", side: 1, base: 0xF7860F, deep: 0xC24C06, lit: 0xFFB54A, previewShift: 12),
]

/// Flattened icons only (iPad, macOS): a soft contact shadow of the halves on the porcelain.
/// visionOS draws its own shadows between layers, so the layers do not carry one.
enum FlatShadow {
    static let colour: UInt32 = 0x3A332B
    static let strength: Float = 0.16
    static let sigma: Float = 9
    static let offset = V2(3, 7)
}

/// macOS: the artwork on a rounded square inside the standard transparent padding.
enum Mac {
    static let inset: Float = 100                 // 824 px tile on the 1024 canvas
    static let cornerRadius: Float = 185.4
    static let shadowOpacity: Float = 0.24
    static let shadowSigma: Float = 8
    static let shadowOffset: Float = 6            // downward
    static let sizes = [16, 32, 64, 128, 256, 512, 1024]
}

// MARK: - Geometry

let tiltCos = cosf(Emblem.tilt), tiltSin = sinf(Emblem.tilt)

/// Closest point on an axis-aligned ellipse (radii ab) to p, by a few fixed-point steps on the evolute.
@inline(__always) func ellipseClosest(_ p: V2, _ ab: V2) -> V2 {
    let px = abs(p.x), py = abs(p.y), a = ab.x, b = ab.y
    var tx: Float = 0.707_106_8, ty: Float = 0.707_106_8
    for _ in 0..<4 {
        let ex = (a * a - b * b) * tx * tx * tx / a, ey = (b * b - a * a) * ty * ty * ty / b
        let r = hypotf(a * tx - ex, b * ty - ey), q = max(1e-6, hypotf(px - ex, py - ey))
        tx = max(0, min(1, ((px - ex) * r / q + ex) / a))
        ty = max(0, min(1, ((py - ey) * r / q + ey) / b))
        let t = hypotf(tx, ty); tx /= t; ty /= t
    }
    return V2(copysignf(a * tx, p.x), copysignf(b * ty, p.y))
}

/// A sample point relative to the oval's centreline.
struct RingPoint {
    let local: V2      // oval frame: x across, y along the major axis
    let offset: Float  // signed distance to the centreline, positive outward
    let normal: V2     // outward normal, screen space
}

@inline(__always) func ringPoint(_ p: V2) -> RingPoint {
    let r = p - Emblem.centre
    let q = V2(r.x * tiltCos + r.y * tiltSin, -r.x * tiltSin + r.y * tiltCos)
    let ab = Emblem.semiAxes
    let c = ellipseClosest(q, ab)
    let inside = (q.x * q.x) / (ab.x * ab.x) + (q.y * q.y) / (ab.y * ab.y) < 1
    let dist = simd_length(q - c)
    let g = simd_normalize(V2(c.x / (ab.x * ab.x), c.y / (ab.y * ab.y)))
    return RingPoint(local: q, offset: inside ? -dist : dist,
                     normal: V2(g.x * tiltCos - g.y * tiltSin, g.x * tiltSin + g.y * tiltCos))
}

/// Signed distance to one half: the rim band intersected with its side of the seam, corners rounded.
@inline(__always) func halfSDF(_ i: Int, _ rp: RingPoint) -> Float {
    let rc = Emblem.cornerRadius
    let a = abs(rp.offset) - Emblem.stroke / 2 + rc
    let b = -halves[i].side * rp.local.x + Emblem.seam / 2 + rc
    return simd_length(simd_max(V2(a, b), .zero)) + min(max(a, b), 0) - rc
}

// MARK: - Layer shaders (linear light)

let fieldLit = hex(Field.lit), fieldBase = hex(Field.base), fieldEdge = hex(Field.edge)
let halfBase = halves.map { hex($0.base) }, halfDeep = halves.map { hex($0.deep) }, halfLit = halves.map { hex($0.lit) }
let glazeColour = hex(Glaze.colour), shadowColour = hex(FlatShadow.colour)
let glazeHalfway = simd_normalize(Emblem.light + V3(0, 0, 1))

/// Back layer.
@inline(__always) func porcelain(_ p: V2) -> V3 {
    let r = simd_length(p - Field.lightCentre) / Field.lightRadius
    var c = mix(fieldLit, fieldBase, smoothstep(0, 0.6, r))
    c = mix(c, fieldEdge, smoothstep(0.55, 1.35, r))
    if Field.reliefStrength > 0 {
        let out = max(0, abs(ringPoint(p - Field.reliefOffset).offset) - Emblem.stroke / 2)
        c *= 1 - Field.reliefStrength * expf(-out * out / (2 * Field.reliefSigma * Field.reliefSigma))
    }
    return c
}

/// Middle (i = 0) and Front (i = 1) layers: one glazed half rim. Returns colour and coverage.
@inline(__always) func halfSample(_ i: Int, _ p: V2, _ footprint: Float) -> (V3, Float) {
    let rp = ringPoint(p)
    let k = coverage(halfSDF(i, rp), footprint)
    if k <= 0 { return (.zero, 0) }
    let s = max(-1, min(1, rp.offset / (Emblem.stroke / 2))) * Emblem.bevel
    let n = V3(rp.normal.x * s, rp.normal.y * s, sqrtf(1 - s * s))
    let diffuse = simd_dot(n, Emblem.light) - Emblem.light.z
    var c = diffuse < 0 ? mix(halfBase[i], halfDeep[i], min(1, -diffuse * 0.9))
                        : mix(halfBase[i], halfLit[i], min(1, diffuse * 1.6))
    c = mix(c, glazeColour, Glaze.strength * powf(max(0, simd_dot(n, glazeHalfway)), Glaze.exponent))
    return (c, k)
}

/// Flattened icons only: soft contact shadow of both halves.
@inline(__always) func contactShadow(_ p: V2) -> (V3, Float) {
    let rp = ringPoint(p - FlatShadow.offset)
    return (shadowColour, FlatShadow.strength * soft(min(halfSDF(0, rp), halfSDF(1, rp)), FlatShadow.sigma))
}

/// macOS tile, in macOS canvas px.
@inline(__always) func tileSDF(_ p: V2) -> Float {
    let q = simd_abs(p - V2(repeating: Float(size) / 2)) - V2(repeating: Float(size) / 2 - Mac.inset - Mac.cornerRadius)
    return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - Mac.cornerRadius
}

// MARK: - Rendering

/// A layer in straight (non-premultiplied) sRGB-encoded floats.
struct Layer {
    var rgb: [V3]
    var alpha: [Float]
    let side: Int
}

/// Renders side x side pixels with n x n supersampling. Output pixel p maps to icon point p * scale + origin;
/// the shader returns linear colour and coverage, and receives the sample footprint in icon px.
func render(_ side: Int, ss n: Int, scale: Float = 1, origin: V2 = .zero, _ shader: (V2, Float) -> (V3, Float)) -> Layer {
    var rgb = [V3](repeating: .zero, count: side * side), alpha = [Float](repeating: 0, count: side * side)
    rgb.withUnsafeMutableBufferPointer { rgbBuf in
        alpha.withUnsafeMutableBufferPointer { alphaBuf in
            let rgbOut = rgbBuf.baseAddress!, alphaOut = alphaBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: side) { y in
                for x in 0..<side {
                    var premult = V3.zero, cover: Float = 0
                    for sy in 0..<n { for sx in 0..<n {
                        let o = V2(Float(x) + (Float(sx) + 0.5) / Float(n), Float(y) + (Float(sy) + 0.5) / Float(n))
                        let (c, k) = shader(o * scale + origin, scale / Float(n))
                        premult += c * k; cover += k
                    } }
                    let c = cover > 0 ? premult / cover : V3.zero
                    let a = cover / Float(n * n)
                    rgbOut[y * side + x] = V3(toSRGB(c.x), toSRGB(c.y), toSRGB(c.z))
                    alphaOut[y * side + x] = a < 1.0 / 512 ? 0 : a
                }
            }
        }
    }
    return Layer(rgb: rgb, alpha: alpha, side: side)
}

/// Source-over in sRGB space, as the platforms composite icon layers.
func over(_ top: Layer, _ bottom: Layer) -> Layer {
    var out = bottom
    for i in 0..<(top.side * top.side) {
        let a = top.alpha[i], b = bottom.alpha[i]
        let oa = a + b * (1 - a)
        out.alpha[i] = oa
        out.rgb[i] = oa > 0 ? (top.rgb[i] * a + bottom.rgb[i] * b * (1 - a)) / oa : V3(repeating: 0)
    }
    return out
}

/// The full stack at any size: Back, Middle, Front, and the flattened-only contact shadow.
func renderStack(_ side: Int, ss n: Int, scale: Float = 1, origin: V2 = .zero) -> (back: Layer, middle: Layer, front: Layer, shadow: Layer) {
    (render(side, ss: max(2, n - 1), scale: scale, origin: origin) { p, _ in (porcelain(p), 1) },
     render(side, ss: n, scale: scale, origin: origin) { p, fp in halfSample(0, p, fp) },
     render(side, ss: n, scale: scale, origin: origin) { p, fp in halfSample(1, p, fp) },
     render(side, ss: 2, scale: scale, origin: origin) { p, _ in contactShadow(p) })
}

func flatten(_ s: (back: Layer, middle: Layer, front: Layer, shadow: Layer)) -> Layer {
    over(s.front, over(s.middle, over(s.shadow, s.back)))
}

/// macOS icon at side px, rendered natively: the stack fills the 824 px tile, outside is transparent.
func macIcon(_ side: Int) -> Layer {
    let canvasPerPx = Float(size) / Float(side)
    let iconPerCanvas = Float(size) / (Float(size) - 2 * Mac.inset)
    let n = side <= 64 ? 6 : 3
    var tile = flatten(renderStack(side, ss: n, scale: canvasPerPx * iconPerCanvas,
                                   origin: V2(repeating: -Mac.inset * iconPerCanvas)))
    let mask = render(side, ss: n, scale: canvasPerPx) { p, fp in (.zero, coverage(tileSDF(p), fp)) }
    let shadow = render(side, ss: 2, scale: canvasPerPx) { p, _ in
        (.zero, Mac.shadowOpacity * soft(tileSDF(p - V2(0, Mac.shadowOffset)), Mac.shadowSigma))
    }
    for i in 0..<(side * side) { tile.alpha[i] *= mask.alpha[i] }
    return over(tile, shadow)
}

/// 8-bit RGBA with an optional +-0.5 LSB triangular dither against banding in the soft gradients.
func quantize(_ layer: Layer, dither: Bool) -> [UInt8] {
    let side = layer.side
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    for i in 0..<(side * side) {
        let a = layer.alpha[i]
        let x = Int32(i % side), y = Int32(i / side)
        for ch in 0..<3 {
            let n = dither ? hash3(x, y, Int32(ch)) - hash3(x, y, Int32(ch + 3)) : 0
            let v = a > 0 ? layer.rgb[i][ch] * 255 + 0.5 + n * 0.5 : 0
            bytes[i * 4 + ch] = UInt8(max(0, min(255, v.rounded(.down))))
        }
        bytes[i * 4 + 3] = UInt8(max(0, min(255, (a * 255 + 0.5).rounded(.down))))
    }
    return bytes
}

// MARK: - Image I/O (ImageIO PNG, sRGB)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func makeImage(_ layer: Layer, alpha: Bool, dither: Bool) -> CGImage {
    let bytes = quantize(layer, dither: dither), side = layer.side
    let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast).rawValue)
    return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                   space: sRGB, bitmapInfo: info, provider: CGDataProvider(data: Data(bytes) as CFData)!,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func writePNG(_ image: CGImage, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
}

func writeText(_ text: String, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - SVG reference and parameter record

func f(_ v: Float, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

func svgReference() -> String {
    let e = "rx=\"\(f(Emblem.semiAxes.x))\" ry=\"\(f(Emblem.semiAxes.y))\" fill=\"none\" stroke-width=\"\(f(Emblem.stroke))\""
    let half = Emblem.seam / 2, far: Float = 600
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    <!-- Porcelain Split Oval: vector reference of the layer stack, written by art/icon/generate_icon.swift.
         Original geometry only: a porcelain field and one tilted oval drawn as two open rim strokes,
         split along the major axis with a seam at each end. Each group is one visionOS layer.
         The shipped PNGs are per-pixel renders; their glaze shading, rounded cut corners, faint relief
         and the flattened icons' contact shadow are not drawn here. -->
    <defs>
      <radialGradient id="porcelain" cx="\(f(Field.lightCentre.x))" cy="\(f(Field.lightCentre.y))" r="\(f(Field.lightRadius * 1.35))" gradientUnits="userSpaceOnUse">
        <stop offset="0" stop-color="\(hexString(Field.lit))"/><stop offset="0.44" stop-color="\(hexString(Field.base))"/><stop offset="1" stop-color="\(hexString(Field.edge))"/>
      </radialGradient>
      <clipPath id="left-of-seam"><rect x="\(f(-far))" y="\(f(-far))" width="\(f(far - half))" height="\(f(2 * far))"/></clipPath>
      <clipPath id="right-of-seam"><rect x="\(f(half))" y="\(f(-far))" width="\(f(far - half))" height="\(f(2 * far))"/></clipPath>
    </defs>
    <g id="Back"><rect width="1024" height="1024" fill="url(#porcelain)"/></g>
    <g id="Middle" transform="translate(\(f(Emblem.centre.x)) \(f(Emblem.centre.y))) rotate(\(f(Emblem.tiltDegrees)))">
      <ellipse id="blue-half" \(e) stroke="\(hexString(halves[0].base))" clip-path="url(#left-of-seam)"/>
    </g>
    <g id="Front" transform="translate(\(f(Emblem.centre.x)) \(f(Emblem.centre.y))) rotate(\(f(Emblem.tiltDegrees)))">
      <ellipse id="orange-half" \(e) stroke="\(hexString(halves[1].base))" clip-path="url(#right-of-seam)"/>
    </g>
    </svg>

    """
}

/// Farthest stroke point from the canvas centre (the outer offset curve peaks at the major axis ends).
let outerExtent = simd_length(Emblem.centre - V2(repeating: Float(size) / 2)) + Emblem.semiAxes.y + Emblem.stroke / 2

func parametersJSON() -> String {
    func v2(_ v: V2, _ d: Int = 1) -> String { "[\(f(v.x, d)), \(f(v.y, d))]" }
    let l = Emblem.light
    let hs = halves.map {
        "    { \"name\" : \"\($0.name)\", \"layer\" : \"\($0.layer)\", \"side\" : \"\($0.side < 0 ? "left" : "right")\", \"base\" : \"\(hexString($0.base))\", \"deep\" : \"\(hexString($0.deep))\", \"lit\" : \"\(hexString($0.lit))\", \"preview_shift_px\" : \(f($0.previewShift, 1)) }"
    }
    return """
    {
      "generator" : "art/icon/generate_icon.swift",
      "design" : "Porcelain Split Oval",
      "canvas_px" : \(size),
      "back" : { "layer" : "Back", "lit" : "\(hexString(Field.lit))", "base" : "\(hexString(Field.base))", "edge" : "\(hexString(Field.edge))", "light_centre_px" : \(v2(Field.lightCentre)), "light_radius_px" : \(f(Field.lightRadius, 1)),
        "relief" : { "strength" : \(f(Field.reliefStrength, 3)), "sigma_px" : \(f(Field.reliefSigma, 1)), "offset_px" : \(v2(Field.reliefOffset)) }, "preview_shift_px" : \(f(Field.previewShift, 1)) },
      "emblem" : { "centre_px" : \(v2(Emblem.centre)), "semi_axes_px" : \(v2(Emblem.semiAxes)), "tilt_deg" : \(f(Emblem.tiltDegrees, 1)), "stroke_px" : \(f(Emblem.stroke, 1)), "seam_px" : \(f(Emblem.seam, 1)), "corner_radius_px" : \(f(Emblem.cornerRadius, 1)),
        "bevel" : \(f(Emblem.bevel, 3)), "light_dir" : [\(f(l.x, 4)), \(f(l.y, 4)), \(f(l.z, 4))], "outer_extent_px" : \(f(outerExtent, 1)) },
      "glaze" : { "colour" : "\(hexString(Glaze.colour))", "strength" : \(f(Glaze.strength, 3)), "exponent" : \(f(Glaze.exponent, 1)) },
      "halves" : [
    \(hs.joined(separator: ",\n"))
      ],
      "flat_contact_shadow" : { "colour" : "\(hexString(FlatShadow.colour))", "strength" : \(f(FlatShadow.strength, 3)), "sigma_px" : \(f(FlatShadow.sigma, 1)), "offset_px" : \(v2(FlatShadow.offset)) },
      "macos" : { "icns" : "art/icon/Portal2.icns", "inset_px" : \(f(Mac.inset, 1)), "corner_radius_px" : \(f(Mac.cornerRadius, 1)), "shadow_opacity" : \(f(Mac.shadowOpacity, 3)), "shadow_sigma_px" : \(f(Mac.shadowSigma, 1)), "shadow_offset_px" : \(f(Mac.shadowOffset, 1)), "sizes_px" : \(Mac.sizes) }
    }

    """
}

// MARK: - Contact sheet (preview only, never shipped)

func squircle(_ r: CGRect, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c),
                        y: r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func contactSheet(back: CGImage, middle: CGImage, front: CGImage, flat: CGImage, mac: [Int: CGImage]) -> CGImage {
    let W = 2280, H = 1480
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Layout in top-left coordinates.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: CGFloat(H) - y - h, width: w, height: h) }
    func fill(_ r: CGRect, _ g: CGFloat) {
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [g, g, g, 1])!)
        ctx.fill(r)
    }
    func clipped(_ path: CGPath, _ draw: () -> Void) { ctx.saveGState(); ctx.addPath(path); ctx.clip(); draw(); ctx.restoreGState() }
    func checker(_ r: CGRect, cell: CGFloat = 16) {
        fill(r, 0.80)
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.62, 0.62, 0.62, 1])!)
        var y: CGFloat = 0
        while y < r.height {
            var x: CGFloat = (Int(y / cell) % 2 == 0) ? 0 : cell
            while x < r.width { ctx.fill(CGRect(x: r.minX + x, y: r.minY + y, width: min(cell, r.width - x), height: min(cell, r.height - y))); x += 2 * cell }
            y += cell
        }
    }
    let light: CGFloat = 0.949, dark: CGFloat = 0.11
    fill(CGRect(x: 0, y: 0, width: W, height: H), 0.165)
    // Heroes on split light / dark grounds: iPad squircle, visionOS circle, macOS tile (its own padding).
    for i in 0..<3 {
        let x = CGFloat(i) * 760
        fill(rect(x, 0, 380, 700), light); fill(rect(x + 380, 0, 380, 700), dark)
        let hero = rect(x + 70, 40, 620, 620)
        switch i {
        case 0: clipped(squircle(hero)) { ctx.draw(flat, in: hero) }
        case 1: clipped(CGPath(ellipseIn: hero, transform: nil)) { ctx.draw(flat, in: hero) }
        default: ctx.draw(mac[1024]!, in: hero)
        }
    }
    // Back, Middle, Front (transparent layers over a checkerboard).
    for (i, img) in [back, middle, front].enumerated() {
        let r = rect(40 + CGFloat(i) * 280, 724, 256, 256)
        if i > 0 { checker(r) }
        ctx.draw(img, in: r)
    }
    // Simulated parallax in the circular mask: look left, up, rest, down, right.
    let shifts: [(CGImage, Float)] = [(back, Field.previewShift), (middle, halves[0].previewShift), (front, halves[1].previewShift)]
    for (i, look) in [(-1.0, 0.0), (0.0, -1.0), (0.0, 0.0), (0.0, 1.0), (1.0, 0.0)].enumerated() {
        let r = rect(40 + CGFloat(3 + i) * 280, 724, 256, 256)
        clipped(CGPath(ellipseIn: r, transform: nil)) {
            for (img, shift) in shifts {
                let s = r.width / 1024 * CGFloat(shift)
                ctx.draw(img, in: r.offsetBy(dx: CGFloat(look.0) * s, dy: -CGFloat(look.1) * s))
            }
        }
    }
    // Small sizes at 1:1 pixels on light and dark strips: iPad squircles, visionOS circles, native macOS renders.
    let sizes: [CGFloat] = [180, 120, 87, 60, 40, 29]
    for (row, shade) in [light, dark].enumerated() {
        let top = 1020 + CGFloat(row) * 230
        fill(rect(0, top, CGFloat(W), 230), shade)
        var x: CGFloat = 40
        for circle in [false, true] {
            for s in sizes {
                let r = rect(x, top + 25 + (180 - s) / 2, s, s)
                clipped(circle ? CGPath(ellipseIn: r, transform: nil) : squircle(r)) { ctx.draw(flat, in: r) }
                x += s + 24
            }
            x += 56
        }
        for s in [128, 64, 32, 16] {
            ctx.draw(mac[s]!, in: rect(x, top + 25 + (180 - CGFloat(s)) / 2, CGFloat(s), CGFloat(s)))
            x += CGFloat(s) + 24
        }
    }
    return ctx.makeImage()!
}

// MARK: - Main

let here = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
let root = here.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func at(_ path: String) -> URL { root.appendingPathComponent(path) }
let stack = "visionos/GameAssets.xcassets/AppIcon.solidimagestack"
let iosSet = "ios/Assets.xcassets/AppIcon.appiconset"
for catalog in [stack, "\(stack)/Back.solidimagestacklayer/Content.imageset", "\(stack)/Middle.solidimagestacklayer/Content.imageset",
                "\(stack)/Front.solidimagestacklayer/Content.imageset", iosSet] {
    guard FileManager.default.fileExists(atPath: at("\(catalog)/Contents.json").path) else {
        fatalError("run from the repository (missing \(catalog)/Contents.json under \(root.path))")
    }
}
let started = Date()
let layers = renderStack(size, ss: 4)
let backImage = makeImage(layers.back, alpha: false, dither: true)
let middleImage = makeImage(layers.middle, alpha: true, dither: false)
let frontImage = makeImage(layers.front, alpha: true, dither: false)
let flatImage = makeImage(flatten(layers), alpha: false, dither: true)
for (name, image) in [("Back", backImage), ("Middle", middleImage), ("Front", frontImage)] {
    writePNG(image, at("\(stack)/\(name).solidimagestacklayer/Content.imageset/\(name).png"))
}
writePNG(flatImage, at("\(iosSet)/AppIcon.png"))
writeText(svgReference(), at("art/icon/split-oval.svg"))
writeText(parametersJSON(), at("art/icon/parameters.json"))

// macOS: native renders at every iconset size, packed by iconutil.
var macImages = [Int: CGImage]()
for s in Mac.sizes { macImages[s] = makeImage(macIcon(s), alpha: true, dither: true) }
let iconset = at("build/porcelain-icon/Portal2.iconset")
try? FileManager.default.removeItem(at: iconset)
for points in [16, 32, 128, 256, 512] {
    writePNG(macImages[points]!, iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(macImages[points * 2]!, iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", at("art/icon/Portal2.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

if !CommandLine.arguments.contains("--no-preview") {
    writePNG(contactSheet(back: backImage, middle: middleImage, front: frontImage, flat: flatImage, mac: macImages),
             at("build/icon-preview/contact-sheet.png"))
}
print("oval: centre \(f(Emblem.centre.x)),\(f(Emblem.centre.y)) semi-axes \(f(Emblem.semiAxes.x))x\(f(Emblem.semiAxes.y)) tilt \(f(Emblem.tiltDegrees, 1))deg stroke \(f(Emblem.stroke, 1)) seam \(f(Emblem.seam, 1)) outer extent \(f(outerExtent, 1))")
print("icon written in \(f(Float(Date().timeIntervalSince(started)), 1)) s")
