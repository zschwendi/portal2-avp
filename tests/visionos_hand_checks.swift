// Host checks for visionos/Sources/PortalHandGestures.swift. Built and run by
// tests/test_visionos_hands.py; synthetic joint positions, no ARKit.
import Foundation
import simd

func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-3) -> Bool { abs(a - b) <= tolerance }
func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tolerance: Float = 1e-3) -> Bool { simd_length(a - b) <= tolerance }

func head(yaw degrees: Float = 0, pitch pitchDegrees: Float = 0) -> simd_float4x4 {
    let yaw = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0))
    let pitch = simd_quatf(angle: pitchDegrees * .pi / 180, axis: SIMD3(1, 0, 0))
    var m = simd_float4x4(yaw * pitch)
    m.columns.3 = SIMD4(0, 1.6, 0, 1)
    return m
}

// Palm-down hand with fingers forward (-Z), thumb toward the body midline.
// palmUp mirrors the knuckles so the palm faces up toward the head.
func hand(_ side: PortalHandGestures.Side, at wrist: SIMD3<Float> = SIMD3(0, 1.0, -0.35),
          index: Float = 0.08, middle: Float = 0.09, palmUp: Bool = false) -> PortalHandSample {
    let inward: Float = (side == .right) != palmUp ? -1 : 1
    let thumb = wrist + SIMD3(inward * 0.04, 0, -0.1)
    return PortalHandSample(wrist: wrist, thumbTip: thumb,
                            indexTip: thumb + SIMD3(0, 0, -index),
                            middleTip: thumb + SIMD3(-inward * middle, 0, 0),
                            indexKnuckle: wrist + SIMD3(inward * 0.02, 0, -0.08),
                            littleKnuckle: wrist + SIMD3(-inward * 0.03, 0, -0.07))
}

func frame(_ time: Double, head h: simd_float4x4? = head(), left: PortalHandSample? = nil,
           right: PortalHandSample? = nil) -> PortalHandFrame {
    PortalHandFrame(time: time, head: h, left: left, right: right)
}

