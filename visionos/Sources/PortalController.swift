import Foundation
import GameController

// GameController handlers publish complete snapshots; disconnect/background
// releases every action. One owner publishes per tick (PortalInputArbiter):
// a connected Sense pair, else the gamepad while in use, else immersive hands.
// Hands are optional; every action stays reachable from a controller.
//
// Standard gamepad / DualSense (PS/Home and Create stay with the system):
//   left stick: move              right stick: turn (X) / look (Y)
//   R2: blue (primary) portal     L2: orange (secondary) portal
//   A/Cross: jump  B/Circle: crouch  X/Square: use  Menu/Options: pause
//   L3: recenter                  L3+R3 held 0.8 s: return to the window
@MainActor
final class PortalController {
    private let session: UInt64
    private var observers: [NSObjectProtocol] = []
    private var controller: GCController?
    private let spatial: (any PortalSpatialSource)?
    private var timer: Timer?
    private var suspended = false
    private var windowHold: Date?
    private var requestedWindow = false
    private var arbiter = PortalInputArbiter()
    private var hands: PortalHandControls?
    private var handsUnavailable = false
    // Hand tracking (and its permission prompt) starts only after an immersive
    // session has had no gamepad and no Sense controller for this long.
    private static let handsAfterNoController = 1.0
    private var noControllerSince: Double?
    private static var active: PortalController?

