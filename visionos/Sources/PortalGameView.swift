#if P2_GAME
import IOSurface
import ARKit
import GameController
import MetalKit
import SwiftUI

struct PortalGameView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var opening = false
    @State private var status = "Native engine test. Immersive stereo integration is still in progress."
    @State private var started = false
    @State private var controlsSession: UInt64 = 0
    @State private var spatial: (any PortalSpatialSource)?
    @State private var aspect = 16.0 / 9.0
    @StateObject private var importer = PortalContentImporter()
    @State private var importing = false
    @State private var importFailed = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Portal 2 — engine test").font(.headline)
                Spacer()
                Button("Run engine test") { start() }.disabled(started || importing || importFailed)
                if ProcessInfo.processInfo.arguments.contains("--immersive-test") {
                    Button("Enter immersive") { Task { await enterImmersive() } }.disabled(!started || opening)
                }
            }
            PortalGameSurface(onAspect: { aspect = $0 }).aspectRatio(aspect, contentMode: .fit)
            Text(status).font(.caption).foregroundStyle(.secondary)
            if importFailed {
                Button("Retry import") { Task { await prepareGame() } }
            }
            if importing {
                ProgressView(value: Double(importer.completedBytes), total: Double(max(importer.totalBytes,1)))
                Text(importer.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("Hold both stick buttons to return to the window. L3 alone recenters.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            let dismiss = dismissSpace, open = openWindow
            PortalGameFlow.shared.configure {
                await dismiss()
                open(id: "game-window")
            }
            prepareControls()
            await prepareGame()
        }
        .onChange(of: phase) { _, value in
            PortalController.suspend(session: controlsSession,value != .active)
        }
        .onDisappear {
            PortalController.stop(session: controlsSession)
            spatial?.stop()
            p2_xr_end_session(controlsSession)
        }
    }
    @MainActor private func prepareGame() async {
        guard !importing else { return }
        importFailed = false
        if p2_vision_game_state() == 0 || p2_vision_game_state() == -1 {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--import-content"), index+1 < arguments.count,
               let url = URL(string: arguments[index+1]) {
                importing = true
                status = "Importing your Portal 2 files from your Mac."
                do {
                    let documents = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
                    try await importer.run(manifestURL: url,documents: documents)
                    importing = false
                    status = "Game files imported."
                } catch {
                    let error = error as NSError
                    let reason = error.userInfo[NSURLErrorNetworkUnavailableReasonKey] as? NSNumber
                    fputs("[vision-import] Failed: domain=\(error.domain) code=\(error.code) network_reason=\(reason?.intValue ?? -1)\n",stderr)
                    importing = false
                    importFailed = true
                    status = "Import stopped. Check Local Network access and your Mac connection, then retry."
                    return
                }
            }
        }
        if p2_vision_game_state() == 1 { started = true; status = "The native engine is running." }
        else if ProcessInfo.processInfo.arguments.contains("--engine-test") { start() }
    }
    @MainActor private func enterImmersive() async {
        opening = true
        defer { opening = false }
        switch await openSpace(id: "game-world") {
        case .opened:
            PortalGameFlow.shared.immersive = true
            dismissWindow(id: "game-window")
        case .userCancelled: status = "Opening immersive play was cancelled."
        case .error: status = "The immersive space could not open."
        @unknown default: status = "The system returned an unknown result."
        }
    }
    @MainActor private func prepareControls() {
        guard controlsSession == 0 else { return }
        guard p2_xr_abi_version() == P2_XR_ABI_VERSION else {
            status = "The native input library needs rebuilding."
            return
        }
        controlsSession = p2_xr_begin_window_session()
        if #available(visionOS 26.0, *) {
            let source = PortalSenseTracking(session: ARKitSession(),world: WorldTrackingProvider(),trackPoses: false)
            spatial = source
            source.start()
        }
        PortalController.attach(session: controlsSession,spatial: spatial)
    }
    private func start() {
        guard p2_xr_abi_version() == P2_XR_ABI_VERSION else {
            status = "The native input library needs rebuilding."
            return
        }
        if p2_vision_game_start() < 0 {
            status = "Game files are missing. Install your Portal 2 content and prepared Linux files first."
        } else {
            started = true
            if ProcessInfo.processInfo.environment["P2_VISION_STEREO_AUDIT"] == "1" {
                status = "Stereo renderer audit: fixed eye separation, no tracked headset pose."
            } else {
                status = "Starting the recompiled game. This window tests the engine; it is not immersive stereo."
            }
        }
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
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue?.makeCommandBuffer() else { return }
        var frame = P2VisionGLFrame()
        let leased = p2_vision_gl_acquire(&frame) != 0
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
                    Task { @MainActor in PortalController.reportControllers() }
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
