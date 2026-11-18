#if P2_GAME
import IOSurface
import GameController
import MetalKit
import SwiftUI

enum PortalCampaignLaunch: Equatable, Sendable {
    case gameMenu, campaignIfPresent, continueCampaign

    var native: Int32 {
        switch self {
        case .gameMenu: return Int32(P2_VISION_GAME_MENU)
        case .campaignIfPresent: return Int32(P2_VISION_CAMPAIGN_IF_PRESENT)
        case .continueCampaign: return Int32(P2_VISION_CAMPAIGN_REQUIRED)
        }
    }
}

// The one window: the Library (PortalLauncherView.swift) until Play, then the
// running game with the expand arrows. The engine has one lifetime per
// process; the Library can cover the running game (Resume returns to it) and
// the window can be dismissed for immersive play, and neither stops it.
struct PortalGameView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @ObservedObject private var flow = PortalGameFlow.shared
    @State private var windowToken = UUID()
    @State private var aspect = 16.0 / 9.0
    @StateObject private var importer = PortalContentImporter()
    private let saveSession = PortalCloudSaves.mobile
    @State private var savePlayRequest = 0
    @State private var preparingSaves = false
    @State private var pendingLaunch = PortalCampaignLaunch.gameMenu
    @State private var engine = p2_vision_game_state()
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var checking = false
    @State private var starting = false
    @State private var libraryOverGame = false
    @State private var sheet: PortalLibrarySheet?
    @State private var notice: String?
    // The last owned-content check (complete or not); nil before one finishes.
    @State private var setup: PortalContentSetup?

    private var showsGame: Bool { engine == 1 && !libraryOverGame }
    private var abiMatches: Bool { p2_xr_abi_version() == P2_XR_ABI_VERSION }

    var body: some View {
        Group {
            if showsGame { game } else { library }
        }
        .handlesGameControllerEvents(matching: .gamepad)
        // Hidden while a transition is in flight or the space presents.
        .ornament(visibility: showsGame && flow.phase == .window ? .visible : .hidden,
                  attachmentAnchor: .scene(.topTrailing)) {
            PortalExpandControl(enabled: flow.canExpand(from: windowToken)) { Task { await flow.expand(from: windowToken) } }
        }
        .ornament(visibility: showsGame && flow.phase == .window ? .visible : .hidden,
                  attachmentAnchor: .scene(.topLeading)) {
            PortalLibraryControl { showLibrary() }
        }
        .onAppear {
            flow.adopt(openSpace: openSpace, dismissSpace: dismissSpace, openWindow: openWindow, dismissWindow: dismissWindow)
            flow.windowAppeared(windowToken)
        }
        .task { await prepare() }
        .task {
            // The engine flips state on its own thread (start, return).
            while !Task.isCancelled {
                let current = p2_vision_game_state()
                if current != engine { engine = current }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: engine == 1 && libraryOverGame, initial: true) { _, covered in
            PortalController.setLauncherVisible(covered)
        }
        .onChange(of: scenePhase) { _, value in
            PortalController.suspend(session: flow.controlsSession, value != .active)
            // Back from Settings (freed space) or elsewhere: look again.
            if value == .active, engine != 1, setup?.complete != true, !importing, !checking {
                Task { await refresh("foreground", start: false) }
            }
        }
        .onDisappear {
            PortalController.setLauncherVisible(false)
            flow.windowDisappeared(windowToken)
        }
    }

    private var game: some View {
        ZStack {
            Color.black
            PortalGameSurface(onAspect: { aspect = $0 }, onPicture: { flow.windowFramePresented(windowToken) })
                .aspectRatio(aspect, contentMode: .fit)
        }
        .ignoresSafeArea()
        .overlay {
            if flow.phase == .opening {
                PortalPanel { ProgressView("Opening immersive view\u{2026}").padding(8) }
                    .portalThemed()
                    .allowsHitTesting(false)
            } else if !flow.windowHasPicture(windowToken) {
                ZStack {
                    PortalBackdrop()
                    if flow.hasPresentedImmersive {
                        ProgressView("Restoring the game window\u{2026}")
                    } else {
                        ProgressView("Starting Portal 2\u{2026}")
                    }
                }
                .portalThemed()
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = flow.message ?? stereoAuditMessage {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackgroundEffect()
                    .padding(16)
            }
        }
    }

    private var stereoAuditMessage: String? {
        guard ProcessInfo.processInfo.environment["P2_VISION_STEREO_AUDIT"] == "1" else { return nil }
        return "Stereo renderer audit: fixed eye separation, no tracked headset pose."
    }

    private var library: some View {
        PortalLibraryView(state: cardState, setup: setup, message: notice, importer: importer,
                          importing: importing, checking: checking, play: { intent in Task { await play(intent) } },
                          resume: resume, checkAgain: { Task { await refresh("check-again", start: false) } },
                          startImport: startImport, cancelImport: { importTask?.cancel() },
                          dismissMessage: { notice = nil }, saveSession: saveSession,
                          canUseSaveControls: engine != 1 && engine != 2 && !starting && !checking,
                          savesChanged: { Task { await refresh("saves-updated", start: false) } },
                          playOffline: preparingSaves && saveSession.cloudConfigured
                            ? { Task { await startFromLocalSaves() } } : nil,
                          sheet: $sheet)
    }

    private var cardState: PortalCardState {
        PortalCardState.resolve(engine: engine, content: setup.map(\.complete), nothingImported: setup?.nothingImported ?? false,
                                importing: importing,
                                importFraction: importer.totalBytes > 0 ? Double(importer.completedBytes) / Double(importer.totalBytes) : nil,
                                starting: starting,
                                campaignSaveAvailable: setup?.campaignSaveAvailable == true && saveSession.controller != nil)
    }

    // MARK: Actions

    private func showLibrary() {
        // Pause first (only during gameplay), then hold input while the
        // Library covers the game.
        PortalController.pauseGameplay()
        libraryOverGame = true
    }

    private func resume() {
        libraryOverGame = false
        sheet = nil
    }

    @MainActor private func play(_ intent: PortalCampaignLaunch) async {
        guard engine != 1, !starting, !importing else { return }
        guard abiMatches else { notice = "This build needs its native libraries rebuilt."; return }
        starting = true
        await refresh("play", start: true, intent: intent)
        if !checking { starting = false }
    }

    @MainActor private func startFromLocalSaves() async {
        guard preparingSaves, let saves = saveSession.controller else { return }
        savePlayRequest += 1
        preparingSaves = false
        guard saves.playOffline() else {
            checking = false
            starting = false
            notice = saves.status
            return
        }
        await startCheckedContent("play", intent: pendingLaunch)
        starting = false
    }

    // Icon launches show the Library. Development launches keep starting by
    // themselves: --engine-test/--immersive-test, and --import-content URL
    // (import, then start).
    @MainActor private func prepare() async {
        guard engine != 1, !importing, !checking else { return }
        if !abiMatches { notice = "This build needs its native libraries rebuilt." }
        let arguments = ProcessInfo.processInfo.arguments
        let autoStart = arguments.contains("--engine-test") || arguments.contains("--immersive-test")
        if engine != 2, let index = arguments.firstIndex(of: "--import-content"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            let task = Task { @MainActor in
                if await runImport(url) { await refresh("import", start: abiMatches) }
            }
            importTask = task   // Cancel Import reaches it too
            await task.value
            importTask = nil
            return
        }
        if engine == 2 { return }
        await refresh(autoStart ? "launch" : "library", start: autoStart && abiMatches)
    }

    private func startImport(_ url: URL) {
        guard !importing, engine != 1 else { return }
        importTask = Task { @MainActor in
            if await runImport(url) { await refresh("import", start: false) }
            importTask = nil
        }
    }

    // Never while the engine runs: it reads these files.
    @MainActor private func runImport(_ url: URL) async -> Bool {
        guard !importing, p2_vision_game_state() != 1 else { return false }
        importing = true
        notice = nil
        var failure: Error?
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try await importer.run(manifestURL: url, documents: documents)
        } catch { failure = error }
        importing = false
        guard let failure else { return true }
        if failure is CancellationError {
            await refresh("import-cancelled", start: false)
        } else {
            let error = failure as NSError
            let reason = error.userInfo[NSURLErrorNetworkUnavailableReasonKey] as? NSNumber
            fputs("[vision-import] Failed: domain=\(error.domain) code=\(error.code) network_reason=\(reason?.intValue ?? -1)\n", stderr)
            notice = "The import stopped. Check Local Network access and your Mac\u{2019}s connection, then try again."
            await refresh("import-failed", start: false)
        }
        return false
    }

    // Runs the content check off the main actor; with `start`, starts the
    // engine only if it passes (p2_vision_game_start enforces the same gate).
    @MainActor private func refresh(_ trigger: String, start: Bool, intent: PortalCampaignLaunch = .gameMenu) async {
        guard !checking, !importing else { return }
        checking = true
        guard start else {
            setup = await PortalContentSetup.check(trigger, start: false)
            checking = false
            engine = p2_vision_game_state()
            return
        }
        guard let saves = saveSession.controller else {
            notice = saveSession.layoutIssue
            if intent == .continueCampaign {
                checking = false
                return
            }
            await startCheckedContent(trigger, intent: .gameMenu)
            return
        }
        savePlayRequest += 1
        let request = savePlayRequest
        pendingLaunch = intent
        preparingSaves = true
        let ready = await saves.prepareForPlay()
        guard savePlayRequest == request else { return }
        preparingSaves = false
        guard ready, !Task.isCancelled else {
            if ready { saves.gameplayDidEnd() }
            checking = false
            notice = saves.status
            return
        }
        await startCheckedContent(trigger, intent: intent)
    }

    @MainActor private func startCheckedContent(_ trigger: String, intent: PortalCampaignLaunch) async {
        let result = await PortalContentSetup.check(trigger, start: true, intent: intent)
        checking = false
        engine = p2_vision_game_state()
        if let result {
            saveSession.controller?.gameplayDidEnd()
            setup = result
            if result.resumeUnavailable { notice = "No valid campaign save was found. Open Saves to check the available versions." }
            if !result.complete { sheet = .importFiles }
            return
        }
        // rt_destroy may leave native workers alive. After a launch attempt
        // succeeds, retain ownership for the rest of this process.
        setup?.complete = true
        if engine == 2 { notice = PortalContentSetup.stopped }
    }
}