    init(session: UInt64, spatial: (any PortalSpatialSource)?) {
        self.session = session
        self.spatial = spatial
        Self.active?.stop()
        Self.active = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectController() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            // The departing controller may still be listed (with its last,
            // possibly held, values) when this arrives: never select it again.
            let gone = (note.object as? GCController).map { ObjectIdentifier($0) }
            Task { @MainActor [weak self] in self?.selectController(excluding: gone) }
        })
        selectController()
        // Poll complete state, including held buttons after tracking resumes.
        // Avoid taking ownership of handlers used by SDL's MFi driver.
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func selectController(excluding gone: ObjectIdentifier? = nil) {
        p2_xr_release_input(session)
        let controllers = GCController.controllers().filter { ObjectIdentifier($0) != gone }
        Self.reportControllers()
        controller = controllers.first {
            if #available(visionOS 26.0, *), $0.productCategory == GCProductCategorySpatialController { return false }
#if targetEnvironment(simulator)
            // CoreSimulator exposes this synthetic MFi pad even when the Mac
            // has no controller. Only the explicit automated input audit
            // ignores it; real DualSense/Sense connections still cancel it.
            if ProcessInfo.processInfo.environment["P2_VISION_INPUT_AUDIT"] == "1",
               $0.productCategory == GCProductCategoryMFi, $0.vendorName == "Gamepad" { return false }
#endif
            return $0.extendedGamepad != nil
        }
        publish()
    }

    static func reportControllers() {
        let devices = GCController.controllers()
        fputs("[P2XR] Available controllers: \(devices.count)\n",stderr)
        for device in devices {
            let line = "[P2XR] Controller: category=\(device.productCategory) vendor=\(device.vendorName ?? "unknown") extended=\(device.extendedGamepad != nil) snapshot=\(device.isSnapshot)\n"
            fputs(line,stderr)
        }
    }

    private func publish() {
        guard p2_xr_session_active(session) != 0 else { return }
        guard !suspended else { hands?.cancel(); p2_xr_release_input(session); return }
        let now = ProcessInfo.processInfo.systemUptime
        let sense = spatial?.inputSnapshot()
        let gamepad = controller?.extendedGamepad
        let pad = gamepad.map(Self.gamepadInput)
        // Only an immersive session publishes tracked headset frames.
        var frame = P2XRFrame()
        let tracked = p2_xr_read(session, &frame, nil) != 0
        // Hands are for controller-less immersive play: no gamepad and no
        // Sense connected for a moment (not a reconnect blip or startup
        // enumeration), so controller players never see the hands prompt.
        if !tracked || sense != nil || pad != nil { noControllerSince = nil }
        else if noControllerSince == nil { noControllerSince = now }
        if let since = noControllerSince, now - since >= Self.handsAfterNoController, hands == nil, !handsUnavailable {
            if PortalHandControls.isAvailable {
                NSLog("[P2XR] No controller connected in immersive play; starting hand controls")
                let controls = PortalHandControls()
                // Fresh pinches only: one already closed (the expand tap) must
                // open before it can act.
                controls.cancel()
                controls.start()
                hands = controls
            } else { handsUnavailable = true }
        }
        let active = gamepad.map(Self.gamepadActive) ?? false
        let decision = arbiter.update(time: now, spatialConnected: sense != nil, gamepadConnected: pad != nil,
                                      gamepadActive: active, handsAvailable: hands?.isRunning == true)
        if decision.changed { NSLog("[P2XR] Input owner: %@", decision.owner.rawValue) }
        if decision.owner != .hands { hands?.cancel() }
        var input: P2XRInput
        switch decision.owner {
        case .spatial: input = sense ?? P2XRInput()
        case .gamepad: input = pad ?? P2XRInput()
        case .hands:
            input = hands?.snapshot(head: tracked ? frame.tracking_from_head : nil, time: now) ?? P2XRInput()
        case .none: input = P2XRInput()
        }
        windowGesture(input)
        if input.connected == 0 { p2_xr_release_input(session) }
        else { p2_xr_publish_input(session, &input) }
    }

    private static func gamepadInput(_ pad: GCExtendedGamepad) -> P2XRInput {
        var input = P2XRInput()
        input.connected = 1
        input.move_x = pad.leftThumbstick.xAxis.value
        input.move_y = pad.leftThumbstick.yAxis.value
        input.turn_x = pad.rightThumbstick.xAxis.value
        input.look_y = pad.rightThumbstick.yAxis.value
        input.blue_trigger = pad.rightTrigger.value
        input.orange_trigger = pad.leftTrigger.value
        if pad.buttonA.isPressed { input.buttons |= UInt32(P2_XR_JUMP.rawValue) }
        if pad.buttonB.isPressed { input.buttons |= UInt32(P2_XR_CROUCH.rawValue) }
        if pad.buttonX.isPressed { input.buttons |= UInt32(P2_XR_USE.rawValue) }
        if pad.buttonMenu.isPressed { input.buttons |= UInt32(P2_XR_PAUSE.rawValue) }
        let left = pad.leftThumbstickButton?.isPressed == true, right = pad.rightThumbstickButton?.isPressed == true
        if left && right { input.buttons |= UInt32(P2_XR_WINDOW.rawValue) }
        else if left { input.buttons |= UInt32(P2_XR_RECENTER.rawValue) }
        return input
    }

    // Unmapped controls (Y, shoulders, R3, d-pad) also count as use, so a pad
    // being handled is never overridden by hands.
    private static func gamepadActive(_ pad: GCExtendedGamepad) -> Bool {
        let input = gamepadInput(pad)
        let unmapped = pad.buttonY.isPressed || pad.leftShoulder.isPressed || pad.rightShoulder.isPressed ||
            pad.rightThumbstickButton?.isPressed == true || pad.dpad.xAxis.value != 0 || pad.dpad.yAxis.value != 0
        return PortalInputArbiter.gamepadActive(move: SIMD2(input.move_x, input.move_y),
            look: SIMD2(input.turn_x, input.look_y), triggers: SIMD2(input.blue_trigger, input.orange_trigger),
            buttons: input.buttons | (unmapped ? 1 : 0))
    }

    private func windowGesture(_ input: P2XRInput) {
        if input.buttons & UInt32(P2_XR_WINDOW.rawValue) != 0 {
            if windowHold == nil { windowHold = Date() }
            if !requestedWindow, let windowHold, Date().timeIntervalSince(windowHold) >= 0.8 {
                requestedWindow = true
                NotificationCenter.default.post(name: .portalRequestWindow,object: nil)
            }
        } else { windowHold = nil; requestedWindow = false }
    }

    static func releaseAll() {
        if let active { p2_xr_release_input(active.session) }
    }

    static func suspend(session: UInt64, _ value: Bool) {
        guard let active, active.session == session else { return }
        active.suspended = value
        active.publish()
    }

    static func attach(session: UInt64, spatial: (any PortalSpatialSource)?) {
        guard p2_xr_session_active(session) != 0 else { return }
        _ = PortalController(session: session, spatial: spatial)
    }

    static func stop(session: UInt64) {
        if active?.session == session { active?.stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hands?.stop()
        hands = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        p2_xr_release_input(session)
        if Self.active === self { Self.active = nil }
    }
}
