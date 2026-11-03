import simd

// Platform-independent hand gesture and input-arbitration model. ARKit joint
// positions (meters, ARKit origin) go in; abstract controls come out. It must
// not import ARKit or GameController: tests/test_visionos_hands.py compiles it
// on macOS with swiftc.
//
// Mapping (immersive only):
//   left  thumb-index pinch + arm displacement: virtual move stick
//   left  thumb-middle pinch: jump
//   right thumb-index pinch: primary (blue) fire
//   right thumb-middle pinch: secondary (orange) fire

struct PortalHandConfig: Sendable, Equatable {
    // ARKit tip joints sit inside fingers, so a firm pinch bottoms out near
    // 1.5 cm rather than 0 (AVPcraft hardware traces). Engage below 2.5 cm,
    // release above 4 cm; P2_HAND_PINCH_ENGAGE/RELEASE retune on hardware.
    var pinchEngage: Float = 0.025
    var pinchRelease: Float = 0.04
    var deadzone: Float = 0.02
    var fullDeflection: Float = 0.12
    // Single-joint tracking drops while a pinch is held are common. Hold the
    // last state this long before treating the hand as lost.
    var lossGrace: Double = 0.12
    // Cosine between the palm normal and the direction to the head.
    var palmFacingEnter: Float = 0.6
    var palmFacingExit: Float = 0.35

    init() {}

    init(environment: [String: String]) {
        func meters(_ key: String) -> Float? {
            guard let value = environment[key].flatMap({ Float($0) }), value > 0.005, value < 0.2 else { return nil }
            return value
        }
        if let engage = meters("P2_HAND_PINCH_ENGAGE") { pinchEngage = engage }
        if let release = meters("P2_HAND_PINCH_RELEASE") { pinchRelease = release }
        if pinchRelease < pinchEngage + 0.005 { pinchRelease = pinchEngage + 0.005 }
    }
}

// One tracked hand. The anchor origin (wrist) is always present; individual
// joints are nil while ARKit reports them untracked.
struct PortalHandSample: Sendable, Equatable {
    var wrist: SIMD3<Float>
    var thumbTip: SIMD3<Float>?
    var indexTip: SIMD3<Float>?
    var middleTip: SIMD3<Float>?
    var indexKnuckle: SIMD3<Float>?
    var littleKnuckle: SIMD3<Float>?
}

struct PortalHandFrame: Sendable {
    var time: Double
    var head: simd_float4x4?          // tracking_from_head; nil while untracked
    var left: PortalHandSample?
    var right: PortalHandSample?
}

struct PortalHandOutput: Sendable, Equatable {
    var move = SIMD2<Float>(0, 0)
    var primary: Float = 0
    var secondary: Float = 0
    var jump = false
    var isNeutral: Bool { self == PortalHandOutput() }
}

// Distance hysteresis. A nil distance (thumb or finger tip untracked) holds
// the state for the loss grace, then releases. After any cancel (loss, palm
// suppression, losing arbitration) the fingers must be seen open before the
// pinch can engage, so a pinch that was already closed never fires later.
struct PortalPinch: Sendable, Equatable {
    private(set) var held = false
    private(set) var blocked = false
    private var lostSince: Double?

    mutating func update(distance: Float?, closest: Bool, time: Double, config: PortalHandConfig) -> Bool {
        guard let distance else {
            let since = lostSince ?? time
            lostSince = since
            if time - since >= config.lossGrace { cancel() }
            return held
        }
        lostSince = nil
        if held || blocked {
            if distance > config.pinchRelease { held = false; blocked = false }
        } else if closest && distance < config.pinchEngage { held = true }
        return held
    }

    mutating func cancel() { held = false; blocked = true; lostSince = nil }
}

// Virtual stick anchored where the pinch began. Displacement is measured in
// the head-yaw frame captured at that moment, so glancing sideways while
// walking does not steer. Height changes are ignored.
struct PortalHandStick: Sendable {
    private(set) var anchor: SIMD3<Float>?
    private var right = SIMD3<Float>(1, 0, 0)
    private var forward = SIMD3<Float>(0, 0, -1)

    // Apple tracking: +X right, +Y up, -Z forward. Subtracting the up vector's
    // share keeps yaw defined when looking straight up or down.
    static func yawBasis(_ head: simd_float4x4) -> (right: SIMD3<Float>, forward: SIMD3<Float>)? {
        let look = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let up = SIMD3<Float>(head.columns.1.x, head.columns.1.y, head.columns.1.z)
        var forward = look - up * look.y
        forward.y = 0
        guard forward.x.isFinite, forward.z.isFinite, simd_length(forward) > 1e-4 else { return nil }
        forward = simd_normalize(forward)
        return (simd_cross(forward, SIMD3<Float>(0, 1, 0)), forward)
    }

    static func deflection(_ offset: SIMD2<Float>, config: PortalHandConfig) -> SIMD2<Float> {
        let radius = simd_length(offset)
        guard radius.isFinite, radius > config.deadzone else { return .zero }
        let span = max(config.fullDeflection - config.deadzone, 1e-4)
        return offset / radius * min(1, (radius - config.deadzone) / span)
    }

    @discardableResult
    mutating func begin(at position: SIMD3<Float>, head: simd_float4x4) -> Bool {
        guard let basis = Self.yawBasis(head) else { anchor = nil; return false }
        anchor = position
        right = basis.right
        forward = basis.forward
        return true
    }