// Returns from the running game to the Library (the game pauses).
private struct PortalLibraryControl: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect()
        .accessibilityLabel("Library")
        .accessibilityHint("Pauses the game and shows the Library.")
        .help("Library")
    }
}

// What the owned-content check found (runtime/content_check.h), worded for
// the Library card and the Game Files sheet. Names are owned file names only.
struct PortalContentSetup: Equatable, Sendable {
    var complete = false
    var campaignSaveAvailable = false
    var resumeUnavailable = false
    var requiredMissing = 0, badDirectories = 0, archives = 0, missingArchives = 0, shortArchives = 0
    // The import's list of every owned file (absent: content copied another
    // way; then the first campaign map stands in for the loose files).
    var manifest = false, manifestBad = false, mapsMissing = false
    var manifestFiles = 0, manifestMissing = 0, manifestWrongSize = 0
    var missingBytes: Int64 = 0
    var available: Int64?, total: Int64?
    var names: [String] = []

    static let stopped = "Portal 2 has stopped. Close and reopen the app to play again."

    init(_ report: P2ContentReport) {
        complete = report.complete != 0
        requiredMissing = Int(report.required_missing)
        badDirectories = Int(report.bad_directories)
        archives = Int(report.archives)
        missingArchives = Int(report.missing_archives)
        shortArchives = Int(report.short_archives)
        manifest = report.manifest != 0
        manifestBad = report.manifest_bad != 0
        mapsMissing = report.maps_missing != 0
        manifestFiles = Int(report.manifest_files)
        manifestMissing = Int(report.manifest_missing)
        manifestWrongSize = Int(report.manifest_wrong_size)
        missingBytes = max(report.missing_bytes, 0)
        available = report.volume_available >= 0 ? report.volume_available : nil
        total = report.volume_total >= 0 ? report.volume_total : nil
        names = (0..<Int(max(report.names, 0))).map { index in
            withUnsafePointer(to: report) { String(cString: p2_content_report_name($0, Int32(index))) }
        }
    }

