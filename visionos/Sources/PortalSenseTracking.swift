import ARKit
import Foundation
import GameController
import simd

protocol PortalSpatialSource: AnyObject, Sendable {
    @MainActor func start()
    @MainActor func stop()
    @MainActor func inputSnapshot() -> P2XRInput?
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
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    @MainActor private func refresh() {
        generation += 1
        let revision = generation
        let previous = refreshTask
        previous?.cancel()
        bindings = []
        let hadProvider = lock.withLock { let present = provider != nil; provider = nil; return present }
        let controllers = GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
        present = !controllers.isEmpty
        refreshTask = Task { [weak self] in
            // Serialize provider changes, including a cancelled run that is
            // still returning from ARKit. A late connection cannot win.
            await previous?.value
            guard let self, !self.stopped, self.generation == revision, !Task.isCancelled else { return }
            var resolved: [(Accessory, GCController)] = []
            for controller in controllers {
                do {
                    let accessory = try await Self.resolve(ObjectIdentifier(controller))
                    guard !Task.isCancelled else { return }
                    resolved.append((accessory, controller))
                } catch { NSLog("[P2XR] Sense identity unavailable: %@", String(describing: error)) }
            }
            guard !self.stopped, self.generation == revision, !Task.isCancelled else { return }
            self.bindings = [Accessory.Chirality.left, .right].compactMap { hand in
                let matches = resolved.filter { $0.0.inherentChirality == hand }
                return matches.count == 1 ? matches[0] : nil
            }
            guard self.trackPoses, AccessoryTrackingProvider.isSupported, !self.bindings.isEmpty else {
                if hadProvider { try? await self.session.run([self.world]) }
                return
            }
            let authorization = await self.session.requestAuthorization(for: AccessoryTrackingProvider.requiredAuthorizations)
            guard authorization.values.allSatisfy({ $0 == .allowed }),
                  !self.stopped, self.generation == revision, !Task.isCancelled else { return }
            let next = AccessoryTrackingProvider(accessories: self.bindings.map { $0.0 })
            do {
                try await self.session.run([self.world, next])
                guard !self.stopped, self.generation == revision, !Task.isCancelled else { return }
                self.lock.withLock { self.provider = next }
                NSLog("[P2XR] Sense tracking provider running for %lu fixed-hand devices; gameplay acceptance pending", self.bindings.count)
            } catch { NSLog("[P2XR] Sense tracking failed: %@", String(describing: error)) }
        }
    }

    @MainActor func inputSnapshot() -> P2XRInput? {
        guard present else { return nil }
        var input = P2XRInput()
        input.spatial = 1
        for (accessory, controller) in bindings {
            let profile = controller.input
            let stick = profile.dpads[.thumbstick]
            let trigger = profile.buttons[.trigger]?.pressedInput.value ?? 0
            let grip = profile.buttons[.grip]?.pressedInput.isPressed == true
            switch accessory.inherentChirality {
            case .left:
                input.move_x = stick?.xAxis.value ?? 0
                input.move_y = stick?.yAxis.value ?? 0
                input.orange_trigger = trigger
                if profile.buttons[.thumbstickButton]?.pressedInput.isPressed == true { input.buttons |= UInt32(P2_XR_RECENTER.rawValue) }
                if profile.buttons[.a]?.pressedInput.isPressed == true { input.buttons |= UInt32(P2_XR_USE.rawValue) }
                if profile.buttons[.b]?.pressedInput.isPressed == true { input.buttons |= UInt32(P2_XR_CROUCH.rawValue) }
            case .right:
                input.connected = 1
                input.turn_x = stick?.xAxis.value ?? 0
                input.blue_trigger = trigger
                if profile.buttons[.a]?.pressedInput.isPressed == true { input.buttons |= UInt32(P2_XR_JUMP.rawValue) }
                if profile.buttons[.b]?.pressedInput.isPressed == true { input.buttons |= UInt32(P2_XR_CROUCH.rawValue) }
            default: break
            }
            if grip { input.buttons |= UInt32(P2_XR_USE.rawValue) }
            if profile.buttons[.menu]?.pressedInput.isPressed == true { input.buttons |= UInt32(P2_XR_PAUSE.rawValue) }
        }
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
        lock.withLock { provider = nil }
    }
}
