#if P2_GAME
import IOSurface
import GameController
import MetalKit
import SwiftUI

struct PortalGameView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @ObservedObject private var flow = PortalGameFlow.shared
    @State private var windowToken = UUID()
    @State private var status = "Checking your Portal 2 files…"
    @State private var started = false
    @State private var aspect = 16.0 / 9.0
    @StateObject private var importer = PortalContentImporter()
    @State private var importing = false
    @State private var importFailed = false
    @State private var checking = false
    // Set while the owned content is incomplete (or an import stopped): the
    // setup panel replaces the game picture and the engine is never started.
    @State private var setup: PortalContentSetup?
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Portal 2").font(.headline)
                Spacer()
                if checking && setup == nil { ProgressView().controlSize(.small) }
            }
            PortalGameSurface(onAspect: { aspect = $0 }).aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    if flow.phase == .opening {
                        ProgressView("Opening immersive view…").padding(24).glassBackgroundEffect()
                    } else if let setup, !started, !importing {
                        PortalSetupPanel(setup: setup, checking: checking, importFailed: importFailed,
                                         checkAgain: { Task { await refresh("check-again", start: true) } },
                                         retryImport: { Task { await prepareGame() } })
                    }
                }
            Text(flow.message ?? status).font(.caption).foregroundStyle(.secondary)
            if importFailed && setup == nil && !started && !checking {
                Button("Retry import") { Task { await prepareGame() } }
            }
            if importing {
                ProgressView(value: Double(importer.completedBytes), total: Double(max(importer.totalBytes,1)))
                Text(importer.status).font(.caption).foregroundStyle(.secondary)
            }
            if started {
                Text("Pause, or hold both stick buttons, to return to this window. L3 alone recenters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
        .handlesGameControllerEvents(matching: .gamepad)
        // Hidden while a transition is in flight or the space presents.
        .ornament(visibility: started && !importing && flow.phase == .window ? .visible : .hidden,
                  attachmentAnchor: .scene(.topTrailing)) {
            PortalExpandControl(enabled: flow.canExpand) { Task { await flow.expand() } }
        }
        .onAppear {
            flow.adopt(openSpace: openSpace, dismissSpace: dismissSpace, openWindow: openWindow, dismissWindow: dismissWindow)
            flow.windowAppeared(windowToken)
        }
        .task {
            if p2_xr_abi_version() != P2_XR_ABI_VERSION { status = "The native input library needs rebuilding." }
            await prepareGame()
        }
        .onChange(of: scenePhase) { _, value in
            PortalController.suspend(session: flow.controlsSession,value != .active)
            // Back from Settings (freed space) or elsewhere: look again.
            if value == .active, setup != nil, !started, !importing, !importFailed {
                Task { await refresh("foreground", start: true) }
            }
        }
        .onDisappear { flow.windowDisappeared(windowToken) }
    }
    // Cold icon launch, --engine-test and after an import: the engine starts by
    // itself once the content check passes; otherwise the setup panel shows.
    @MainActor private func prepareGame() async {
        guard !importing, !checking else { return }
        importFailed = false
        var trigger = "launch"
        if p2_vision_game_state() == 0 || p2_vision_game_state() == -1 {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--import-content"), index+1 < arguments.count,
               let url = URL(string: arguments[index+1]) {
                importing = true
                setup = nil
                status = "Importing your Portal 2 files from your Mac."
                do {
                    let documents = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
                    try await importer.run(manifestURL: url,documents: documents)
                    importing = false
                    status = "Game files imported."
                    trigger = "import"
                } catch {
                    let error = error as NSError
                    let reason = error.userInfo[NSURLErrorNetworkUnavailableReasonKey] as? NSNumber
                    fputs("[vision-import] Failed: domain=\(error.domain) code=\(error.code) network_reason=\(reason?.intValue ?? -1)\n",stderr)
                    importing = false
                    importFailed = true
                    status = "Import stopped. Check Local Network access and your Mac connection, then retry."
                    await refresh("import-failed", start: false)
                    return
                }
            }
        }
        switch p2_vision_game_state() {
        case 1: started = true; setup = nil; status = "Portal 2 is running."
        case 2: status = PortalContentSetup.stopped
        default: await refresh(trigger, start: true)
        }
    }
    // Runs the content check off the main actor; with `start`, starts the
    // engine only if it passes (p2_vision_game_start enforces the same gate).
    @MainActor private func refresh(_ trigger: String, start: Bool) async {
        guard !checking, !importing else { return }
        let abi = p2_xr_abi_version() == P2_XR_ABI_VERSION
        checking = true
        if abi && !importFailed { status = "Checking your Portal 2 files…" }
        let result = await PortalContentSetup.check(trigger, start: start && abi)
        checking = false
        if let result {
            setup = result.complete && !importFailed ? nil : result
            if !abi { status = "The native input library needs rebuilding." }
            else if !importFailed { status = result.headline }
            return
        }
        setup = nil
        if p2_vision_game_state() == 2 { status = PortalContentSetup.stopped; return }
        started = true
        if ProcessInfo.processInfo.environment["P2_VISION_STEREO_AUDIT"] == "1" {
            status = "Stereo renderer audit: fixed eye separation, no tracked headset pose."
        } else {
            status = "Starting Portal 2. Use the expand arrows to play around you in stereo."
        }
    }
}