    // Off the main actor: reads the VPK directory trees and the volume's free
    // space. nil when the engine started (or already runs or returned).
    static func check(_ trigger: String, start: Bool, intent: PortalCampaignLaunch = .gameMenu) async -> PortalContentSetup? {
        await Task.detached(priority: .userInitiated) { () -> PortalContentSetup? in
            var report = P2ContentReport()
            if start {
                let status = p2_vision_game_start(trigger, intent.native)
                if status == 0 { return nil }
                _ = p2_vision_content_last(&report)
                var result = PortalContentSetup(report)
                result.resumeUnavailable = status == -2
                return result
            }
            _ = p2_vision_content_check(trigger, &report)
            var result = PortalContentSetup(report)
            result.campaignSaveAvailable = result.complete && p2_vision_has_campaign_save() != 0
            return result
        }.value
    }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var nothingImported: Bool { requiredMissing >= 3 }
    // With a readable list, a missing archive is also one of its missing files: count it once.
    private var problems: Int {
        let archive = requiredMissing + badDirectories + missingArchives + shortArchives
        let listed = manifest && !manifestBad ? manifestMissing + manifestWrongSize : 0
        return max(archive, listed) + (manifestBad ? 1 : 0) + (mapsMissing ? 1 : 0)
    }
    var moreNames: Bool { problems > names.count }
    var spaceShort: Bool { available.map { missingBytes > 0 && $0 < missingBytes } ?? false }

