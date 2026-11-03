// Twin Gateways: original app icon generator for the Portal 2 native Apple port.
//
// Every pixel written by this program is computed from the procedural geometry
// and colour constants below: a pinhole camera looking at a turned panel wall,
// two elliptical openings in that wall, analytic glows, and a seeded starfield.
// It reads no image, font, texture, model or other artwork. See PROVENANCE.md.
//
// Regenerate from the repository root (no network, Xcode command line tools only):
//
//   xcrun swiftc -O art/icon/generate_icon.swift -o "${TMPDIR:-/tmp}/p2-icongen" && "${TMPDIR:-/tmp}/p2-icongen"
//
// Writes (relative to the repository root):
//   visionos/GameAssets.xcassets/   AppIcon.solidimagestack (Back/Middle/Front, 1024 px each)
//   ios/Assets.xcassets/            AppIcon.appiconset (single 1024 px universal icon)
//   art/icon/twin-gateways.svg      vector reference of the main geometry
//   art/icon/parameters.json        every parameter and the derived screen-space ellipses
//   build/icon-preview/contact-sheet.png   masks, sizes, layers and parallax preview
// Pass --no-preview to skip the contact sheet.

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
func maxc(_ v: V3) -> Float { max(v.x, max(v.y, v.z)) }

/// Integer hash to [0, 1): panel tone variation and quantisation dither.
func hash3(_ a: Int32, _ b: Int32, _ c: Int32) -> Float {
    var h = UInt32(bitPattern: a) &* 0x9E37_79B1
    h ^= UInt32(bitPattern: b) &* 0x85EB_CA77
    h ^= UInt32(bitPattern: c) &* 0xC2B2_AE3D
    h ^= h >> 15; h &*= 0x2C1B_3C6D
    h ^= h >> 12; h &*= 0x297A_2D39
    h ^= h >> 15
    return Float(h >> 8) / Float(1 << 24)
}

/// Seeded linear congruential generator (Knuth MMIX constants) for the starfield.
struct LCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}

// MARK: - Parameters (icon space is 1024 x 1024 px, origin top-left, y down)

let size = 1024

/// Pinhole camera at the origin looking down +z at a wall turned about the vertical axis.
enum Camera {
    static let focal: Float = 1000          // px
    static let yawDegrees: Float = 30       // wall recedes to the right
    static let distance: Float = 1          // wall units, along the optical axis
    static let principal = V2(512, 470)     // eye level, a little above centre
    static var yaw: Float { yawDegrees * .pi / 180 }
}

/// The clean panel wall of the Middle layer (wall units).
enum Wall {
    static let panel: Float = 0.25              // square panels
    static let gridOrigin = V2(0.0775, -0.09)   // a vertical seam falls midway between the openings
    static let seamWidth: Float = 0.0034
    static let albedo: UInt32 = 0xD3DAE3        // cool off-white
    static let ambient: UInt32 = 0xF2F5FA
    static let fog: UInt32 = 0x161D2C           // distance haze toward the far end
    static let keyLight = V2(-0.62, 0.42)       // soft light pool, upper left (wall u, v)
    static let keyRadius: Float = 0.70
    static let toneJitter: Float = 0.07         // per-panel albedo variation (hash)
}

/// The deep field seen through the openings (Back layer).
enum Deep {
    static let inner: UInt32 = 0x0D1F4C          // deep navy centre
    static let outer: UInt32 = 0x02040C          // near-black edge
    static let centre = V2(560, 470)
    static let radius: Float = 760
    static let starSeed: UInt64 = 0x5EED_2B1C_0DE5
    static let starCount = 230
    // Faint nebula wisps: centre, sigma (x, y), rotation (deg), colour, linear intensity.
    static let wisps: [(V2, V2, Float, UInt32, Float)] = [
        (V2(300, 430), V2(150, 60), -28, 0x2C3C9E, 0.12),
        (V2(380, 640), V2(170, 70), 18, 0x16708F, 0.11),
        (V2(760, 420), V2(120, 50), 35, 0x0F5E86, 0.12),
        (V2(820, 600), V2(140, 55), -15, 0x3A2E86, 0.08),
        (V2(560, 300), V2(260, 80), 8, 0x23307A, 0.09),
    ]
}

