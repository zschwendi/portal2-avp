#if P2_GAME
import ARKit
import Foundation
import QuartzCore
import SwiftUI
import UIKit

// Exactly one engine-frame consumer: the window MTKView (owner 0) or the
// immersive renderer holding ownership by its xr session. Acquiring under this
// lock means ownership only changes between acquires. Leases are refcounted in
// gl_vision and each consumer releases its own after GPU completion.
final class PortalPresentation: @unchecked Sendable {
    static let shared = PortalPresentation()
    struct Gameplay { var worldFrames: UInt64 = 0, worldTime = 0.0, menuTime = 0.0, pauseTime = 0.0 }
    private let lock = NSLock()
    private var owner: UInt64 = 0
    private var ready = false
    private var play = Gameplay()

    var windowOwns: Bool { lock.withLock { owner == 0 } }

    func acquireWindow(_ frame: inout P2VisionGLFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == 0 else { return false }
        return p2_vision_gl_acquire(&frame) != 0
    }

    func acquireImmersive(_ session: UInt64, _ frame: inout P2VisionGLFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard session != 0, owner == session else { return false }
        return p2_vision_gl_acquire(&frame) != 0
    }

    // The engine renders the immersive eye size only while that renderer owns
    // the frames; every ownership change withdraws it (back to windowed 16:9).
    func grant(_ session: UInt64) {
        lock.withLock { owner = session; ready = false; play = Gameplay(); p2_vision_request_eye_size(0, 0) }
    }
    func revoke(_ session: UInt64) {
        lock.withLock { if session != 0 && owner == session { owner = 0; p2_vision_request_eye_size(0, 0) } }
    }
    func revokeImmersive() { lock.withLock { owner = 0; p2_vision_request_eye_size(0, 0) } }

    @discardableResult
    func requestEyeSize(_ session: UInt64, width: Int32, height: Int32) -> Bool {
        lock.withLock {
            guard session != 0, owner == session else { return false }
            p2_vision_request_eye_size(width, height)
            return true
        }
    }

    // From a completed command buffer that presented engine pixels for
    // `session`. True exactly once per grant: the first valid frame.
    func completed(_ session: UInt64, world: Bool) -> Bool {
        lock.withLock {
            guard session != 0, owner == session else { return false }
            let now = CACurrentMediaTime()
            if world { play.worldFrames += 1; play.worldTime = now } else { play.menuTime = now }
            defer { ready = true }
            return !ready
        }
    }

    // Only a press made during gameplay counts; a press that resumes from a
    // visible menu must not later send a loading screen back to the window.
    func pausePressed(_ session: UInt64) {
        guard p2_vision_game_ui_visible() == 0 else { return }
        lock.withLock { if session != 0 && owner == session { play.pauseTime = CACurrentMediaTime() } }
    }

    func gameplay(_ session: UInt64) -> Gameplay {
        lock.withLock { session != 0 && owner == session ? play : Gameplay() }
    }
}

// Window <-> immersive lifecycle for the one running engine. The space is
// value-tagged with its attempt; only the first renderer of the current
// attempt presents. CompositorLayer is scene content, not a View, so the
// environment actions are adopted from the window and outlive it.
//
//   window --expand--> opening --first completed frame + .opened--> presenting (window dismissed)
//   opening --cancel/error/8 s/renderer stop/stick hold--> closing (window kept, message)
//   presenting --pause/stick hold/system close--> returning --window appeared--> closing
//   closing --space dismissed + every renderer GPU-retired--> window
@MainActor
final class PortalGameFlow: ObservableObject {
    enum Phase: String { case window, opening, presenting, returning, closing }
    static let shared = PortalGameFlow()
    nonisolated static let spaceID = "game-world", windowID = "game-window"
    private static let firstFrameTimeout = Duration.seconds(8)
    private static let windowTimeout = Duration.seconds(2)
    private static let pauseDebounce = 0.3, pauseLead = 1.5

