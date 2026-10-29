import Foundation
import GameController

// GameController handlers publish complete snapshots; disconnect/background
// releases every action. No gameplay action depends on hand or eye access.
@MainActor
final class PortalController {
    private let session: UInt64
    private var observers: [NSObjectProtocol] = []
    private var controller: GCController?
    private static var active: PortalController?

    init(session: UInt64) {
        self.session = session
        Self.active?.stop()
        Self.active = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectController() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectController() }
        })
        selectController()
    }

    private func selectController() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        p2_xr_release_input(session)
        controller = GCController.controllers().first { $0.extendedGamepad != nil }
        let session = self.session
        controller?.extendedGamepad?.valueChangedHandler = { pad, _ in
            var input = P2XRInput()
            input.connected = 1
            input.move_x = pad.leftThumbstick.xAxis.value
            input.move_y = pad.leftThumbstick.yAxis.value
            input.turn_x = pad.rightThumbstick.xAxis.value
            input.blue_trigger = pad.leftTrigger.value
            input.orange_trigger = pad.rightTrigger.value
            if pad.buttonA.isPressed { input.buttons |= UInt32(P2_XR_JUMP.rawValue) }
            if pad.buttonB.isPressed { input.buttons |= UInt32(P2_XR_CROUCH.rawValue) }
            if pad.buttonX.isPressed { input.buttons |= UInt32(P2_XR_USE.rawValue) }
            if pad.buttonMenu.isPressed { input.buttons |= UInt32(P2_XR_PAUSE.rawValue) }
            if pad.leftThumbstickButton?.isPressed == true { input.buttons |= UInt32(P2_XR_RECENTER.rawValue) }
            p2_xr_publish_input(session, &input)
        }
    }

    static func releaseAll() {
        if let active { p2_xr_release_input(active.session) }
    }

    static func attach(session: UInt64) {
        guard p2_xr_session_active(session) != 0 else { return }
        _ = PortalController(session: session)
    }

    static func stop(session: UInt64) {
        if active?.session == session { active?.stop() }
    }

    func stop() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        p2_xr_release_input(session)
        if Self.active === self { Self.active = nil }
    }
}