struct Portal {
    let name: String
    let center: V2          // wall units (u to the right along the wall, v up)
    let semiAxes: V2        // wall units
    let rim: UInt32         // saturated rim colour
    let glow: UInt32        // deeper glow / light-spill colour
    let core: UInt32        // white-hot core line
    let beyond: UInt32      // light seen far beyond the opening (the linked side's colour)
    let phase: Float        // rim shimmer phase
}

/// Two linked openings of identical physical size; the far one reads smaller and narrower.
let portals = [
    Portal(name: "cyan", center: V2(-0.215, -0.10), semiAxes: V2(0.13, 0.215),
           rim: 0x2CC6FF, glow: 0x1690FF, core: 0xE9FBFF, beyond: 0xFFA24A, phase: 0.35),
    Portal(name: "amber", center: V2(0.370, 0.06), semiAxes: V2(0.13, 0.215),
           rim: 0xFFA11F, glow: 0xFF5A0A, core: 0xFFF6E6, beyond: 0x45C8FF, phase: 2.10),
]

/// Rim, halo and spill profile (screen px at depth 1, scaled by 1/depth).
enum Light {
    static let coreWidth: Float = 3.3
    static let bandWidth: Float = 13
    static let haloNear: Float = 30, haloFar: Float = 125
    static let hazeNear: Float = 34, hazeFar: Float = 115
    static let spillNear: Float = 0.36, spillFar: Float = 1.1   // wall, in ellipse radii
    static let spillStrength: Float = 1.0
}

// MARK: - Perspective (wall <-> screen)

let cosY = cosf(Camera.yaw), sinY = sinf(Camera.yaw)

/// Screen pixel -> (u, v, depth) on the wall plane.
@inline(__always) func wallPoint(_ x: Float, _ y: Float) -> (Float, Float, Float) {
    let a = (x - Camera.principal.x) / Camera.focal
    let b = (Camera.principal.y - y) / Camera.focal
    let t = Camera.distance * cosY / (cosY - a * sinY)
    return (t * a * cosY + (t - Camera.distance) * sinY, t * b, t)
}

/// Wall (u, v) -> screen pixel.
func project(_ u: Float, _ v: Float) -> V2 {
    let z = Camera.distance + u * sinY
    return V2(Camera.principal.x + Camera.focal * u * cosY / z, Camera.principal.y - Camera.focal * v / z)
}

/// Exact screen-space ellipse of a wall ellipse: transform the conic by the homography.
struct ScreenEllipse {
    let center: V2, radii: V2, angle: Float, depth: Float
    var cosA: Float { cosf(angle) }
    var sinA: Float { sinf(angle) }
}

func screenEllipse(_ p: Portal) -> ScreenEllipse {
    let F = Double(Camera.focal), D = Double(Camera.distance)
    let cx = Double(Camera.principal.x), cy = Double(Camera.principal.y)
    let c = Double(cosY), s = Double(sinY)
    let h = simd_double3x3(rows: [SIMD3(F * c + cx * s, 0, cx * D), SIMD3(cy * s, -F, cy * D), SIMD3(s, 0, D)])
    let u0 = Double(p.center.x), v0 = Double(p.center.y)
    let ia = 1 / Double(p.semiAxes.x * p.semiAxes.x), ib = 1 / Double(p.semiAxes.y * p.semiAxes.y)
    let cw = simd_double3x3(rows: [SIMD3(ia, 0, -u0 * ia), SIMD3(0, ib, -v0 * ib),
                                   SIMD3(-u0 * ia, -v0 * ib, u0 * u0 * ia + v0 * v0 * ib - 1)])
    let hi = h.inverse
    var m = hi.transpose * cw * hi
    let (a, b, cc, d, e) = (m[0][0], m[1][0], m[1][1], m[2][0], m[2][1])
    let det = a * cc - b * b
    let x0 = (b * e - cc * d) / det, y0 = (b * d - a * e) / det
    var f0 = m[2][2] + d * x0 + e * y0
    var (qa, qb, qc) = (a, b, cc)
    if f0 > 0 { f0 = -f0; qa = -qa; qb = -qb; qc = -qc; m = -1 * m }
    let mean = (qa + qc) / 2, diff = sqrt(((qa - qc) / 2) * ((qa - qc) / 2) + qb * qb)
    let angle = 0.5 * atan2(2 * qb, qa - qc)
    let rShort = sqrt(-f0 / (mean + diff)), rLong = sqrt(-f0 / (mean - diff))
    return ScreenEllipse(center: V2(Float(x0), Float(y0)), radii: V2(Float(rShort), Float(rLong)),
                         angle: Float(angle), depth: Camera.distance + p.center.x * sinY)
}

