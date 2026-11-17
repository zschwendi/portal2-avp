import Foundation
import GameController
import simd

// GameController handlers publish complete snapshots; disconnect/background
// releases every action. One owner publishes per tick (PortalInputArbiter):
// a connected Sense pair, else the gamepad while in use, else immersive hands.
// A lone Sense controller owns input only without a gamepad
// (PortalControllerRoute). Hands are optional; every action stays reachable
// from a controller.
//
// Losing the playing controller during gameplay presses pause once (which
// also returns immersive play to the window, PortalGameFlow). Afterwards, and
// after the Library covered the game, nothing reaches the game until every
// control is released, so a reconnect or a launcher press never moves, fires
// or picks a menu item by itself.
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
    private var pauseUntil: Double?
    private var awaitingRelease = false
    private static let pausePress = 0.2
    private static var active: PortalController?
    // The Library covers the running game: input stays released.
    private static var launcherVisible = false

    init(session: UInt64, spatial: (any PortalSpatialSource)?) {
        self.session = session
        self.spatial = spatial
        // A session change (window <-> immersive) never carries a held press over.
        awaitingRelease = Self.active?.awaitingRelease ?? false
        Self.active?.stop()
        Self.active = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectController() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            // The departing controller may still be listed (with its last,
            // possibly held, values) when this arrives: never select it again.
            let device = note.object as? GCController
            let gone = device.map { ObjectIdentifier($0) }
            let sense = device.map(Self.isSense) ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.routeLost(selectedGamepad: gone != nil && gone == self.controller.map { ObjectIdentifier($0) },
                               spatial: sense)
                self.selectController(excluding: gone)
            }
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
            if Self.isSense($0) { return false }
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

    private func routeLost(selectedGamepad: Bool, spatial: Bool) {
        let owner: PortalRouteLoss.Owner
        switch arbiter.owner {
        case .spatial: owner = .spatial
        case .gamepad: owner = .gamepad
        case .hands: owner = .hands
        case .none: owner = .none
        }
        guard PortalRouteLoss.pauses(owner: owner, lostSpatial: spatial, lostSelectedGamepad: selectedGamepad,
                                     engineRunning: Self.engineRunning, gameUIVisible: Self.gameUIVisible) else { return }
        NSLog("[P2XR] Playing %@ disconnected; pausing the game", spatial ? "Sense controller" : "gamepad")
        pauseUntil = ProcessInfo.processInfo.systemUptime + Self.pausePress
        awaitingRelease = true
    }

    nonisolated static func isSense(_ device: GCController) -> Bool {
        if #available(visionOS 26.0, *) { return device.productCategory == GCProductCategorySpatialController }
        return false
    }

    #if P2_GAME
    private static var engineRunning: Bool { p2_vision_game_state() == 1 }
    private static var gameUIVisible: Bool { p2_vision_game_ui_visible() != 0 }
    #else
    private static let engineRunning = false, gameUIVisible = false
    #endif

    // Nothing pressed, triggers up, sticks near center.
    private static func neutral(_ input: P2XRInput) -> Bool {
        input.buttons == 0 && max(input.blue_trigger, input.orange_trigger) < 0.05 &&
            simd_length(SIMD2(input.move_x, input.move_y)) < 0.2 && simd_length(SIMD2(input.turn_x, input.look_y)) < 0.2
    }

    private func publish() {
        guard p2_xr_session_active(session) != 0 else { return }
        guard !suspended else { hands?.cancel(); p2_xr_release_input(session); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let until = pauseUntil {
            if now < until {
                var press = P2XRInput()
                press.connected = 1
                press.buttons = UInt32(P2_XR_PAUSE.rawValue)
                p2_xr_publish_input(session, &press)
                return
            }
            pauseUntil = nil
        }
        guard !Self.launcherVisible else { hands?.cancel(); p2_xr_release_input(session); return }
        let sense = spatial?.inputSnapshot()
        let gamepad = controller?.extendedGamepad
        let pad = gamepad.map(Self.gamepadInput)
        let senseOwns = sense != nil && PortalControllerRoute.senseOwnsInput(
            senseDevices: spatial?.connectedDevices ?? 0, gamepadConnected: pad != nil)
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
        let decision = arbiter.update(time: now, spatialConnected: senseOwns, gamepadConnected: pad != nil,
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
        if awaitingRelease {
            // Nothing connected is not a release: a controller that
            // reconnects with a press held must let go first.
            guard input.connected != 0, Self.neutral(input) else { p2_xr_release_input(session); return }
            awaitingRelease = false
            NSLog("[P2XR] Controls released; input reaches the game again")
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

    // The Library covering a running game: release input now; when it hides,
    // wait for a full release before the game sees anything.
    static func setLauncherVisible(_ visible: Bool) {
        guard launcherVisible != visible else { return }
        launcherVisible = visible
        if let active {
            if !visible { active.awaitingRelease = true }
            active.publish()
        }
    }

    // A pause press for the game (the Library opening over gameplay). Only
    // during gameplay: in a menu the same press would resume.
    static func pauseGameplay() {
        guard let active, engineRunning, !gameUIVisible else { return }
        active.pauseUntil = ProcessInfo.processInfo.systemUptime + pausePress
        active.publish()
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