// What the owned-content check found (runtime/content_check.h), worded for
// the setup panel. Names are owned file names only.
struct PortalContentSetup: Equatable, Sendable {
    var complete = false
    var requiredMissing = 0, badDirectories = 0, archives = 0, missingArchives = 0, shortArchives = 0
    var missingBytes: Int64 = 0
    var available: Int64?, total: Int64?
    var names: [String] = []

    static let stopped = "Portal 2 has stopped. Close and reopen the app to play again."
    static let delivery = "On your Mac, in the portal2-avp folder, start tools/serve_owned_content.py, then relaunch this app with --import-content and the manifest address from its receipt (AVP-INSTALL.md, \u{201C}Headset content import\u{201D}). Files already here are verified and kept; only missing ones are copied. Keep the headset awake and allow Local Network access."

    init(_ report: P2ContentReport) {
        complete = report.complete != 0
        requiredMissing = Int(report.required_missing)
        badDirectories = Int(report.bad_directories)
        archives = Int(report.archives)
        missingArchives = Int(report.missing_archives)
        shortArchives = Int(report.short_archives)
        missingBytes = max(report.missing_bytes, 0)
        available = report.volume_available >= 0 ? report.volume_available : nil
        total = report.volume_total >= 0 ? report.volume_total : nil
        names = (0..<Int(max(report.names, 0))).map { index in
            withUnsafePointer(to: report) { String(cString: p2_content_report_name($0, Int32(index))) }
        }
    }

