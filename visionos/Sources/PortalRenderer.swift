import ARKit
import CompositorServices
import Foundation
import Metal
import QuartzCore
import simd
import SwiftUI
#if P2_GAME
import IOSurface
#endif

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
    #if P2_GAME
    private let menuPipeline: MTLRenderPipelineState
    private var anchors: [UInt64: DeviceAnchor] = [:]
    private var reportedGame = false
    #endif

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
        #if P2_GAME
        let vertexName = "p2_game_vertex", fragmentName = "p2_world_fragment"
        #else
        let vertexName = "p2_calibration_vertex", fragmentName = "p2_calibration_fragment"
        #endif
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw NSError(domain: "Portal2XR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal resources unavailable"])
        }
        self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        #if P2_GAME
        descriptor.vertexFunction = library.makeFunction(name: "p2_menu_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "p2_menu_fragment")
        menuPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        #endif
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
        #if P2_GAME
        #if !targetEnvironment(simulator)
        if let anchor, tracked {
            anchors[sequence] = anchor
            anchors = anchors.filter { sequence - $0.key < 96 }
        }
        #endif
        #endif
        // Recording drawables cannot replace the built-in headset pose/input.
        if #available(visionOS 26.0, *) {
            if drawable.target == .builtIn { p2_xr_publish_frame(session, &xr) }
        } else { p2_xr_publish_frame(session, &xr) }
        #if P2_GAME
        encodeGame(drawable: drawable,command: command,tracked: tracked,currentAnchor: anchor)
        #else
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
        #endif
    }

    #if P2_GAME
    private func gameTexture(_ pointer: UnsafeMutableRawPointer?,frame: P2VisionGLFrame) -> MTLTexture? {
        guard let pointer else { return nil }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: Int(frame.width),height: Int(frame.height),mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return layer.device.makeTexture(descriptor: descriptor,iosurface: surface,plane: 0)
    }

    private func encodeGame(drawable: LayerRenderer.Drawable,command: MTLCommandBuffer,
                            tracked: Bool,currentAnchor: DeviceAnchor?) {
        var frame = P2VisionGLFrame()
        let leased = p2_vision_gl_acquire(&frame) != 0
        let stereo = leased && frame.kind == P2_VISION_TRACKED_STEREO.rawValue &&
            frame.eye_count == 2 && frame.xr_session == session && frame.render_pose.tracked != 0
        let sourceAnchor = stereo ? anchors[frame.render_pose.sequence] : nil
        let worldReady = tracked && stereo && sourceAnchor != nil
        let menuReady = tracked && leased && frame.kind == P2_VISION_MONO.rawValue
        // The anchor must be the pose that rendered these pixels. A newer
        // compositor pose must never be attached to a stale engine image.
        #if !targetEnvironment(simulator)
        if worldReady { drawable.deviceAnchor = sourceAnchor }
        else if menuReady { drawable.deviceAnchor = currentAnchor }
        #endif
        let left = leased ? gameTexture(frame.surface,frame: frame) : nil
        let right = stereo ? gameTexture(frame.right_surface,frame: frame) : nil
        for (eye,view) in drawable.views.enumerated() {
            let index = view.textureMap.textureIndex, slice = view.textureMap.sliceIndex
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.colorTextures[index]
            pass.colorAttachments[0].slice = slice
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.005,green: 0.007,blue: 0.01,alpha: 1)
            pass.depthAttachment.texture = drawable.depthTextures[index]
            pass.depthAttachment.slice = slice
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 0
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setViewport(view.textureMap.viewport)
            encoder.setDepthStencilState(depth)
            let texture = eye == 1 ? right : left
            if worldReady, let texture {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture,index: 0)
                let sourceProjection = eye == 1 ? frame.render_pose.eyes.1.projection : frame.render_pose.eyes.0.projection
                var crop = sourceProjection * simd_inverse(drawable.computeProjection(convention: .rightUpBack,viewIndex: eye))
                encoder.setFragmentBytes(&crop,length: MemoryLayout<simd_float4x4>.stride,index: 1)
                // Color-only world submission uses far depth. Positional
                // reprojection awaits actual engine depth export; fresh game
                // frames still render from both complete six-DoF eye poses.
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            } else if menuReady, let left {
                encoder.setRenderPipelineState(menuPipeline)
                encoder.setFragmentTexture(left,index: 0)
                var panel = matrix_identity_float4x4
                panel.columns.0.x = 0.8
                panel.columns.1.y = 0.8 * Float(frame.height) / Float(frame.width)
                panel.columns.3.z = -2
                var mvp = drawable.computeProjection(convention: .rightUpBack,viewIndex: eye) * simd_inverse(view.transform) * panel
                encoder.setVertexBytes(&mvp,length: MemoryLayout<simd_float4x4>.stride,index: 1)
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
            }
            encoder.endEncoding()
        }
        if leased {
            let slot = frame.slot
            command.addCompletedHandler { _ in p2_vision_gl_release(slot) }
        }
        if worldReady && !reportedGame {
            reportedGame = true
            let pose = frame.render_pose.sequence, image = frame.sequence
            command.addCompletedHandler { buffer in
                NSLog("[P2XR] Game stereo GPU submission completed: image=%llu pose=%llu eyes=2 status=%lu; physical acceptance pending",image,pose,buffer.status.rawValue)
            }
        }
    }
    #endif

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