let ellipses = portals.map(screenEllipse)

/// Signed distance (px) to an axis-aligned ellipse, Quilez's first-order approximation.
@inline(__always) func ellipseDistance(_ q: V2, _ r: V2) -> Float {
    let k1 = simd_length(q / (r * r))
    if k1 < 1e-6 { return -min(r.x, r.y) }
    let k0 = simd_length(q / r)
    return k0 * (k0 - 1) / k1
}

// MARK: - Layer shaders (linear light)

let wallAlbedo = hex(Wall.albedo), wallAmbient = hex(Wall.ambient), wallFog = hex(Wall.fog)
let rimColors = portals.map { hex($0.rim) }, glowColors = portals.map { hex($0.glow) }
let coreColors = portals.map { hex($0.core) }, beyondColors = portals.map { hex($0.beyond) }

/// Middle layer: the panel wall with two openings cut through it. Returns colour and coverage.
@inline(__always) func wallSample(_ x: Float, _ y: Float) -> (V3, Float) {
    let (u, v, depth) = wallPoint(x, y)
    var coverage: Float = 1
    var light = V3(repeating: 0)
    for (i, p) in portals.enumerated() {
        let du = (u - p.center.x) / p.semiAxes.x, dv = (v - p.center.y) / p.semiAxes.y
        let r = sqrtf(du * du + dv * dv)
        if r < 1 { coverage = 0 }
        let out = max(0, r - 1)
        light += glowColors[i] * (Light.spillStrength * (0.90 * expf(-out / Light.spillNear) + 0.10 * expf(-out / Light.spillFar)))
    }
    // Panels: seams, a soft bevel (top edges catch the light), per-panel tone.
    let gu = (u - Wall.gridOrigin.x) / Wall.panel, gv = (v - Wall.gridOrigin.y) / Wall.panel
    let iu = floorf(gu), iv = floorf(gv)
    let fu = gu - iu, fv = gv - iv
    let edge = min(min(fu, 1 - fu), min(fv, 1 - fv)) * Wall.panel
    let seamCore = edge / Wall.seamWidth
    var shade: Float = 1 - 0.42 * expf(-seamCore * seamCore) - 0.06 * expf(-edge / 0.016)
    shade *= 1 + 0.09 * expf(-(1 - fv) * Wall.panel / 0.010) - 0.07 * expf(-fv * Wall.panel / 0.010)
    shade *= 1 + (hash3(Int32(iu), Int32(iv), 7) - 0.5) * Wall.toneJitter
    // Key light pool, gentle top-to-bottom falloff.
    let kd = V2(u, v) - Wall.keyLight
    let key = 0.20 + 0.98 * expf(-simd_length_squared(kd) / (2 * Wall.keyRadius * Wall.keyRadius))
    let vertical = 0.86 + 0.14 * smoothstep(-0.9, 0.5, v)
    var colour = wallAlbedo * shade * (wallAmbient * (key * vertical) + light)
    // Distance haze: the wall darkens toward the far end, which makes the far rim pop.
    let fog = (1 - expf(-max(0, depth - 0.80) * 2.0)) * 0.86
    colour = mix(colour, wallFog, fog)
    return (colour, coverage)
}

/// Front layer: luminous rims, outer halo and inner haze (emitted light, linear).
@inline(__always) func rimEmission(_ x: Float, _ y: Float) -> V3 {
    var e = V3(repeating: 0)
    for (i, el) in ellipses.enumerated() {
        let p = V2(x, y) - el.center
        let q = V2(p.x * el.cosA + p.y * el.sinA, -p.x * el.sinA + p.y * el.cosA)
        let d = ellipseDistance(q, el.radii) * el.depth
        let phi = atan2f(q.y / el.radii.y, q.x / el.radii.x)
        let ph = portals[i].phase
        let shimmer = 1 + 0.16 * sinf(3 * phi + ph) + 0.09 * sinf(5 * phi + 2.3 * ph) + 0.05 * sinf(9 * phi + 0.7 + ph)
        let core = expf(-(d / Light.coreWidth) * (d / Light.coreWidth))
        let band = expf(-(d / Light.bandWidth) * (d / Light.bandWidth))
        let halo = d > 0
            ? 0.50 * expf(-d / Light.haloNear) + 0.20 * expf(-d / Light.haloFar)
            : 0.55 * expf(d / Light.hazeNear) + 0.12 * expf(d / Light.hazeFar)
        e += coreColors[i] * (core * 1.9)
        e += rimColors[i] * (band * 1.45 * shimmer)
        e += glowColors[i] * (halo * (0.85 + 0.15 * shimmer))
    }
    return e
}

