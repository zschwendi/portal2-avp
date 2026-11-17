import ARKit
import Foundation
import GameController
import simd

protocol PortalSpatialSource: AnyObject, Sendable {
    @MainActor func start()
    @MainActor func stop()
    @MainActor func inputSnapshot() -> P2XRInput?
    // Sense controllers connected now (resolved or not).
    @MainActor var connectedDevices: Int { get }
    func writePoses(at timestamp: Double, into frame: inout P2XRFrame)
}

// Sense controllers are two independent devices. Fixed hardware chirality
// assigns controls; connection order and the hand currently holding one do not.
@available(visionOS 26.0, *)
final class PortalSenseTracking: PortalSpatialSource, @unchecked Sendable {
    private let session: ARKitSession
    private let world: WorldTrackingProvider
    private let trackPoses: Bool
    private let lock = NSLock()
    private var provider: AccessoryTrackingProvider?
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var refreshTask: Task<Void, Never>?
    @MainActor private var generation = 0
    @MainActor private var bindings: [(Accessory, GCController)] = []
    @MainActor private var present = false
    @MainActor private(set) var connectedDevices = 0
    @MainActor private var stopped = false
    private enum ConnectionError: Error { case disconnected }

    // Resolve a fresh framework reference off the UI actor. Only its Sendable
    // identity crosses executors; keep the actor-owned controller in place.
    nonisolated private static func resolve(_ identity: ObjectIdentifier) async throws -> Accessory {
        guard let device = GCController.controllers().first(where: { ObjectIdentifier($0) == identity }) else {
            throw ConnectionError.disconnected
        }
        return try await Accessory(device: device)
    }

    init(session: ARKitSession, world: WorldTrackingProvider, trackPoses: Bool = true) {
        self.session = session
        self.world = world
        self.trackPoses = trackPoses
    }

