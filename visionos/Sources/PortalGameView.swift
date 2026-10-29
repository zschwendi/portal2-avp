#if P2_GAME
import IOSurface
import ARKit
import GameController
import MetalKit
import SwiftUI

struct PortalGameView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = "Native engine test. Immersive stereo integration is still in progress."
    @State private var started = false
    @State private var controlsSession: UInt64 = 0
    @State private var spatial: (any PortalSpatialSource)?
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Portal 2 — engine test").font(.headline)
                Spacer()
                Button("Run engine test") { start() }.disabled(started)
            }
            PortalGameSurface().aspectRatio(16 / 9, contentMode: .fit)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            prepareControls()
            if ProcessInfo.processInfo.arguments.contains("--engine-test") { start() }
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
    @MainActor private func prepareControls() {
        guard controlsSession == 0 else { return }
        controlsSession = p2_xr_begin_window_session()
        if #available(visionOS 26.0, *) {
            let source = PortalSenseTracking(session: ARKitSession(),world: WorldTrackingProvider(),trackPoses: false)
            spatial = source
            source.start()
        }
        PortalController.attach(session: controlsSession,spatial: spatial)
    }
    private func start() {
        if p2_vision_game_start() < 0 {
            status = "Game files are missing. Install your Portal 2 content and prepared Linux files first."
        } else {
            started = true
            status = "Starting the recompiled game. This window tests the engine; it is not immersive stereo."
        }
    }
}

private struct PortalGameSurface: UIViewRepresentable {
    func makeCoordinator() -> PortalGameSurfaceRenderer { PortalGameSurfaceRenderer() }
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
    @MainActor func configure(_ view: MTKView) {
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
        var texture: MTLTexture?
        if leased, let pointer = frame.surface {
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                width: Int(frame.width), height: Int(frame.height), mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = view.device?.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        }
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            if let texture, let pipeline {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                if !reported {
                    reported = true
                    NSLog("[vision-game] Actual engine texture submitted: sequence=%llu %ux%u", frame.sequence, frame.width, frame.height)
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