    @Published private(set) var phase = Phase.window
    @Published private(set) var message: String?
    @Published private(set) var engineFrames = false
    @Published private(set) var renderersLive = 0
    @Published private(set) var dismissing = false
    private(set) var controlsSession: UInt64 = 0
    private var attempt: UInt64 = 0
    private var rendererSerial: UInt64 = 0, rendererSession: UInt64 = 0
    private var live = Set<UInt64>()
    private var openInFlight = false, spaceOpen = false, ready = false
    // Per-view tokens: a window retired by present() may report onDisappear
    // late, after a replacement window appeared, without zeroing the count.
    private var windowTokens = Set<UUID>(), retiredWindows = Set<UUID>()
    private var windows: Int { windowTokens.subtracting(retiredWindows).count }
    private var windowRequested = false
    private var dismissal: Task<Void, Never>?
    private var dismissals: UInt64 = 0
    private var deadline: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var autoEnterTaken = false
    private var spatial: (any PortalSpatialSource)?
    private var openSpace: OpenImmersiveSpaceAction?
    private var dismissSpace: DismissImmersiveSpaceAction?
    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    private var observers: [NSObjectProtocol] = []

    var canExpand: Bool {
        phase == .window && renderersLive == 0 && !dismissing && engineFrames && p2_vision_game_state() == 1
    }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .portalRequestWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PortalGameFlow.shared.requestWindow() }
        })
        observers.append(center.addObserver(forName: .portalRendererReady, object: nil, queue: .main) { note in
            let attempt = note.userInfo?["attempt"] as? UInt64 ?? 0, session = note.userInfo?["session"] as? UInt64 ?? 0
            let world = note.userInfo?["world"] as? Bool ?? false
            MainActor.assumeIsolated { PortalGameFlow.shared.rendererReady(attempt: attempt, session: session, world: world) }
        })
        observers.append(center.addObserver(forName: .portalRendererStopped, object: nil, queue: .main) { note in
            let attempt = note.userInfo?["attempt"] as? UInt64 ?? 0, session = note.userInfo?["session"] as? UInt64 ?? 0
            let serial = note.userInfo?["renderer"] as? UInt64 ?? 0
            MainActor.assumeIsolated { PortalGameFlow.shared.rendererStopped(attempt: attempt, session: session, serial: serial) }
        })
    }

    private func log(_ text: String) { NSLog("[P2Flow] %@", text) }

    func adopt(openSpace: OpenImmersiveSpaceAction, dismissSpace: DismissImmersiveSpaceAction,
               openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        self.openSpace = openSpace
        self.dismissSpace = dismissSpace
        self.openWindow = openWindow
        self.dismissWindow = dismissWindow
    }

    // MARK: Window scene

    func windowAppeared(_ token: UUID) {
        windowTokens.insert(token)
        windowRequested = false
        log("Window appeared (count \(windows), phase \(phase.rawValue), attempt \(attempt))")
        if phase == .returning { beginClosing(nil) } else { attachWindowControls() }
    }

    func windowDisappeared(_ token: UUID) {
        windowTokens.remove(token)
        retiredWindows.remove(token)
        log("Window disappeared (count \(windows), phase \(phase.rawValue))")
        if windows == 0 { detachWindowControls() }
    }

    func engineFrameSeen() {
        guard !engineFrames else { return }
        engineFrames = true
        // Development auto-enter, once per process (not per reopened window).
        if !autoEnterTaken, ProcessInfo.processInfo.arguments.contains("--immersive-test") {
            autoEnterTaken = true
            Task { await expand() }
        }
    }

    // The window publishes controls only while it owns presentation. The
    // immersive renderer's own session supersedes it while presenting.
    private func attachWindowControls() {
        guard windows > 0, phase == .window || phase == .closing, PortalPresentation.shared.windowOwns,
              p2_xr_abi_version() == P2_XR_ABI_VERSION, p2_xr_session_active(controlsSession) == 0 else { return }
        detachWindowControls()
        controlsSession = p2_xr_begin_window_session()
        if #available(visionOS 26.0, *) {
            let source = PortalSenseTracking(session: ARKitSession(), world: WorldTrackingProvider(), trackPoses: false)
            spatial = source
            source.start()
        }
        PortalController.attach(session: controlsSession, spatial: spatial)
    }

    private func detachWindowControls() {
        guard controlsSession != 0 else { return }
        PortalController.stop(session: controlsSession)
        spatial?.stop()
        spatial = nil
        p2_xr_end_session(controlsSession)  // no-op once a renderer session superseded it
        controlsSession = 0
    }

    // MARK: Expand

    func expand() async {
        guard canExpand, let openSpace else { return }
        attempt &+= 1
        let attempt = self.attempt
        phase = .opening
        message = nil
        ready = false
        rendererSerial = 0
        rendererSession = 0
        openInFlight = true
        log("Opening immersive attempt \(attempt)")
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: PortalGameFlow.firstFrameTimeout)
            guard !Task.isCancelled, let self, self.attempt == attempt, self.phase == .opening else { return }
            self.log("Attempt \(attempt): no completed immersive frame within 8 s")
            self.beginClosing("The immersive view didn't show the game within 8 seconds. Still playing here.")
        }
        let result = await openSpace(id: Self.spaceID, value: attempt)
        openInFlight = false
        log("Attempt \(attempt) open result: \(result) (phase \(phase.rawValue))")
        switch result {
        case .opened:
            spaceOpen = true
            if phase != .opening { requestDismissal() }  // this attempt already ended
            else if ready { present() }
        case .userCancelled:
            if phase == .opening { beginClosing("Opening the immersive view was cancelled.") }
        case .error:
            if phase == .opening { beginClosing("The immersive view couldn't open.") }
        @unknown default:
            if phase == .opening { beginClosing("The immersive view is unavailable.") }
        }
        finishIfComplete()
    }

    // Called by PortalRenderer.start on the main actor, for every layer.
    func rendererArriving(attempt: UInt64, serial: UInt64) -> Bool {
        live.insert(serial)
        renderersLive = live.count
        spaceOpen = true
        let accept = attempt != 0 && attempt == self.attempt && phase == .opening && rendererSerial == 0
        log("Renderer \(serial) arrived for attempt \(attempt) (current \(self.attempt), phase \(phase.rawValue)): \(accept ? "presenting" : "black, not presenting")")
        if accept { rendererSerial = serial }
        else if phase == .window || phase == .closing { requestDismissal() }
        return accept
    }

    func rendererPresenting(serial: UInt64, session: UInt64) {
        guard serial == rendererSerial, phase == .opening, session != 0 else { return }
        rendererSession = session
        detachWindowControls()
        PortalPresentation.shared.grant(session)  // the window keeps its last picture
        log("Attempt \(attempt): immersive session \(session) owns engine frames")
    }

    private func rendererReady(attempt: UInt64, session: UInt64, world: Bool) {
        guard attempt == self.attempt, session != 0, session == rendererSession else {
            log("Ignored stale readiness: attempt \(attempt) session \(session)")
            return
        }
        log("Attempt \(attempt): first immersive \(world ? "stereo world" : "menu panel") frame completed on the GPU (session \(session))")
        guard phase == .opening else { return }
        ready = true
        if spaceOpen && !openInFlight { present() }
    }

    private func present() {
        deadline?.cancel()
        phase = .presenting
        log("Attempt \(attempt) presenting; retiring the window (\(windows) visible)")
        // Unconditional: full immersion may hide a window without dismissing it.
        // Every current window is retired; the return path then reopens one.
        retiredWindows = windowTokens
        dismissWindow?.callAsFunction(id: Self.windowID)
        startMonitor()
    }

    // MARK: Return

    func requestWindow() {
        switch phase {
        case .opening: beginClosing("Immersive view cancelled.")
        case .presenting: returnToWindow("controller window request")
        default: break
        }
    }

    private func returnToWindow(_ reason: String) {
        guard phase == .presenting else { return }
        monitor?.cancel()
        phase = .returning
        log("Attempt \(attempt) returning to the window: \(reason)")
        if windows > 0 { beginClosing(nil); return }
        guard UIApplication.shared.applicationState == .active, let openWindow else {
            log("App not active; the system reopens the window on the next launch")
            beginClosing(nil)
            return
        }
        // Window first, then the space, so the app always keeps a scene.
        windowRequested = true
        openWindow(id: Self.windowID)
        let attempt = self.attempt
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: PortalGameFlow.windowTimeout)
            guard !Task.isCancelled, let self, self.attempt == attempt, self.phase == .returning else { return }
            self.log("Attempt \(attempt): window did not appear within 2 s; dismissing the space anyway")
            self.windowRequested = false
            self.beginClosing(nil)
        }
    }

    private func beginClosing(_ message: String?) {
        deadline?.cancel()
        monitor?.cancel()
        if let message { self.message = message; log(message) }
        phase = .closing
        PortalPresentation.shared.revokeImmersive()
        attachWindowControls()
        if windows == 0 && !windowRequested && UIApplication.shared.applicationState == .active, let openWindow {
            windowRequested = true
            openWindow(id: Self.windowID)
        }
        if spaceOpen { requestDismissal() }  // an in-flight open is dismissed when it returns
        finishIfComplete()
    }

    // Dismissals run one at a time; only the newest one settles the state.
    private func requestDismissal() {
        guard let dismissSpace else { spaceOpen = false; finishIfComplete(); return }
        dismissals &+= 1
        let request = dismissals, previous = dismissal
        dismissing = true
        dismissal = Task { [weak self] in
            await previous?.value
            await dismissSpace()
            guard let self, request == self.dismissals else { return }
            self.spaceOpen = false
            self.dismissing = false
            self.log("Immersive space dismissed (request \(request))")
            self.finishIfComplete()
        }
    }

    private func rendererStopped(attempt: UInt64, session: UInt64, serial: UInt64) {
        live.remove(serial)
        renderersLive = live.count
        let current = serial != 0 && serial == rendererSerial
        log("Renderer \(serial) stopped after GPU retirement: attempt \(attempt) session \(session) \(current ? "current" : "stale"), \(live.count) live")
        if current {
            rendererSerial = 0
            switch phase {
            case .opening: beginClosing("The immersive view closed before it showed the game.")
            case .presenting: returnToWindow("immersive space closed by the system")
            default: break
            }
        }
        attachWindowControls()
        finishIfComplete()
    }

    // Quarantine: a new space may open only after the previous one is gone and
    // every renderer has retired its last command buffer.
    private func finishIfComplete() {
        guard phase == .closing, !openInFlight, !spaceOpen, !dismissing, live.isEmpty else { return }
        phase = .window
        rendererSession = 0
        windowRequested = false
        log("Attempt \(attempt) closed; the window owns the running game")
        attachWindowControls()
    }

    // MARK: Pause -> window

    // Conservative: game UI (engine flag, or menu-only frames after world
    // frames) held for the debounce, after stereo world frames in this session,
    // and following a pause press. Map loads and death reloads show UI without
    // a pause press and stay immersive; they are logged.
    private func startMonitor() {
        monitor?.cancel()
        let attempt = self.attempt, session = rendererSession
        monitor = Task { [weak self] in
            var since: Double?, worldBefore: UInt64 = 0, shown = false, held = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.phase == .presenting, self.attempt == attempt else { return }
                if p2_vision_game_state() != 1 { self.returnToWindow("engine stopped"); return }
                let now = CACurrentMediaTime(), play = PortalPresentation.shared.gameplay(session)
                let flag = p2_vision_game_ui_visible() != 0
                let menuOnly = play.worldFrames > 0 && play.menuTime > play.worldTime && now - play.menuTime < 0.25
                let visible = flag || menuOnly
                if visible != shown {
                    shown = visible
                    let pause = play.pauseTime > 0 ? String(format: "%.2f s ago", now - play.pauseTime) : "none"
                    self.log("Attempt \(attempt): game UI \(visible ? "visible" : "hidden") (engine flag \(flag ? 1 : 0), menu-only frames \(menuOnly ? 1 : 0), world frames \(play.worldFrames), pause press \(pause))")
                }
                guard visible else { since = nil; held = false; continue }
                if since == nil { since = now; worldBefore = play.worldFrames }
                guard let start = since, now - start >= PortalGameFlow.pauseDebounce else { continue }
                let paused = play.pauseTime > 0 && play.pauseTime >= start - PortalGameFlow.pauseLead
                if worldBefore > 0 && paused {
                    self.returnToWindow("game paused (UI held \(Int((now - start) * 1000)) ms)")
                    return
                }
                if !held {
                    held = true
                    self.log("Attempt \(attempt): game UI held without \(worldBefore == 0 ? "prior stereo gameplay" : "a pause press (map load or reload?)"); staying immersive")
                }
            }
        }
    }
}
#endif