    func value(at position: SIMD3<Float>, config: PortalHandConfig) -> SIMD2<Float> {
        guard let anchor else { return .zero }
        let offset = position - anchor
        return Self.deflection(SIMD2(simd_dot(offset, right), simd_dot(offset, forward)), config: config)
    }

    mutating func end() { anchor = nil }
}

struct PortalHandGestures: Sendable {
    enum Side: Int, Sendable { case left = 0, right = 1 }

    private struct Hand: Sendable {
        var index = PortalPinch()
        var middle = PortalPinch()
        var palmFacing = false
        mutating func cancel() { index.cancel(); middle.cancel() }
    }

    let config: PortalHandConfig
    private var hands = [Hand(), Hand()]
    private var stick = PortalHandStick()
    private var move = SIMD2<Float>(0, 0)

    init(config: PortalHandConfig = PortalHandConfig()) { self.config = config }

    // Palm normal from three joint positions, so it does not depend on the
    // per-hand joint axis convention: (I-W)x(L-W) leaves the right palm and
    // enters the left one (same derivation as AVPcraft's anatomical frame).
    static func palmTowardHead(_ hand: PortalHandSample, side: Side, head: simd_float4x4) -> Float? {
        guard let index = hand.indexKnuckle, let little = hand.littleKnuckle else { return nil }
        var normal = simd_cross(index - hand.wrist, little - hand.wrist)
        if side == .left { normal = -normal }
        let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let toHead = eye - (hand.wrist + index + little) / 3
        guard simd_length(normal) > 1e-6, simd_length(toHead) > 1e-4 else { return nil }
        return simd_dot(simd_normalize(normal), simd_normalize(toHead))
    }

    // Losing arbitration, suspension or session end: neutral now, and every
    // pinch must reopen before it can act again.
    mutating func cancel() {
        hands[0].cancel(); hands[1].cancel()
        stick.end()
        move = .zero
    }

    private mutating func cancel(_ side: Side) {
        hands[side.rawValue].cancel()
        if side == .left { stick.end(); move = .zero }
    }

    mutating func update(_ frame: PortalHandFrame) -> PortalHandOutput {
        guard let head = frame.head else { cancel(); return PortalHandOutput() }
        for side in [Side.left, .right] {
            let sample = side == .left ? frame.left : frame.right
            if let sample, let facing = Self.palmTowardHead(sample, side: side, head: head) {
                let threshold = hands[side.rawValue].palmFacing ? config.palmFacingExit : config.palmFacingEnter
                hands[side.rawValue].palmFacing = facing > threshold
            }
            // System Home / Control Center gesture: never act, and require a
            // fresh pinch after the palm turns away.
            if sample != nil && hands[side.rawValue].palmFacing { cancel(side); continue }
            func distance(_ tip: SIMD3<Float>?) -> Float? {
                guard let thumb = sample?.thumbTip, let tip else { return nil }
                return simd_distance(thumb, tip)
            }
            let indexDistance = distance(sample?.indexTip), middleDistance = distance(sample?.middleTip)
            let indexHeld = hands[side.rawValue].index.update(distance: indexDistance,
                closest: (indexDistance ?? .infinity) <= (middleDistance ?? .infinity), time: frame.time, config: config)
            _ = hands[side.rawValue].middle.update(distance: middleDistance,
                closest: (middleDistance ?? .infinity) < (indexDistance ?? .infinity), time: frame.time, config: config)
            guard side == .left else { continue }
            if !indexHeld { stick.end(); move = .zero }
            else if let sample {
                // Re-anchor on every new pinch. A missing hand holds the last
                // value until the pinch's loss grace expires.
                if stick.anchor == nil { stick.begin(at: sample.wrist, head: head) }
                move = stick.value(at: sample.wrist, config: config)
            }
        }
        var output = PortalHandOutput()
        output.move = move
        output.jump = hands[0].middle.held
        output.primary = hands[1].index.held ? 1 : 0
        output.secondary = hands[1].middle.held ? 1 : 0
        return output
    }
}

// Controllers win. A connected Sense pair owns input outright; a gamepad owns
// it while in use and for a short idle delay after; hands contribute only when
// neither applies. Owner changes are reported once by the caller.
enum PortalInputOwner: String, Sendable { case none, spatial, gamepad, hands }

struct PortalInputArbiter: Sendable {
    var gamepadIdleDelay: Double = 0.75
    private(set) var owner = PortalInputOwner.none
    private var gamepadActiveAt: Double?

    // Just under the engine's 0.15 stick threshold, so a slow creep or a
    // partial trigger keeps the pad in charge instead of handing it to hands.
    static func gamepadActive(move: SIMD2<Float>, look: SIMD2<Float>, triggers: SIMD2<Float>, buttons: UInt32) -> Bool {
        buttons != 0 || simd_length(move) > 0.12 || simd_length(look) > 0.12 || max(triggers.x, triggers.y) > 0.02
    }

    mutating func update(time: Double, spatialConnected: Bool, gamepadConnected: Bool,
                         gamepadActive: Bool, handsAvailable: Bool) -> (owner: PortalInputOwner, changed: Bool) {
        if !gamepadConnected { gamepadActiveAt = nil }
        else if gamepadActive { gamepadActiveAt = time }
        let next: PortalInputOwner
        if spatialConnected { next = .spatial }
        else if let at = gamepadActiveAt, time - at < gamepadIdleDelay { next = .gamepad }
        else if handsAvailable { next = .hands }
        else if gamepadConnected { next = .gamepad }
        else { next = .none }
        let changed = next != owner
        owner = next
        return (next, changed)
    }
}