/// Back layer: deep indigo field, faint wisps, and the linked side's light far beyond each opening.
func deepField(_ x: Float, _ y: Float) -> V3 {
    let r = simd_length(V2(x, y) - Deep.centre)
    var c = mix(hex(Deep.inner), hex(Deep.outer), smoothstep(0, Deep.radius, r))
    for (centre, sigma, deg, colour, k) in Deep.wisps {
        let a = deg * .pi / 180
        let p = V2(x, y) - centre
        let q = V2(p.x * cosf(a) + p.y * sinf(a), -p.x * sinf(a) + p.y * cosf(a)) / sigma
        c += hex(colour) * (k * expf(-0.5 * simd_length_squared(q)))
    }
    for (i, el) in ellipses.enumerated() {
        // Seen deeper than the wall, so the glow sits toward the vanishing point.
        let s = 1 / el.depth
        let p = V2(x, y) - (el.center + V2(26 * s, -14 * s))
        let d2 = simd_length_squared(p)
        let w1 = 80 * s, w2 = 190 * s
        c += beyondColors[i] * (0.08 * expf(-d2 / (2 * w1 * w1)) + 0.05 * expf(-d2 / (2 * w2 * w2)))
    }
    return c
}

// MARK: - Rendering

func parallelRows(_ height: Int, _ body: (Int) -> Void) {
    DispatchQueue.concurrentPerform(iterations: height) { body($0) }
}

/// A layer in straight (non-premultiplied) sRGB-encoded floats.
struct Layer {
    var rgb: [V3]
    var alpha: [Float]
}

func renderBack() -> Layer {
    var lin = [V3](repeating: .zero, count: size * size)
    lin.withUnsafeMutableBufferPointer { buf in
        let out = buf.baseAddress!
        parallelRows(size) { y in
            for x in 0..<size {
                // 2x2 supersampling; the field is smooth.
                var c = V3(repeating: 0)
                for sy in 0..<2 { for sx in 0..<2 {
                    c += deepField(Float(x) + 0.25 + 0.5 * Float(sx), Float(y) + 0.25 + 0.5 * Float(sy))
                } }
                out[y * size + x] = c * 0.25
            }
        }
    }
    // Stars: splatted Gaussians, seeded, mostly faint, a few with a soft halo.
    var rng = LCG(state: Deep.starSeed)
    for _ in 0..<Deep.starCount {
        let sx = rng.next() * Float(size), sy = rng.next() * Float(size)
        let m = rng.next()
        let brightness = 0.12 + 1.6 * powf(m, 7)
        let sigma = 0.55 + 0.9 * rng.next()
        let tint = mix(hex(0xBFD9FF), hex(0xFFE6C2), rng.next())
        let halo: Float = m > 0.94 ? 0.10 : 0
        let reach = Int(ceilf(halo > 0 ? 14 : sigma * 4))
        for py in max(0, Int(sy) - reach)...min(size - 1, Int(sy) + reach) {
            for px in max(0, Int(sx) - reach)...min(size - 1, Int(sx) + reach) {
                let d2 = (Float(px) + 0.5 - sx) * (Float(px) + 0.5 - sx) + (Float(py) + 0.5 - sy) * (Float(py) + 0.5 - sy)
                let k = brightness * expf(-d2 / (2 * sigma * sigma)) + halo * expf(-d2 / (2 * 4.5 * 4.5))
                lin[py * size + px] += tint * k
            }
        }
    }
    return Layer(rgb: lin.map { V3(toSRGB($0.x), toSRGB($0.y), toSRGB($0.z)) },
                 alpha: [Float](repeating: 1, count: size * size))
}