    @MainActor func start() {
        guard observers.isEmpty, !stopped else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // A departing controller can still be listed when this
                // arrives; counting it would keep a gone pair owning input.
                let gone = name == .GCControllerDidDisconnect ? (note.object as? GCController).map { ObjectIdentifier($0) } : nil
                Task { @MainActor [weak self] in self?.refresh(excluding: gone) }
            })
        }
        refresh()
    }

    @MainActor private func refresh(excluding gone: ObjectIdentifier? = nil) {
        generation += 1
        let revision = generation
        let previous = refreshTask
        previous?.cancel()
        bindings = []
        let hadProvider = lock.withLock { let present = provider != nil; provider = nil; return present }
        let controllers = GCController.controllers().filter {
            $0.productCategory == GCProductCategorySpatialController && ObjectIdentifier($0) != gone
        }
        present = !controllers.isEmpty
        connectedDevices = controllers.count
        refreshTask = Task { [weak self] in
            // Serialize provider changes, including a cancelled run that is
            // still returning from ARKit. A late connection cannot win.
            await previous?.value
            // A listed controller whose identity has not resolved yet would
            // leave the pair owning neutral input until the next connection
            // change. Retry, bounded, while this refresh is current.
            for attempt in 0...PortalSenseBinding.retryDelays.count {
                if attempt > 0 { try? await Task.sleep(for: .seconds(PortalSenseBinding.retryDelays[attempt - 1])) }
                guard let self, self.current(revision) else { return }
                if await self.bind(controllers, attempt: attempt, revision: revision, hadProvider: hadProvider) { return }
            }
            guard let self, self.current(revision) else { return }
            NSLog("[P2XR] Sense identity incomplete after %ld attempts: %ld of %ld controllers bound; waiting for a reconnect",
                  PortalSenseBinding.retryDelays.count + 1, self.bindings.count, controllers.count)
        }
    }

    @MainActor private func current(_ revision: Int) -> Bool {
        !stopped && generation == revision && !Task.isCancelled
    }

    // One resolution pass. True when finished: every connected controller (up
    // to a pair) has a hand, or this refresh is no longer current.
    @MainActor private func bind(_ controllers: [GCController], attempt: Int, revision: Int, hadProvider: Bool) async -> Bool {
        var resolved: [(Accessory, GCController)] = []
        for controller in controllers {
            do {
                let accessory = try await Self.resolve(ObjectIdentifier(controller))
                guard current(revision) else { return true }
                resolved.append((accessory, controller))
            } catch { NSLog("[P2XR] Sense identity unavailable (attempt %ld): %@", attempt + 1, String(describing: error)) }
        }
        guard current(revision) else { return true }
        let hands = resolved.map { item -> PortalSenseBinding.Hand in
            item.0.inherentChirality == .left ? .left : item.0.inherentChirality == .right ? .right : .other
        }
        let next = PortalSenseBinding.assign(hands).map { resolved[$0] }
        let done = PortalSenseBinding.complete(connected: controllers.count, bound: next.count)
        if !done {
            NSLog("[P2XR] Sense attempt %ld: %ld connected, %ld resolved, %ld bound (left=%ld right=%ld other=%ld)",
                  attempt + 1, controllers.count, resolved.count, next.count, hands.filter { $0 == .left }.count,
                  hands.filter { $0 == .right }.count, hands.filter { $0 == .other }.count)
        }
        // A retry that binds no more keeps the current bindings and provider.
        guard PortalSenseBinding.adopts(attempt: attempt, bound: next.count, current: bindings.count) else { return done }
        bindings = next
        if attempt > 0 { NSLog("[P2XR] Sense identity retry %ld bound %ld of %ld controllers", attempt, next.count, controllers.count) }
        reportProfiles()
        guard trackPoses, AccessoryTrackingProvider.isSupported, !bindings.isEmpty else {
            if hadProvider && attempt == 0 { try? await session.run([world]) }
            return done
        }
        let authorization = await session.requestAuthorization(for: AccessoryTrackingProvider.requiredAuthorizations)
        guard authorization.values.allSatisfy({ $0 == .allowed }), current(revision) else { return done || !current(revision) }
        let provider = AccessoryTrackingProvider(accessories: bindings.map { $0.0 })
        do {
            try await session.run([world, provider])
            guard current(revision) else { return true }
            lock.withLock { self.provider = provider }
            NSLog("[P2XR] Sense tracking provider running for %lu fixed-hand devices; gameplay acceptance pending", bindings.count)
        } catch { NSLog("[P2XR] Sense tracking failed: %@", String(describing: error)) }
        return done
    }

    // PSVR2 Sense mapping by fixed hardware chirality. PS/Home and share are
    // never read; they stay with the system.
    //   left  stick: move                  right stick: turn (X) / look (Y)
    //   L2 trigger: orange (secondary)     R2 trigger: blue (primary)
    //   Square (lower face): use           Cross (lower face): jump
    //   Triangle (upper face): crouch      Circle (upper face): crouch
    //   L1/R1 grip: use                    Options/Create as menu: pause
    //   L3: recenter                       L3+R3 held 0.8 s: return to window
    // visionOS may name a controller's face buttons a/b or x/y; with two face
    // buttons per controller both spellings are read. A connected but not yet
    // resolved pair still owns input (neutral), so a gamepad cannot fight it.
    // Once per controller identity: the physical profile aliases this device
    // actually exposes, against the names inputSnapshot reads.
    @MainActor private var reportedProfiles = Set<ObjectIdentifier>()
    @MainActor private func reportProfiles() {
        for (accessory, controller) in bindings where reportedProfiles.insert(ObjectIdentifier(controller)).inserted {
            let input = controller.input
            func names<T>(_ elements: GCPhysicalInputElementCollection<T>) -> String {
                elements.map { $0.aliases.sorted().joined(separator: "|") }.sorted().joined(separator: ", ")
            }
            let read: [GCButtonElementName] = [.a, .b, .x, .y, .trigger, .grip, .thumbstickButton, .menu, .options]
            let missing = read.filter { input.buttons[$0] == nil }.map(\.rawValue) +
                (input.dpads[.thumbstick] == nil ? [GCDirectionPadElementName.thumbstick.rawValue] : [])
            NSLog("[P2XR] Sense %@ profile: buttons=[%@] dpads=[%@] missing-for-mapping=[%@]",
                  accessory.inherentChirality == .left ? "left" : accessory.inherentChirality == .right ? "right" : "other",
                  names(input.buttons), names(input.dpads), missing.joined(separator: ", "))
        }
    }

    // P2_VISION_INPUT_TRACE=1: host Sense samples, logged when a button or a
    // coarse axis bucket changes, at most 600 lines per process.
    private static let traceInput = ProcessInfo.processInfo.environment["P2_VISION_INPUT_TRACE"] == "1"
    @MainActor private static var traceLines = 0
    @MainActor private var lastTrace: [Int32] = []
    @MainActor private func trace(_ input: P2XRInput) {
        guard Self.traceInput, Self.traceLines < 600 else { return }
        func bucket(_ value: Float) -> Int32 { Int32((max(-1, min(1, value)) * 2).rounded()) }
        let key = [Int32(bitPattern: input.buttons), Int32(input.connected), Int32(bindings.count),
                   bucket(input.move_x), bucket(input.move_y), bucket(input.turn_x), bucket(input.look_y),
                   bucket(input.blue_trigger), bucket(input.orange_trigger)]
        guard key != lastTrace else { return }
        lastTrace = key
        Self.traceLines += 1
        NSLog("[P2XR] Sense host sample #%d: bound=%ld connected=%u buttons=%#x move=%.2f/%.2f look=%.2f/%.2f triggers=%.2f/%.2f",
              Self.traceLines, bindings.count, input.connected, input.buttons, input.move_x, input.move_y,
              input.turn_x, input.look_y, input.blue_trigger, input.orange_trigger)
    }

    @MainActor func inputSnapshot() -> P2XRInput? {
        guard present else { return nil }
        var input = P2XRInput()
        input.spatial = 1
        var leftClick = false, rightClick = false
        for (accessory, controller) in bindings {
            let profile = controller.input
            func pressed(_ names: GCButtonElementName...) -> Bool {
                names.contains { profile.buttons[$0]?.pressedInput.isPressed == true }
            }
            let stick = profile.dpads[.thumbstick]
            let trigger = profile.buttons[.trigger]?.pressedInput.value ?? 0
            let lower = pressed(.a, .x), upper = pressed(.b, .y)
            switch accessory.inherentChirality {
            case .left:
                leftClick = pressed(.thumbstickButton)
                input.move_x = stick?.xAxis.value ?? 0
                input.move_y = stick?.yAxis.value ?? 0
                input.orange_trigger = trigger
                if lower { input.buttons |= UInt32(P2_XR_USE.rawValue) }
                if upper { input.buttons |= UInt32(P2_XR_CROUCH.rawValue) }
            case .right:
                rightClick = pressed(.thumbstickButton)
                input.turn_x = stick?.xAxis.value ?? 0
                input.look_y = stick?.yAxis.value ?? 0
                input.blue_trigger = trigger
                if lower { input.buttons |= UInt32(P2_XR_JUMP.rawValue) }
                if upper { input.buttons |= UInt32(P2_XR_CROUCH.rawValue) }
            default: continue
            }
            input.connected = 1
            if pressed(.grip) { input.buttons |= UInt32(P2_XR_USE.rawValue) }
            if pressed(.menu, .options) { input.buttons |= UInt32(P2_XR_PAUSE.rawValue) }
        }
        if leftClick && rightClick { input.buttons |= UInt32(P2_XR_WINDOW.rawValue) }
        else if leftClick { input.buttons |= UInt32(P2_XR_RECENTER.rawValue) }
        trace(input)
        return input
    }

    func writePoses(at timestamp: Double, into frame: inout P2XRFrame) {
        guard let provider = lock.withLock({ provider }), provider.state == .running else { return }
        let anchors = provider.latestAnchors
        for hand in [Accessory.Chirality.left, .right] {
            let matches = anchors.filter { $0.accessory.inherentChirality == hand }
            guard matches.count == 1, let latest = matches.first,
                  let anchor = provider.predictAnchor(for: latest, at: timestamp),
                  anchor.trackingState == .positionOrientationTracked,
                  anchor.accessory.locations.contains(.aim), anchor.accessory.locations.contains(.grip) else { continue }
            // Coordinate spaces use a world reference ancestor. Convert the
            // location back into ARKit's origin used by the head anchor.
            let referenceFromAnchor = anchor.coordinateSpace(correction: .none).ancestorFromSpaceTransformFloat().matrix
            let originFromReference = anchor.originFromAnchorTransform * simd_inverse(referenceFromAnchor)
            var pose = P2XRControllerPose()
            pose.tracked = 1
            pose.tracking_from_aim = originFromReference * anchor.coordinateSpace(for: .aim, correction: .none).ancestorFromSpaceTransformFloat().matrix
            pose.tracking_from_grip = originFromReference * anchor.coordinateSpace(for: .grip, correction: .none).ancestorFromSpaceTransformFloat().matrix
            if hand == .left { frame.controllers.0 = pose }
            else { frame.controllers.1 = pose }
        }
    }

    @MainActor func stop() {
        stopped = true
        generation += 1
        refreshTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        bindings = []
        present = false
        connectedDevices = 0
        lock.withLock { provider = nil }
    }
}
