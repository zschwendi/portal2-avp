#if P2_GAME
import Foundation
import GameController

// Connected controllers as the Library shows them, resolved with the same
// route rule PortalController uses for gameplay (PortalControllerRoute).
//
// While the Library is visible it also reads the controller for the card,
// reveal-first (Port Forge): after a full release the first press of
// Cross/A only shows focus, the second acts; Circle/B clears focus; focus
// fades after 10 s idle. Polled, so the game's own input path is untouched.
@MainActor
final class PortalControllerReadiness: ObservableObject {
    static let shared = PortalControllerReadiness()
    struct Device: Identifiable, Equatable {
        let id: ObjectIdentifier
        let name: String
        let sense: Bool
        let battery: Float?      // 0...1 when reported
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var route = PortalControllerRoute.none
    @Published private(set) var focused = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var activate: (() -> Void)?
    private var released = false
    private var focusedAt = 0.0
    private static let focusTimeout = 10.0

    private init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The departing controller can still be listed when this arrives.
                Task { @MainActor [weak self] in
                    self?.refresh()
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    static func isSense(_ controller: GCController) -> Bool { PortalController.isSense(controller) }

    func refresh() {
        devices = GCController.controllers().compactMap { controller in
            let sense = Self.isSense(controller)
            guard sense || controller.extendedGamepad != nil else { return nil }
            let level = controller.battery.map { $0.batteryState == .unknown ? nil : Optional($0.batteryLevel) } ?? nil
            return Device(id: ObjectIdentifier(controller), name: Self.displayName(controller, sense: sense),
                          sense: sense, battery: level)
        }
        route = PortalControllerRoute.resolve(senseDevices: devices.filter(\.sense).count,
                                              gamepads: devices.filter { !$0.sense }.map(\.name))
    }

    private static func displayName(_ controller: GCController, sense: Bool) -> String {
        if sense { return "PS VR2 Sense" }
        let name = controller.vendorName?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.localizedCaseInsensitiveContains("dualsense") { return "DualSense" }
        return name.isEmpty ? "Controller" : name
    }

    var lowBattery: Device? { devices.first { ($0.battery ?? 1) < 0.15 } }

    // MARK: Card navigation

    func beginCardNavigation(activate: @escaping () -> Void) {
        self.activate = activate
        released = false   // a press still held from gameplay never acts
        focused = false
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func endCardNavigation() {
        timer?.invalidate()
        timer = nil
        activate = nil
        focused = false
    }

    private func poll() {
        var confirm = false, back = false, any = false
        for controller in GCController.controllers() {
            if let pad = controller.extendedGamepad, !Self.isSense(controller) {
                confirm = confirm || pad.buttonA.isPressed
                back = back || pad.buttonB.isPressed
                any = any || pad.buttonA.isPressed || pad.buttonB.isPressed || pad.buttonX.isPressed ||
                    pad.buttonY.isPressed || pad.buttonMenu.isPressed || pad.rightTrigger.isPressed || pad.leftTrigger.isPressed
            } else if #available(visionOS 26.0, *), Self.isSense(controller) {
                // Lower face button (Cross on the right, Square on the left) confirms; upper backs out.
                let buttons = controller.input.buttons
                let lower = [GCButtonElementName.a, .x].contains { buttons[$0]?.pressedInput.isPressed == true }
                let upper = [GCButtonElementName.b, .y].contains { buttons[$0]?.pressedInput.isPressed == true }
                let trigger = buttons[.trigger]?.pressedInput.isPressed == true
                confirm = confirm || lower
                back = back || upper
                any = any || lower || upper || trigger
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if focused && now - focusedAt > Self.focusTimeout { focused = false }
        guard released else { released = !any; return }
        guard any else { return }
        released = false
        if back { focused = false; return }
        guard confirm else { return }
        if focused { focused = false; activate?() }
        else { focused = true; focusedAt = now }
    }
}
#endif