func renderMiddle() -> Layer {
    var layer = Layer(rgb: [V3](repeating: .zero, count: size * size), alpha: [Float](repeating: 0, count: size * size))
    let n = 4  // 4x4 supersampling: crisp seams and opening edges
    layer.rgb.withUnsafeMutableBufferPointer { rgb in
        layer.alpha.withUnsafeMutableBufferPointer { alpha in
            let rgbOut = rgb.baseAddress!, alphaOut = alpha.baseAddress!
            parallelRows(size) { y in
                for x in 0..<size {
                    var premult = V3(repeating: 0), cover: Float = 0
                    for sy in 0..<n { for sx in 0..<n {
                        let (c, k) = wallSample(Float(x) + (Float(sx) + 0.5) / Float(n), Float(y) + (Float(sy) + 0.5) / Float(n))
                        premult += c * k; cover += k
                    } }
                    cover /= Float(n * n)
                    let c = cover > 0 ? premult / (cover * Float(n * n)) : V3(repeating: 0)
                    rgbOut[y * size + x] = V3(toSRGB(c.x), toSRGB(c.y), toSRGB(c.z))
                    alphaOut[y * size + x] = cover
                }
            }
        }
    }
    return layer
}

func renderFront() -> Layer {
    var layer = Layer(rgb: [V3](repeating: .zero, count: size * size), alpha: [Float](repeating: 0, count: size * size))
    let n = 3
    layer.rgb.withUnsafeMutableBufferPointer { rgb in
        layer.alpha.withUnsafeMutableBufferPointer { alpha in
            let rgbOut = rgb.baseAddress!, alphaOut = alpha.baseAddress!
            parallelRows(size) { y in
                for x in 0..<size {
                    var e = V3(repeating: 0)
                    for sy in 0..<n { for sx in 0..<n {
                        e += rimEmission(Float(x) + (Float(sx) + 0.5) / Float(n), Float(y) + (Float(sy) + 0.5) / Float(n))
                    } }
                    e /= Float(n * n)
                    // Emitted light as an "over" layer: alpha from the strongest channel.
                    let a = min(1, maxc(e))
                    let c = a > 1e-5 ? e / a : V3(repeating: 0)
                    rgbOut[y * size + x] = V3(toSRGB(c.x), toSRGB(c.y), toSRGB(c.z))
                    alphaOut[y * size + x] = a < 1.0 / 512 ? 0 : a
                }
            }
        }
    }
    return layer
}

/// Source-over in sRGB space, as the platforms composite icon layers.
func over(_ top: Layer, _ bottom: Layer) -> Layer {
    var out = bottom
    for i in 0..<(size * size) {
        let a = top.alpha[i], b = bottom.alpha[i]
        let oa = a + b * (1 - a)
        out.alpha[i] = oa
        out.rgb[i] = oa > 0 ? (top.rgb[i] * a + bottom.rgb[i] * b * (1 - a)) / oa : V3(repeating: 0)
    }
    return out
}

/// 8-bit RGBA. Opaque images get a +-0.5 LSB triangular dither against banding in the dark gradients.
func quantize(_ layer: Layer, width: Int, height: Int, dither: Bool) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) {
        let a = layer.alpha[i]
        let x = Int32(i % width), y = Int32(i / width)
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

func makeImage(_ bytes: [UInt8], _ width: Int, _ height: Int, alpha: Bool) -> CGImage {
    let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast).rawValue)
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
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

// MARK: - Asset catalogs

let xcodeInfo = "\"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }"
let catalogRoot = "{\n  \(xcodeInfo)\n}\n"

func writeVisionCatalog(_ root: URL, _ layers: [(String, CGImage)]) {
    let catalog = root.appendingPathComponent("visionos/GameAssets.xcassets")
    writeText(catalogRoot, catalog.appendingPathComponent("Contents.json"))
    let stack = catalog.appendingPathComponent("AppIcon.solidimagestack")
    let list = layers.map { "    {\n      \"filename\" : \"\($0.0).solidimagestacklayer\"\n    }" }.joined(separator: ",\n")
    writeText("{\n  \(xcodeInfo),\n  \"layers\" : [\n\(list)\n  ]\n}\n", stack.appendingPathComponent("Contents.json"))
    for (name, image) in layers {
        let layer = stack.appendingPathComponent("\(name).solidimagestacklayer")
        writeText(catalogRoot, layer.appendingPathComponent("Contents.json"))
        let set = layer.appendingPathComponent("Content.imageset")
        writeText("""
        {
          "images" : [
            {
              "filename" : "\(name).png",
              "idiom" : "vision",
              "scale" : "2x"
            }
          ],
          \(xcodeInfo)
        }

        """, set.appendingPathComponent("Contents.json"))
        writePNG(image, set.appendingPathComponent("\(name).png"))
    }
}