    var title: String {
        if complete { return "The import stopped" }
        return nothingImported ? "Portal 2\u{2019}s game files aren\u{2019}t on this Vision Pro yet" : "Portal 2\u{2019}s game files are incomplete"
    }
    // One line for the window's status text.
    var headline: String {
        if complete { return "Your Portal 2 files are complete." }
        return nothingImported ? "Import your Portal 2 files to play." : "Portal 2 can\u{2019}t start until its game files are complete."
    }
    // e.g. "412 of 3,592 game files are missing, about 2.7 GB." (with the
    // import's file list) or "112 of 148 game archives are missing, about 3.4 GB."
    var detail: String {
        if complete { return "The files already on this Vision Pro are complete, so Portal 2 can start." }
        if nothingImported {
            return "Portal 2 runs from your own copy of the game: its content, the Linux depot files and the prepared images."
        }
        var parts: [String] = []
        if manifest && !manifestBad {
            if manifestMissing > 0 {
                parts.append(manifestMissing == 1 ? "1 of \(manifestFiles.formatted()) game files is missing"
                             : "\(manifestMissing.formatted()) of \(manifestFiles.formatted()) game files are missing")
            }
            if manifestWrongSize > 0 {
                parts.append(manifestWrongSize == 1 ? "1 game file is only partly copied or differs from your Mac\u{2019}s copy"
                             : "\(manifestWrongSize.formatted()) game files are only partly copied or differ from your Mac\u{2019}s copies")
            }
        }
        // Archive wording: no list, an unreadable one, or what only the archive check sees.
        if parts.isEmpty { parts = archiveParts }
        var text = parts.joined(separator: "; ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        if missingBytes > 0 { text += ", about \(Self.size(missingBytes))" }
        return text + "."
    }
    private var archiveParts: [String] {
        var parts: [String] = []
        if manifestBad { parts.append("the list of game files (\(PortalContentImporter.contentManifestName)) is unreadable or damaged") }
        if missingArchives > 0 { parts.append("\(missingArchives) of \(archives) game archives are missing") }
        if shortArchives > 0 {
            parts.append(shortArchives == 1 ? "1 archive is only partly copied" : "\(shortArchives) archives are only partly copied")
        }
        if badDirectories > 0 {
            parts.append(badDirectories == 1 ? "1 archive index is damaged or cut short" : "\(badDirectories) archive indexes are damaged or cut short")
        }
        if requiredMissing > 0 {
            parts.append(requiredMissing == 1 ? "1 required file is missing" : "\(requiredMissing) required files are missing")
        }
        if mapsMissing { parts.append("the campaign maps (game/portal2/maps) are missing") }
        return parts
    }
    var space: String {
        guard let available else { return missingBytes > 0 ? "About \(Self.size(missingBytes)) more is needed." : "" }
        var text = "Free space on this Vision Pro: \(Self.size(available))" + (total.map { " of \(Self.size($0))" } ?? "") + "."
        if missingBytes > 0 {
            text += " Needed: about \(Self.size(missingBytes))."
            if available < missingBytes {
                text += " Free up at least \(Self.size(missingBytes - available)) in Settings \u{203A} General \u{203A} Storage first."
            }
        }
        return text
    }
}

// The familiar expand control (AVPcraft/Minecraft host): a 44 pt glass circle
// ornament on the window's top-trailing corner.
private struct PortalExpandControl: View {
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect()
        .accessibilityLabel("Enter immersive view")
        .accessibilityHint(enabled ? "Play this running game around you." : "Available once the game shows a picture.")
        .help("Enter immersive view")
        .disabled(!enabled)
    }
}

