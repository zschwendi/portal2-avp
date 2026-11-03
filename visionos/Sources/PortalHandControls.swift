import ARKit
import Foundation
import simd

// Hand controls for immersive play. HandTrackingProvider needs an open
// immersive space, so PortalController creates this only after its XR session
// has published a tracked headset frame (window sessions never do) and stops
// it with that session. It runs on its own ARKitSession; the renderer's
// world/accessory session is untouched. Gestures: PortalHandGestures.swift.
@MainActor
final class PortalHandControls {
    // P2XRInput.connected value marking hand-sourced input. input_vision.c
    // (P2_VISION_INPUT_HANDS) keeps it neutral while game menus are visible.
    static let connectedTag: UInt32 = 2

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private var gestures = PortalHandGestures(config: PortalHandConfig(environment: ProcessInfo.processInfo.environment))
    private var task: Task<Void, Never>?
    private var stopped = false
    private var running = false

    // The usage string is only in the game target. Without it, requesting
    // hand tracking would fail, so the renderer check never starts it.
    static var isAvailable: Bool {
        HandTrackingProvider.isSupported &&
            Bundle.main.object(forInfoDictionaryKey: "NSHandsTrackingUsageDescription") != nil
    }

    var isRunning: Bool { running && provider.state == .running }

    func start() {
        guard task == nil, !stopped, Self.isAvailable else { return }
        let session = self.session, provider = self.provider
        task = Task { [weak self] in
            let status = await session.requestAuthorization(for: HandTrackingProvider.requiredAuthorizations)
            guard status.values.allSatisfy({ $0 == .allowed }) else {
                NSLog("[P2XR] Hand tracking not authorized; hand controls stay off")
                return
            }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            do {
                try await session.run([provider])
                guard !self.stopped, !Task.isCancelled else { session.stop(); return }
                self.running = true
                NSLog("[P2XR] Hand tracking running; hands act only without Sense or an active gamepad")
            } catch { NSLog("[P2XR] Hand tracking failed: %@", String(describing: error)) }
        }
    }

    func stop() {
        stopped = true
        running = false
        task?.cancel()
        task = nil
        session.stop()
        gestures.cancel()
    }

    // Neutral now; held pinches must reopen before they act again.
    func cancel() { gestures.cancel() }

    // head: tracking_from_head of the current tracked frame, nil if untracked.
    func snapshot(head: simd_float4x4?, time: Double) -> P2XRInput {
        var input = P2XRInput()
        input.connected = Self.connectedTag
        guard isRunning else { gestures.cancel(); return input }
        let anchors = provider.latestAnchors
        let output = gestures.update(PortalHandFrame(time: time, head: head,
            left: Self.sample(anchors.leftHand), right: Self.sample(anchors.rightHand)))
        input.move_x = output.move.x
        input.move_y = output.move.y
        input.blue_trigger = output.primary
        input.orange_trigger = output.secondary
        if output.jump { input.buttons |= UInt32(P2_XR_JUMP.rawValue) }
        return input
    }

    private static func sample(_ anchor: HandAnchor?) -> PortalHandSample? {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let origin = anchor.originFromAnchorTransform
        func point(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let p = origin * joint.anchorFromJointTransform.columns.3
            return SIMD3(p.x, p.y, p.z)
        }
        return PortalHandSample(wrist: SIMD3(origin.columns.3.x, origin.columns.3.y, origin.columns.3.z),
                                thumbTip: point(.thumbTip), indexTip: point(.indexFingerTip),
                                middleTip: point(.middleFingerTip), indexKnuckle: point(.indexFingerKnuckle),
                                littleKnuckle: point(.littleFingerKnuckle))
    }
}
