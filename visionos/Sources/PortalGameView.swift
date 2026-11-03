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
    @State private var status = "Native engine. Expand to play around you in stereo."
    @State private var started = false
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
            }
            PortalGameSurface(onAspect: { aspect = $0 }).aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    if flow.phase == .opening {
                        ProgressView("Opening immersive view…").padding(24).glassBackgroundEffect()
                    }
                }
            Text(flow.message ?? status).font(.caption).foregroundStyle(.secondary)
            if importFailed {
                Button("Retry import") { Task { await prepareGame() } }
            }
            if importing {
                ProgressView(value: Double(importer.completedBytes), total: Double(max(importer.totalBytes,1)))
                Text(importer.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("Pause, or hold both stick buttons, to return to this window. L3 alone recenters.")
                .font(.caption).foregroundStyle(.secondary)
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
        }
        .onDisappear { flow.windowDisappeared(windowToken) }
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
