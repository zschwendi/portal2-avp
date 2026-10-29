import ARKit
import CompositorServices
import Foundation
import Metal
import QuartzCore
import simd
import SwiftUI

struct PortalLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        configuration.defaultDepthRange = SIMD2(100, max(0.05, capabilities.supportedMinimumNearPlaneDistance))
        // Start with separate textures and no foveation. A future game bridge
        // must explicitly support array slices/rate maps before enabling them.
        configuration.isFoveationEnabled = false
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .layered
    }
}

final class PortalRenderer: @unchecked Sendable {
    private let layer: LayerRenderer
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let vertexCount: Int
    private let arSession = ARKitSession()
    private let tracking = WorldTrackingProvider()
    private let session: UInt64
    private var sequence: UInt64 = 0
    private var trackingTask: Task<Void, Never>?
    private var originFromScene: simd_float4x4?
    private var firstFrame = true
    private var spatial: (any PortalSpatialSource)?

    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }

    static func start(layer: LayerRenderer) {
        guard p2_xr_abi_version() == P2_XR_ABI_VERSION else {
            NSLog("[P2XR] Refusing mismatched native XR archive")
            NotificationCenter.default.post(name: .portalRendererStopped, object: nil)
            return
        }
        do {
            let renderer = try PortalRenderer(layer: layer)
            renderer.trackingTask = Task {
                do {
                    if WorldTrackingProvider.isSupported {
                        try await renderer.arSession.run([renderer.tracking])
                        await renderer.spatial?.start()
                    }
                } catch { NSLog("[P2XR] World tracking failed: %@", String(describing: error)) }
            }
            Thread.detachNewThread { renderer.run() }
        } catch {
            NSLog("[P2XR] Renderer initialization failed: %@", String(describing: error))
            NotificationCenter.default.post(name: .portalRendererStopped, object: nil)
        }
    }

    private init(layer: LayerRenderer) throws {
        self.layer = layer
        let device = layer.device
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "p2_calibration_vertex"),
              let fragment = library.makeFunction(name: "p2_calibration_fragment") else {
            throw NSError(domain: "Portal2XR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal resources unavailable"])
        }
        self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        depthDescriptor.depthCompareFunction = .greaterEqual
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw NSError(domain: "Portal2XR", code: 2)
        }
        self.depth = depth
        let mesh = Self.calibrationMesh()
        vertexCount = mesh.count
        guard let buffer = mesh.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw NSError(domain: "Portal2XR", code: 3) }
        vertices = buffer
        session = p2_xr_begin_session()
        if #available(visionOS 26.0, *) {
            spatial = PortalSenseTracking(session: arSession, world: tracking)
        }
    }

    private func run() {
        let session = self.session
        DispatchQueue.main.async {
            PortalController.attach(session: session, spatial: self.spatial)
        }
        defer {
            p2_xr_end_session(session)
            trackingTask?.cancel()
            arSession.stop()
            DispatchQueue.main.async {
                PortalController.stop(session: session)
                self.spatial?.stop()
                NotificationCenter.default.post(name: .portalRendererStopped, object: nil)
            }
            NSLog("[P2XR] Session %llu stopped", session)
        }
        while layer.state != .invalidated {
            if layer.state == .paused {
                invalidateTracking()
                layer.waitUntilRunning()
                continue
            }
            autoreleasepool { renderFrame() }
        }
    }

    private func invalidateTracking() {
        var invalid = P2XRFrame()
        p2_xr_publish_frame(session, &invalid)
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate(); frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        guard let command = queue.makeCommandBuffer() else { return }
        frame.startSubmission()
        let drawables: [LayerRenderer.Drawable]
        if #available(visionOS 26.0, *) { drawables = frame.queryDrawables() }
        else { drawables = frame.queryDrawable().map { [$0] } ?? [] }
        // An empty query cancels/invalidates the frame; do not access it again.
        guard !drawables.isEmpty else { invalidateTracking(); return }
        defer { frame.endSubmission() }
        for drawable in drawables {
            encode(drawable: drawable, command: command)
            drawable.encodePresent(commandBuffer: command)
        }
        command.commit()
    }

    private func encode(drawable: LayerRenderer.Drawable, command: MTLCommandBuffer) {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime)
        let timestamp = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        #if targetEnvironment(simulator)
        // Only this explicitly named renderer check permits a synthetic pose.
        // It is never marked tracked or delivered to game input.
        let anchor: DeviceAnchor? = nil
        let tracked = false
        var head = matrix_identity_float4x4
        head.columns.3.y = 1.6
        #else
        let anchor = tracking.queryDeviceAnchor(atTimestamp: timestamp)
        let tracked = anchor?.isTracked == true
        let head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        #endif
        #if !targetEnvironment(simulator)
        if tracked { drawable.deviceAnchor = anchor }
        #endif
        sequence += 1
        var xr = P2XRFrame()
        xr.sequence = sequence
        xr.presentation_time = timestamp
        xr.tracked = tracked ? 1 : 0
        xr.eye_count = UInt32(drawable.views.count)
        xr.tracking_from_head = head
        spatial?.writePoses(at: timestamp, into: &xr)
        if drawable.views.count == 2 {
            xr.eyes.0.head_from_eye = drawable.views[0].transform
            xr.eyes.1.head_from_eye = drawable.views[1].transform
            xr.eyes.0.projection = drawable.computeProjection(convention: .rightUpBack, viewIndex: 0)
            xr.eyes.1.projection = drawable.computeProjection(convention: .rightUpBack, viewIndex: 1)
        }
        // Recording drawables cannot replace the built-in headset pose/input.
        if #available(visionOS 26.0, *) {
            if drawable.target == .builtIn { p2_xr_publish_frame(session, &xr) }
        } else { p2_xr_publish_frame(session, &xr) }
        if originFromScene == nil {
            var origin = matrix_identity_float4x4
            origin.columns.3 = SIMD4(head.columns.3.x, head.columns.3.y - 1.6, head.columns.3.z, 1)
            originFromScene = origin
        }
        var drawCalibration = tracked
        #if targetEnvironment(simulator)
        drawCalibration = true
        #endif
        for (eye, view) in drawable.views.enumerated() {
            let index = view.textureMap.textureIndex
            let slice = view.textureMap.sliceIndex
            let color = drawable.colorTextures[index]
            let depthTexture = drawable.depthTextures[index]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].slice = slice
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.015, green: 0.02, blue: 0.03, alpha: 1)
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.slice = slice
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 0
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setViewport(view.textureMap.viewport)
            if drawCalibration {
                var mvp = drawable.computeProjection(convention: .rightUpBack, viewIndex: eye) *
                    simd_inverse(head * view.transform) * (originFromScene ?? matrix_identity_float4x4)
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depth)
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            }
            encoder.endEncoding()
        }
        if firstFrame {
            firstFrame = false
            let eyeCount = drawable.views.count
            #if targetEnvironment(simulator)
            let simulated = true
            #else
            let simulated = false
            #endif
            if let view = drawable.views.first {
                NSLog("[P2XR] First view: head=%@ eye=%@ projection=%@ depth=%@", String(describing: head),
                      String(describing: view.transform),
                      String(describing: drawable.computeProjection(convention: .rightUpBack, viewIndex: 0)),
                      String(describing: drawable.depthRange))
            }
            command.addCompletedHandler { buffer in
                NSLog("[P2XR] Renderer check GPU completed: status=%lu tracked=%d eyes=%lu simulated=%d; game_attached=0",
                      buffer.status.rawValue, tracked ? 1 : 0, eyeCount, simulated ? 1 : 0)
            }
        }
    }

    private static func calibrationMesh() -> [Vertex] {
        var mesh: [Vertex] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ color: SIMD4<Float>) {
            for point in [a, b, c, a, c, d] { mesh.append(Vertex(position: point, color: color)) }
        }
        let floor = SIMD4<Float>(0.05, 0.065, 0.08, 1)
        quad([-3, 0, -4], [3, 0, -4], [3, 0, 2], [-3, 0, 2], floor)
        let line = SIMD4<Float>(0.15, 0.2, 0.25, 1)
        for step in -6...6 {
            let x = Float(step) * 0.5
            quad([x-0.004, 0.002, -4], [x+0.004, 0.002, -4], [x+0.004, 0.002, 2], [x-0.004, 0.002, 2], line)
            let z = x - 1
            quad([-3, 0.002, z-0.004], [3, 0.002, z-0.004], [3, 0.002, z+0.004], [-3, 0.002, z+0.004], line)
        }
        for (x, color) in [(Float(-0.6), SIMD4<Float>(0.04, 0.35, 0.9, 1)),
                           (Float(0.6), SIMD4<Float>(0.9, 0.3, 0.04, 1))] {
            let a: SIMD3<Float> = [x-0.15, 1.05, -1.65]
            let b: SIMD3<Float> = [x+0.15, 1.35, -1.35]
            quad([a.x,a.y,b.z], [b.x,a.y,b.z], [b.x,b.y,b.z], [a.x,b.y,b.z], color)
            quad([b.x,a.y,a.z], [a.x,a.y,a.z], [a.x,b.y,a.z], [b.x,b.y,a.z], color * SIMD4(0.6,0.6,0.6,1))
            quad([a.x,a.y,a.z], [a.x,a.y,b.z], [a.x,b.y,b.z], [a.x,b.y,a.z], color * SIMD4(0.8,0.8,0.8,1))
            quad([b.x,a.y,b.z], [b.x,a.y,a.z], [b.x,b.y,a.z], [b.x,b.y,b.z], color * SIMD4(0.7,0.7,0.7,1))
            quad([a.x,b.y,b.z], [b.x,b.y,b.z], [b.x,b.y,a.z], [a.x,b.y,a.z], color)
        }
        return mesh
    }
}