    // Off the main actor: reads the VPK directory trees and the volume's free
    // space. nil when the engine started (or already runs or returned).
    static func check(_ trigger: String, start: Bool) async -> PortalContentSetup? {
        await Task.detached(priority: .userInitiated) { () -> PortalContentSetup? in
            var report = P2ContentReport()
            if start {
                if p2_vision_game_start(trigger) == 0 { return nil }
                _ = p2_vision_content_last(&report)
            } else {
                _ = p2_vision_content_check(trigger, &report)
            }
            return PortalContentSetup(report)
        }.value
    }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private var nothingImported: Bool { requiredMissing >= 3 }
    var moreNames: Bool { requiredMissing + badDirectories + missingArchives + shortArchives > names.count }
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
    // e.g. "112 of 148 game archives are missing, about 3.4 GB."
    var detail: String {
        if complete { return "The files already on this Vision Pro are complete, so Portal 2 can start." }
        if nothingImported {
            return "Portal 2 runs from your own copy of the game: its content, the Linux depot files and the prepared images."
        }
        var parts: [String] = []
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
        var text = parts.joined(separator: "; ")
        if missingBytes > 0 { text += ", about \(Self.size(missingBytes))" }
        return text + "."
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

private struct PortalSetupPanel: View {
    let setup: PortalContentSetup
    let checking: Bool
    let importFailed: Bool
    let checkAgain: () -> Void
    let retryImport: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(setup.title).font(.title2.weight(.semibold))
                Text(setup.detail)
                if !setup.names.isEmpty {
                    Text("Missing or damaged: " + setup.names.joined(separator: ", ") + (setup.moreNames ? ", \u{2026}" : ""))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if !setup.space.isEmpty {
                    Text(setup.space).foregroundStyle(setup.spaceShort ? Color.orange : Color.secondary)
                }
                if !setup.complete {
                    Divider()
                    Text("Copy the game files from your Mac").font(.headline)
                    Text(PortalContentSetup.delivery).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(setup.complete ? "Start Portal 2" : "Check again", action: checkAgain)
                        .buttonStyle(.borderedProminent).disabled(checking)
                    if importFailed { Button("Retry import", action: retryImport).disabled(checking) }
                    if checking { ProgressView() }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(28)
        }
        .glassBackgroundEffect()
        .padding(20)
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
    func makeCoordinator() -> PortalGameSurfaceRenderer { PortalGameSurfaceRenderer(onAspect: onAspect) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.015, green: 0.02, blue: 0.03, alpha: 1)
        view.preferredFramesPerSecond = 60
        context.coordinator.configure(view)
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {}
}

private final class PortalGameSurfaceRenderer: NSObject, MTKViewDelegate {
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var reported = false
    private var aspect = 0.0
    private let onAspect: @MainActor @Sendable (Double) -> Void
    init(onAspect: @escaping @MainActor @Sendable (Double) -> Void) { self.onAspect = onAspect }
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
        guard PortalPresentation.shared.windowOwns, p2_vision_display_restoring() == 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue?.makeCommandBuffer() else { return }
        var frame = P2VisionGLFrame()
        let leased = PortalPresentation.shared.acquireWindow(&frame)
        if leased && frame.height > 0 {
            let eyes = frame.kind == P2_VISION_DIAGNOSTIC_STEREO.rawValue ? 2.0 : 1.0
            let next = Double(frame.width) * eyes / Double(frame.height)
            if abs(next - aspect) > 0.001 {
                aspect = next
                let onAspect = self.onAspect
                Task { @MainActor in onAspect(next) }
            }
        }
        var texture: MTLTexture?
        var rightTexture: MTLTexture?
        if leased, let pointer = frame.surface {
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                width: Int(frame.width), height: Int(frame.height), mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = view.device?.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            if frame.kind == P2_VISION_DIAGNOSTIC_STEREO.rawValue, let pointer = frame.right_surface {
                let right = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
                rightTexture = view.device?.makeTexture(descriptor: descriptor,iosurface: right,plane: 0)
            }
        }
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            if let texture, let pipeline {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentTexture(rightTexture ?? texture,index: 1)
                var paired: UInt32 = rightTexture == nil ? 0 : 1
                encoder.setFragmentBytes(&paired,length: MemoryLayout<UInt32>.size,index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                if !reported {
                    reported = true
                    NSLog("[vision-game] Actual engine texture submitted: sequence=%llu %ux%u", frame.sequence, frame.width, frame.height)
                    Task { @MainActor in
                        PortalController.reportControllers()
                        PortalGameFlow.shared.engineFrameSeen()
                    }
                }
            }
            encoder.endEncoding()
        }
        if leased {
            let slot = frame.slot
            command.addCompletedHandler { _ in p2_vision_gl_release(slot) }
        }
        command.present(drawable)
        command.commit()
    }
}
#endif
