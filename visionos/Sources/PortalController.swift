import Foundation
import GameController

// GameController handlers publish complete snapshots; disconnect/background
// releases every action. No gameplay action depends on hand or eye access.
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
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectController() }
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

    private func selectController() {
        p2_xr_release_input(session)
        let controllers = GCController.controllers()
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
        guard !suspended else { p2_xr_release_input(session); return }
        if var input = spatial?.inputSnapshot() {
            windowGesture(input)
            p2_xr_publish_input(session, &input)
        } else if let pad = controller?.extendedGamepad {
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
            if pad.leftThumbstickButton?.isPressed == true { input.buttons |= UInt32(P2_XR_RECENTER.rawValue) }
            if pad.leftThumbstickButton?.isPressed == true && pad.rightThumbstickButton?.isPressed == true {
                input.buttons |= UInt32(P2_XR_WINDOW.rawValue)
                input.buttons &= ~UInt32(P2_XR_RECENTER.rawValue)
            }
            windowGesture(input)
            p2_xr_publish_input(session, &input)
        } else { p2_xr_release_input(session) }
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
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        p2_xr_release_input(session)
        if Self.active === self { Self.active = nil }
    }
}