@main struct HandChecks {
static func main() {
var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL line \(line): \(message)") }
}
let config = PortalHandConfig()

// Pinch hysteresis: engage below 2.5 cm, hold to 4 cm, release above.
do {
    var pinch = PortalPinch()
    check(!pinch.update(distance: 0.03, closest: true, time: 0, config: config), "3 cm must not engage")
    check(pinch.update(distance: 0.02, closest: true, time: 0, config: config), "2 cm engages")
    check(pinch.update(distance: 0.035, closest: true, time: 0, config: config), "3.5 cm stays held")
    check(!pinch.update(distance: 0.045, closest: true, time: 0, config: config), "4.5 cm releases")
    check(!pinch.update(distance: 0.03, closest: true, time: 0, config: config), "re-engage needs < engage")
    check(!pinch.update(distance: 0.01, closest: false, time: 0, config: config), "a farther finger never engages")
    check(pinch.update(distance: 0.01, closest: true, time: 0, config: config), "closest finger engages")
    pinch.cancel()
    check(!pinch.held && pinch.blocked, "cancel releases and blocks")
    check(!pinch.update(distance: 0.01, closest: true, time: 0, config: config), "blocked until opened")
    check(!pinch.update(distance: 0.05, closest: true, time: 0, config: config), "opening unblocks")
    check(pinch.update(distance: 0.01, closest: true, time: 0, config: config), "fresh pinch after reopening")
}

// Radial deadzone and full deflection.
do {
    check(PortalHandStick.deflection(SIMD2(0, 0.019), config: config) == .zero, "inside deadzone")
    check(PortalHandStick.deflection(SIMD2(0, 0.02), config: config) == .zero, "deadzone edge")
    check(near(PortalHandStick.deflection(SIMD2(0, 0.07), config: config), SIMD2(0, 0.5)), "half deflection")
    check(near(PortalHandStick.deflection(SIMD2(0.12, 0), config: config), SIMD2(1, 0)), "full deflection at 12 cm")
    check(near(PortalHandStick.deflection(SIMD2(0, -0.3), config: config), SIMD2(0, -1)), "clamped beyond 12 cm")
    let diagonal = PortalHandStick.deflection(SIMD2(0.1, 0.1), config: config)
    check(near(diagonal.x, diagonal.y) && near(simd_length(diagonal), 1), "direction preserved, radial clamp")
}

// Head-yaw frame, including straight up/down.
do {
    let level = PortalHandStick.yawBasis(head())!
    check(near(simd_distance(level.forward, SIMD3(0, 0, -1)), 0) && near(simd_distance(level.right, SIMD3(1, 0, 0)), 0), "level basis")
    let turned = PortalHandStick.yawBasis(head(yaw: 90))!
    check(near(simd_distance(turned.forward, SIMD3(-1, 0, 0)), 0), "yaw 90 left faces -X")
    let down = PortalHandStick.yawBasis(head(yaw: 90, pitch: -90))!
    check(near(simd_distance(down.forward, SIMD3(-1, 0, 0)), 0), "looking straight down keeps yaw")
    let up = PortalHandStick.yawBasis(head(pitch: 89.9))!
    check(near(simd_distance(up.forward, SIMD3(0, 0, -1)), 0), "looking straight up keeps yaw")
}

// Left index pinch is a virtual stick: anchor, displacement, release, re-anchor.
do {
    var gestures = PortalHandGestures()
    let start = SIMD3<Float>(0, 1.0, -0.35)
    var out = gestures.update(frame(0, left: hand(.left, at: start, index: 0.06)))
    check(out.isNeutral, "open hand is neutral")
    out = gestures.update(frame(0.016, left: hand(.left, at: start, index: 0.015)))
    check(out.move == .zero, "pinch start anchors at zero")
    out = gestures.update(frame(0.033, left: hand(.left, at: start + SIMD3(0, 0, -0.07), index: 0.015)))
    check(near(out.move, SIMD2(0, 0.5)), "7 cm forward is half forward: \(out.move)")
    out = gestures.update(frame(0.05, left: hand(.left, at: start + SIMD3(0.2, 0.1, -0.07), index: 0.015)))
    check(near(simd_length(out.move), 1) && out.move.x > 0.9, "far right is full right; height ignored: \(out.move)")
    // A head turn after anchoring does not steer the walk.
    out = gestures.update(frame(0.066, head: head(yaw: 90), left: hand(.left, at: start + SIMD3(0, 0, -0.07), index: 0.015)))
    check(near(out.move, SIMD2(0, 0.5)), "anchor-time yaw frame is kept: \(out.move)")
    out = gestures.update(frame(0.083, left: hand(.left, at: start + SIMD3(0, 0, -0.07), index: 0.05)))
    check(out.isNeutral, "release is neutral")
    let moved = start + SIMD3(0, 0, -0.07)
    out = gestures.update(frame(0.1, left: hand(.left, at: moved, index: 0.015)))
    check(out.move == .zero, "new pinch re-anchors where it starts")
    out = gestures.update(frame(0.116, head: head(yaw: 90), left: hand(.left, at: moved + SIMD3(-0.12, 0, 0), index: 0.015)))
    check(near(out.move, SIMD2(-1, 0)), "frame captured at pinch start (level), not the new head yaw: \(out.move)")
    // New pinch with the head turned left: -X is forward.
    _ = gestures.update(frame(0.13, head: head(yaw: 90), left: hand(.left, at: moved, index: 0.06)))
    _ = gestures.update(frame(0.15, head: head(yaw: 90), left: hand(.left, at: moved, index: 0.015)))
    out = gestures.update(frame(0.166, head: head(yaw: 90), left: hand(.left, at: moved + SIMD3(-0.12, 0, 0), index: 0.015)))
    check(near(out.move, SIMD2(0, 1)), "displacement measured in head-yaw frame: \(out.move)")
}

// Fire, secondary fire and jump; finger exclusivity.
do {
    var gestures = PortalHandGestures()
    var out = gestures.update(frame(0, left: hand(.left), right: hand(.right, index: 0.015)))
    check(out.primary == 1 && out.secondary == 0 && !out.jump, "right index pinch fires blue")
    out = gestures.update(frame(0.016, left: hand(.left), right: hand(.right, index: 0.06, middle: 0.015)))
    check(out.primary == 0 && out.secondary == 1, "right middle pinch fires orange")
    out = gestures.update(frame(0.033, left: hand(.left, middle: 0.015), right: hand(.right)))
    check(out.jump && out.primary == 0 && out.secondary == 0 && out.move == .zero, "left middle pinch jumps")
    out = gestures.update(frame(0.05, left: hand(.left), right: hand(.right, index: 0.02, middle: 0.012)))
    check(out.secondary == 1 && out.primary == 0, "only the closest finger engages")
}

// Tracking loss: hold through a short dropout, neutral after the grace, and
// a pinch still closed on reacquire does not fire again.
do {
    var gestures = PortalHandGestures()
    let start = SIMD3<Float>(0, 1.0, -0.35)
    _ = gestures.update(frame(0, left: hand(.left, at: start, index: 0.015), right: hand(.right, index: 0.015)))
    var out = gestures.update(frame(0.016, left: hand(.left, at: start + SIMD3(0, 0, -0.12), index: 0.015), right: hand(.right, index: 0.015)))
    check(near(out.move, SIMD2(0, 1)) && out.primary == 1, "walking and firing")
    var dropped = hand(.right, index: 0.015)
    dropped.thumbTip = nil
    out = gestures.update(frame(0.05, left: nil, right: dropped))
    check(near(out.move, SIMD2(0, 1)) && out.primary == 1, "short joint dropout holds state")
    out = gestures.update(frame(0.2, left: nil, right: dropped))
    check(out.isNeutral, "neutral after the loss grace: \(out)")
    out = gestures.update(frame(0.216, left: hand(.left, at: start, index: 0.015), right: hand(.right, index: 0.015)))
    check(out.isNeutral, "reacquired closed pinches stay released")
    _ = gestures.update(frame(0.233, left: hand(.left, at: start, index: 0.06), right: hand(.right, index: 0.06)))
    out = gestures.update(frame(0.25, left: hand(.left, at: start, index: 0.015), right: hand(.right, index: 0.015)))
    check(out.primary == 1 && out.move == .zero, "fresh pinches act again and re-anchor")
    out = gestures.update(frame(0.266, head: nil, left: hand(.left, at: start, index: 0.015), right: hand(.right, index: 0.015)))
    check(out.isNeutral, "untracked head is neutral immediately")
}

// An occluded middle tip does not disturb an index pinch; a lost hand does.
do {
    var gestures = PortalHandGestures()
    let start = SIMD3<Float>(0, 1.0, -0.35)
    func curled(_ at: SIMD3<Float>) -> PortalHandSample {
        var sample = hand(.left, at: at, index: 0.015)
        sample.middleTip = nil
        return sample
    }
    _ = gestures.update(frame(0, left: curled(start)))
    var out = gestures.update(frame(0.5, left: curled(start + SIMD3(0, 0, -0.12))))
    check(near(out.move, SIMD2(0, 1)), "index pinch survives an untracked middle tip: \(out.move)")
    out = gestures.update(frame(0.55, left: nil))
    check(near(out.move, SIMD2(0, 1)), "brief whole-hand dropout holds the stick")
    out = gestures.update(frame(0.7, left: nil))
    check(out.isNeutral, "whole-hand loss releases the stick after the grace")
}

// Palm toward the head (system Home / Control Center gesture) suppresses.
do {
    var gestures = PortalHandGestures()
    let h = head()
    check(PortalHandGestures.palmTowardHead(hand(.right, palmUp: true), side: .right, head: h)! > 0.6, "right palm up faces head")
    check(PortalHandGestures.palmTowardHead(hand(.left, palmUp: true), side: .left, head: h)! > 0.6, "left palm up faces head")
    check(PortalHandGestures.palmTowardHead(hand(.right), side: .right, head: h)! < 0, "right palm down faces away")
    check(PortalHandGestures.palmTowardHead(hand(.left), side: .left, head: h)! < 0, "left palm down faces away")
    var out = gestures.update(frame(0, right: hand(.right, index: 0.015, palmUp: true)))
    check(out.primary == 0, "palm-facing pinch does not fire")
    out = gestures.update(frame(0.016, left: hand(.left, middle: 0.015, palmUp: true), right: hand(.right, index: 0.015)))
    check(out.primary == 0 && !out.jump, "turning away mid-pinch stays blocked; left palm blocks jump")
    _ = gestures.update(frame(0.033, right: hand(.right, index: 0.06)))
    out = gestures.update(frame(0.05, right: hand(.right, index: 0.015)))
    check(out.primary == 1, "fresh pinch with palm away fires")
}

// Arbitration cancel: neutral and held pinches must reopen.
do {
    var gestures = PortalHandGestures()
    _ = gestures.update(frame(0, right: hand(.right, index: 0.015)))
    gestures.cancel()
    let out = gestures.update(frame(0.016, right: hand(.right, index: 0.015)))
    check(out.isNeutral, "cancel blocks a held pinch")
}

// Controllers win; hands only without Sense and with an idle gamepad.
do {
    var arbiter = PortalInputArbiter()
    var d = arbiter.update(time: 0, spatialConnected: false, gamepadConnected: false, gamepadActive: false, handsAvailable: false)
    check(d.owner == .none && !d.changed, "nothing connected")
    d = arbiter.update(time: 0.1, spatialConnected: false, gamepadConnected: false, gamepadActive: false, handsAvailable: true)
    check(d.owner == .hands && d.changed, "hands alone")
    d = arbiter.update(time: 0.2, spatialConnected: false, gamepadConnected: false, gamepadActive: false, handsAvailable: true)
    check(d.owner == .hands && !d.changed, "change reported once")
    d = arbiter.update(time: 0.3, spatialConnected: true, gamepadConnected: true, gamepadActive: true, handsAvailable: true)
    check(d.owner == .spatial && d.changed, "Sense wins over everything")
    d = arbiter.update(time: 0.4, spatialConnected: false, gamepadConnected: true, gamepadActive: false, handsAvailable: true)
    check(d.owner == .gamepad, "recent gamepad use holds ownership")
    d = arbiter.update(time: 1.2, spatialConnected: false, gamepadConnected: true, gamepadActive: false, handsAvailable: true)
    check(d.owner == .hands && d.changed, "idle gamepad yields to hands")
    d = arbiter.update(time: 1.3, spatialConnected: false, gamepadConnected: true, gamepadActive: true, handsAvailable: true)
    check(d.owner == .gamepad && d.changed, "gamepad use takes over immediately")
    d = arbiter.update(time: 1.4, spatialConnected: false, gamepadConnected: false, gamepadActive: false, handsAvailable: true)
    check(d.owner == .hands, "disconnect hands back without delay")
    d = arbiter.update(time: 1.5, spatialConnected: false, gamepadConnected: true, gamepadActive: false, handsAvailable: false)
    check(d.owner == .gamepad, "idle gamepad without hands still owns")
    check(!PortalInputArbiter.gamepadActive(move: SIMD2(0.06, 0.06), look: SIMD2(0.1, 0), triggers: SIMD2(0.01, 0), buttons: 0), "stick drift is idle")
    check(PortalInputArbiter.gamepadActive(move: SIMD2(0, 0.2), look: .zero, triggers: .zero, buttons: 0), "slow creep above the engine threshold is use")
    check(PortalInputArbiter.gamepadActive(move: SIMD2(0, 0.5), look: .zero, triggers: .zero, buttons: 0), "stick use")
    check(PortalInputArbiter.gamepadActive(move: .zero, look: .zero, triggers: SIMD2(0, 0.2), buttons: 0), "trigger use")
    check(PortalInputArbiter.gamepadActive(move: .zero, look: .zero, triggers: .zero, buttons: 1), "button use")
}

// Hardware tuning overrides.
do {
    let tuned = PortalHandConfig(environment: ["P2_HAND_PINCH_ENGAGE": "0.03", "P2_HAND_PINCH_RELEASE": "0.02"])
    check(near(tuned.pinchEngage, 0.03) && near(tuned.pinchRelease, 0.035), "release kept above engage")
    let bad = PortalHandConfig(environment: ["P2_HAND_PINCH_ENGAGE": "nan", "P2_HAND_PINCH_RELEASE": "5"])
    check(bad == PortalHandConfig(), "invalid values ignored")
}

if failures > 0 { print("\(failures) hand check(s) failed"); exit(1) }
print("hand checks passed")
}
}