func writeIOSCatalog(_ root: URL, _ icon: CGImage) {
    let catalog = root.appendingPathComponent("ios/Assets.xcassets")
    writeText(catalogRoot, catalog.appendingPathComponent("Contents.json"))
    let set = catalog.appendingPathComponent("AppIcon.appiconset")
    writeText("""
    {
      "images" : [
        {
          "filename" : "AppIcon.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      \(xcodeInfo)
    }

    """, set.appendingPathComponent("Contents.json"))
    writePNG(icon, set.appendingPathComponent("AppIcon.png"))
}

// MARK: - SVG reference and parameter record

func f(_ v: Float, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

func svgReference() -> String {
    var s = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    <!-- Twin Gateways: vector reference of the main geometry, written by art/icon/generate_icon.swift.
         Original procedural geometry only: perspective panel wall, two elliptical openings, glows.
         The shipped PNGs are the per-pixel renders; this file is for review. -->
    <defs>
      <radialGradient id="deep" cx="\(f(Deep.centre.x))" cy="\(f(Deep.centre.y))" r="\(f(Deep.radius))" gradientUnits="userSpaceOnUse">
        <stop offset="0" stop-color="\(hexString(Deep.inner))"/><stop offset="1" stop-color="\(hexString(Deep.outer))"/>
      </radialGradient>
      <linearGradient id="wall" x1="0" y1="0" x2="1024" y2="640" gradientUnits="userSpaceOnUse">
        <stop offset="0" stop-color="\(hexString(Wall.albedo))"/><stop offset="0.55" stop-color="#A6ADBA"/><stop offset="1" stop-color="#474D5B"/>
      </linearGradient>
      <filter id="halo" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="22"/></filter>
      <filter id="band" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter>
    </defs>
    <rect width="1024" height="1024" fill="url(#wall)"/>
    <g id="seams" stroke="#5C6573" stroke-width="2" stroke-opacity="0.55" fill="none">

    """
    // Vertical seams stay vertical; horizontal seams are straight lines converging to the vanishing point.
    let (uMin, _, _) = wallPoint(0, 512), (uMax, _, _) = wallPoint(1024, 512)
    var k = ceilf((uMin - Wall.gridOrigin.x) / Wall.panel)
    while Wall.gridOrigin.x + k * Wall.panel <= uMax {
        let x = project(Wall.gridOrigin.x + k * Wall.panel, 0).x
        s += "  <line x1=\"\(f(x))\" y1=\"0\" x2=\"\(f(x))\" y2=\"1024\"/>\n"
        k += 1
    }
    for j in -6...4 {
        let v = Wall.gridOrigin.y + Float(j) * Wall.panel
        let (u0, _, _) = wallPoint(0, 512), (u1, _, _) = wallPoint(1024, 512)
        let a = project(u0, v), b = project(u1, v)
        s += "  <line x1=\"\(f(a.x))\" y1=\"\(f(a.y))\" x2=\"\(f(b.x))\" y2=\"\(f(b.y))\"/>\n"
    }
    s += "</g>\n"
    for (i, el) in ellipses.enumerated() {
        let p = portals[i]
        let tf = "rotate(\(f(el.angle * 180 / .pi, 3)) \(f(el.center.x)) \(f(el.center.y)))"
        let e = "cx=\"\(f(el.center.x))\" cy=\"\(f(el.center.y))\" rx=\"\(f(el.radii.x))\" ry=\"\(f(el.radii.y))\" transform=\"\(tf)\""
        s += """
        <g id="\(p.name)-opening">
          <ellipse \(e) fill="url(#deep)"/>
          <ellipse \(e) fill="none" stroke="\(hexString(p.glow))" stroke-width="\(f(60 / el.depth))" stroke-opacity="0.55" filter="url(#halo)"/>
          <ellipse \(e) fill="none" stroke="\(hexString(p.rim))" stroke-width="\(f(16 / el.depth))" filter="url(#band)"/>
          <ellipse \(e) fill="none" stroke="\(hexString(p.core))" stroke-width="\(f(4 / el.depth))"/>
        </g>

        """
    }
    return s + "</svg>\n"
}

func parametersJSON() -> String {
    func v2(_ v: V2, _ d: Int = 4) -> String { "[\(f(v.x, d)), \(f(v.y, d))]" }
    var lines = [String]()
    lines.append("  \"generator\" : \"art/icon/generate_icon.swift\",")
    lines.append("  \"canvas_px\" : \(size),")
    lines.append("  \"camera\" : { \"focal_px\" : \(f(Camera.focal)), \"wall_yaw_deg\" : \(f(Camera.yawDegrees)), \"distance\" : \(f(Camera.distance)), \"principal_px\" : \(v2(Camera.principal, 1)) },")
    lines.append("  \"wall\" : { \"panel\" : \(f(Wall.panel, 4)), \"grid_origin\" : \(v2(Wall.gridOrigin)), \"seam_width\" : \(f(Wall.seamWidth, 4)), \"albedo\" : \"\(hexString(Wall.albedo))\", \"ambient\" : \"\(hexString(Wall.ambient))\", \"fog\" : \"\(hexString(Wall.fog))\", \"key_light_uv\" : \(v2(Wall.keyLight)), \"key_radius\" : \(f(Wall.keyRadius, 3)), \"tone_jitter\" : \(f(Wall.toneJitter, 3)) },")
    let wisps = Deep.wisps.map { "{ \"centre_px\" : \(v2($0.0, 1)), \"sigma_px\" : \(v2($0.1, 1)), \"rotation_deg\" : \(f($0.2, 1)), \"colour\" : \"\(hexString($0.3))\", \"intensity\" : \(f($0.4, 3)) }" }
    lines.append("  \"deep_field\" : { \"inner\" : \"\(hexString(Deep.inner))\", \"outer\" : \"\(hexString(Deep.outer))\", \"centre_px\" : \(v2(Deep.centre, 1)), \"radius_px\" : \(f(Deep.radius, 1)), \"star_seed\" : \"0x\(String(Deep.starSeed, radix: 16, uppercase: true))\", \"star_count\" : \(Deep.starCount),")
    lines.append("    \"wisps\" : [\n      " + wisps.joined(separator: ",\n      ") + "\n    ] },")
    lines.append("  \"light\" : { \"core_width_px\" : \(f(Light.coreWidth)), \"band_width_px\" : \(f(Light.bandWidth)), \"halo_px\" : [\(f(Light.haloNear)), \(f(Light.haloFar))], \"haze_px\" : [\(f(Light.hazeNear)), \(f(Light.hazeFar))], \"spill_radii\" : [\(f(Light.spillNear)), \(f(Light.spillFar))], \"spill_strength\" : \(f(Light.spillStrength)) },")
    var ps = [String]()
    for (i, p) in portals.enumerated() {
        let el = ellipses[i]
        ps.append("""
            { "name" : "\(p.name)", "wall_centre" : \(v2(p.center)), "wall_semi_axes" : \(v2(p.semiAxes)), "rim" : "\(hexString(p.rim))", "glow" : "\(hexString(p.glow))", "core" : "\(hexString(p.core))", "beyond" : "\(hexString(p.beyond))", "shimmer_phase" : \(f(p.phase, 3)),
              "screen" : { "centre_px" : \(v2(el.center, 2)), "radii_px" : \(v2(el.radii, 2)), "rotation_deg" : \(f(el.angle * 180 / .pi, 3)), "depth" : \(f(el.depth, 4)) } }
        """)
    }
    lines.append("  \"portals\" : [\n" + ps.joined(separator: ",\n") + "\n  ]")
    return "{\n" + lines.joined(separator: "\n") + "\n}\n"
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

func contactSheet(back: CGImage, middle: CGImage, front: CGImage, flat: CGImage) -> CGImage {
    let W = 1960, H = 1624
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Layout in top-left coordinates.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: CGFloat(H) - y - h, width: w, height: h) }
    func fill(_ r: CGRect, _ g: CGFloat, _ b: CGFloat? = nil) {
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [g, g, b ?? g, 1])!)
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
    fill(CGRect(x: 0, y: 0, width: W, height: H), 0.165, 0.18)
    // (b, c) iOS squircle at 1024 over a split light / dark backdrop.
    fill(rect(0, 0, 552, 1104), light); fill(rect(552, 0, 552, 1104), dark)
    let hero = rect(40, 40, 1024, 1024)
    clipped(squircle(hero)) { ctx.draw(flat, in: hero) }
    // (a) visionOS circular mask, then its three layers (Middle and Front over a checkerboard).
    let col: CGFloat = 1104 + 40
    let vision = rect(col + 148, 40, 520, 520)
    clipped(CGPath(ellipseIn: vision, transform: nil)) { ctx.draw(flat, in: vision) }
    for (i, img) in [back, middle, front].enumerated() {
        let r = rect(col + CGFloat(i) * 280, 584, 256, 256)
        if i > 0 { checker(r) }
        ctx.draw(img, in: r)
    }
    // (d) simulated parallax: look left, rest, look right (layers scaled 6 % and shifted by depth).
    for (i, k) in [-1.0, 0.0, 1.0].enumerated() {
        let r = rect(col + CGFloat(i) * 280, 864, 256, 256)
        clipped(CGPath(ellipseIn: r, transform: nil)) {
            for (img, shift) in [(back, -12.0), (middle, 5.0), (front, 18.0)] {
                let s = r.width / 1024
                let grow = r.width * 0.06
                ctx.draw(img, in: r.insetBy(dx: -grow / 2, dy: -grow / 2).offsetBy(dx: CGFloat(k * shift) * s, dy: 0))
            }
        }
    }
    // (c) size ladder on light and dark strips: iOS squircles, then visionOS circles, 1:1 pixels.
    let sizes: [CGFloat] = [180, 120, 87, 60, 40, 29]
    for (row, shade) in [light, dark].enumerated() {
        let top = 1144 + CGFloat(row) * 220
        fill(rect(0, top, CGFloat(W), 220), shade)
        var x: CGFloat = 40
        for circle in [false, true] {
            for s in sizes {
                let r = rect(x, top + 20 + (180 - s) / 2, s, s)
                let path = circle ? CGPath(ellipseIn: r, transform: nil) : squircle(r)
                clipped(path) { ctx.draw(flat, in: r) }
                x += s + 28
            }
            x += 72
        }
    }
    return ctx.makeImage()!
}

// MARK: - Main

let here = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
let root = here.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("visionos/project.yml").path) else {
    fatalError("run from the repository (could not locate visionos/project.yml under \(root.path))")
}
let started = Date()
let back = renderBack(), middle = renderMiddle(), front = renderFront()
let flat = over(front, over(middle, back))
let backImage = makeImage(quantize(back, width: size, height: size, dither: true), size, size, alpha: false)
let middleImage = makeImage(quantize(middle, width: size, height: size, dither: false), size, size, alpha: true)
let frontImage = makeImage(quantize(front, width: size, height: size, dither: false), size, size, alpha: true)
let flatImage = makeImage(quantize(flat, width: size, height: size, dither: true), size, size, alpha: false)

writeVisionCatalog(root, [("Front", frontImage), ("Middle", middleImage), ("Back", backImage)])
writeIOSCatalog(root, flatImage)
writeText(svgReference(), root.appendingPathComponent("art/icon/twin-gateways.svg"))
writeText(parametersJSON(), root.appendingPathComponent("art/icon/parameters.json"))
if !CommandLine.arguments.contains("--no-preview") {
    writePNG(contactSheet(back: backImage, middle: middleImage, front: frontImage, flat: flatImage),
             root.appendingPathComponent("build/icon-preview/contact-sheet.png"))
}
for (p, el) in zip(portals, ellipses) {
    print("\(p.name): centre \(f(el.center.x)),\(f(el.center.y)) radii \(f(el.radii.x))x\(f(el.radii.y)) rot \(f(el.angle * 180 / .pi, 3))deg depth \(f(el.depth, 3))")
}
print("icon written in \(f(Float(Date().timeIntervalSince(started)), 1)) s")