private struct PortalGameSurface: UIViewRepresentable {
    let onAspect: @MainActor @Sendable (Double) -> Void
    let onPicture: @MainActor @Sendable () -> Void
    func makeCoordinator() -> PortalGameSurfaceRenderer { PortalGameSurfaceRenderer(onAspect: onAspect, onPicture: onPicture) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = true
        view.layer.isOpaque = true
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = Int(p2_vision_game_fps_limit())
        context.coordinator.configure(view)
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {}
}

private final class PortalGameSurfaceRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var aspect = 0.0
    private var candidateSize: SIMD2<UInt32>?
    private var candidateSequence: UInt64 = 0
    private let reportLock = NSLock()
    private var firstCompletionClaimed = false
    private let onAspect: @MainActor @Sendable (Double) -> Void
    private let onPicture: @MainActor @Sendable () -> Void
    init(onAspect: @escaping @MainActor @Sendable (Double) -> Void, onPicture: @escaping @MainActor @Sendable () -> Void) {
        self.onAspect = onAspect
        self.onPicture = onPicture
    }
    @MainActor func configure(_ view: MTKView) {
        guard p2_xr_abi_version() == P2_XR_ABI_VERSION else { return }
        guard let device = view.device, let library = device.makeDefaultLibrary() else { return }
        queue = device.makeCommandQueue()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "p2_game_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "p2_game_fragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { NSLog("[vision-game] Display pipeline failed: %@", String(describing: error)) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        // While the immersive renderer owns engine frames, keep the last picture;
        // also while the engine returns from the immersive eye size, so the
        // window never adopts a near-square frame's aspect for a moment.
        var frame = P2VisionGLFrame()
        guard PortalPresentation.shared.acquireWindow(&frame) else { return }
        let slot = frame.slot
        var submitted = false
        defer { if !submitted { p2_vision_gl_release(slot) } }
        let paired = frame.kind == P2_VISION_DIAGNOSTIC_STEREO.rawValue
        guard let pointer = frame.surface, frame.width > 0, frame.height > 0,
              paired || PortalPresentation.usableMonoFrame(frame) else { return }
        // Repeated draws of one leased frame aren't proof of a settled size.
        let size = SIMD2(frame.width, frame.height)
        if size != candidateSize {
            candidateSize = size
            candidateSequence = frame.sequence
            return
        }
        guard frame.sequence != candidateSequence, let device = view.device, let pipeline else { return }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: Int(frame.width), height: Int(frame.height), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return }
        var rightTexture: MTLTexture?
        if paired, let pointer = frame.right_surface {
            let right = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            rightTexture = device.makeTexture(descriptor: descriptor, iosurface: right, plane: 0)
        }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue?.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let next = Double(frame.width) * (rightTexture == nil ? 1 : 2) / Double(frame.height)
        if abs(next - aspect) > 0.001 {
            aspect = next
            let onAspect = self.onAspect
            Task { @MainActor in onAspect(next) }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(rightTexture ?? texture, index: 1)
        var stereoFlags = SIMD2<UInt32>(rightTexture == nil ? 0 : 1, frame.flip_left_y)
        encoder.setFragmentBytes(&stereoFlags, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if reportLock.withLock({
            guard !firstCompletionClaimed else { return false }
            firstCompletionClaimed = true
            return true
        }) {
            let sequence = frame.sequence
            command.addCompletedHandler { [weak self] command in
                guard let self else { return }
                guard command.status == .completed else {
                    self.reportLock.withLock { self.firstCompletionClaimed = false }
                    return
                }
                NSLog("[vision-game] Actual engine texture submitted: sequence=%llu %ux%u", sequence, size.x, size.y)
                let onPicture = self.onPicture
                Task { @MainActor in
                    PortalController.reportControllers()
                    onPicture()
                }
            }
        }
        command.addCompletedHandler { _ in p2_vision_gl_release(slot) }
        submitted = true
        command.present(drawable)
        command.commit()
    }
}
#endif
