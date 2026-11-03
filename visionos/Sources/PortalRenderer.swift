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
    private let attempt: UInt64
    private let serial: UInt64
    // Every committed command buffer; the stop notification waits for all of
    // them so leases and drawables retire before another space may open.
    private let inFlight = DispatchGroup()
    @MainActor private static var serials: UInt64 = 0
    private var sequence: UInt64 = 0
    private var trackingTask: Task<Void, Never>?
    private var originFromScene: simd_float4x4?
    private var firstFrame = true
    private var spatial: (any PortalSpatialSource)?
    #if P2_GAME
    private let menuPipeline: MTLRenderPipelineState
    private let laserPipeline: MTLRenderPipelineState
    private let overlayDepth: MTLDepthStencilState
    private var anchors: [UInt64: DeviceAnchor] = [:]
    // originFromPanel of the menu panel shown now: placed when the menu first
    // appears, kept until a stereo world frame shows (the menu hid).
    private var menuPanel: simd_float4x4?
    private var eyeSizeRequested = false
    private var laserShown = false
    private var reportedGame = false
    private var frameLeases: [Int32] = []
    private var frameContent = 0  // built-in drawable: 1 tracked menu panel, 2 tracked stereo world
    private var pauseHeld = false
    #endif

    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }

    // `attempt` is the value the space was opened with (0: untagged). A layer
    // the game flow does not accept still presents (cleared frames) until the
    // space closes, but never owns engine frames, input or tracking.
    @MainActor static func start(layer: LayerRenderer, attempt: UInt64 = 0) {
        serials &+= 1
        let serial = serials
        #if P2_GAME
        let present = PortalGameFlow.shared.rendererArriving(attempt: attempt, serial: serial)
        #else
        let present = true
        #endif
        guard p2_xr_abi_version() == P2_XR_ABI_VERSION else {
            NSLog("[P2XR] Refusing mismatched native XR archive")
            postStopped(attempt: attempt, session: 0, serial: serial)
            return
        }
        do {
            let renderer = try PortalRenderer(layer: layer, attempt: attempt, serial: serial, present: present)
            #if P2_GAME
            if present { PortalGameFlow.shared.rendererPresenting(serial: serial, session: renderer.session) }
            #endif
            if present {
                renderer.trackingTask = Task {
                    do {
                        if WorldTrackingProvider.isSupported {
                            try await renderer.arSession.run([renderer.tracking])
                            renderer.spatial?.start()
                        }
                    } catch { NSLog("[P2XR] World tracking failed: %@", String(describing: error)) }
                }
            }
            Thread.detachNewThread { renderer.run() }
        } catch {
            NSLog("[P2XR] Renderer initialization failed: %@", String(describing: error))
            postStopped(attempt: attempt, session: 0, serial: serial)
        }
    }

    private static func postStopped(attempt: UInt64, session: UInt64, serial: UInt64) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .portalRendererStopped, object: nil,
                                            userInfo: ["attempt": attempt, "session": session, "renderer": serial])
        }
    }

    private init(layer: LayerRenderer, attempt: UInt64, serial: UInt64, present: Bool) throws {
        self.layer = layer
        self.attempt = attempt
        self.serial = serial
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
        // Aim laser: straight alpha over the game image.
        descriptor.vertexFunction = library.makeFunction(name: "p2_laser_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "p2_laser_fragment")
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.rgbBlendOperation = .add
        blend.alphaBlendOperation = .add
        blend.sourceRGBBlendFactor = .sourceAlpha
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        laserPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        #endif
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        depthDescriptor.depthCompareFunction = .greaterEqual
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw NSError(domain: "Portal2XR", code: 2)
        }
        self.depth = depth
        #if P2_GAME
        // Overlays on the depthless game image: always drawn, real depth kept
        // for the compositor.
        depthDescriptor.depthCompareFunction = .always
        guard let overlayDepth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw NSError(domain: "Portal2XR", code: 2)
        }
        self.overlayDepth = overlayDepth
        #endif
        let mesh = Self.calibrationMesh()
        vertexCount = mesh.count
        guard let buffer = mesh.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw NSError(domain: "Portal2XR", code: 3) }
        vertices = buffer
        session = present ? p2_xr_begin_session() : 0
        if #available(visionOS 26.0, *), present {
            spatial = PortalSenseTracking(session: arSession, world: tracking)
        }
    }

    private func run() {
        let session = self.session, attempt = self.attempt, serial = self.serial
        NSLog("[P2XR] Renderer %llu started: attempt=%llu session=%llu", serial, attempt, session)
        DispatchQueue.main.async {
            PortalController.attach(session: session, spatial: self.spatial)
        }
        while layer.state != .invalidated {
            if layer.state == .paused {
                invalidateTracking()
                layer.waitUntilRunning()
                continue
            }
            autoreleasepool { renderFrame() }
        }
        #if P2_GAME
        PortalPresentation.shared.revoke(session)
        #endif
        p2_xr_end_session(session)
        trackingTask?.cancel()
        arSession.stop()
        // Quarantine: report the stop only after the last command buffer (and
        // with it every engine lease and drawable) has completed.
        if inFlight.wait(timeout: .now() + 2) == .timedOut {
            NSLog("[P2XR] Renderer %llu waiting for its last command buffer", serial)
            inFlight.wait()
        }
        DispatchQueue.main.async {
            PortalController.stop(session: session)
            self.spatial?.stop()
        }
        Self.postStopped(attempt: attempt, session: session, serial: serial)
        NSLog("[P2XR] Session %llu stopped (renderer %llu, attempt %llu)", session, serial, attempt)
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
        let group = inFlight
        group.enter()
        #if P2_GAME
        notePause()
        let leases = frameLeases, content = frameContent, session = self.session, attempt = self.attempt
        frameLeases.removeAll(keepingCapacity: true)
        frameContent = 0
        command.addCompletedHandler { buffer in
            for slot in leases { p2_vision_gl_release(slot) }
            if content != 0, buffer.status == .completed,
               PortalPresentation.shared.completed(session, world: content == 2) {
                NSLog("[P2XR] First valid immersive frame completed: attempt=%llu session=%llu kind=%@",
                      attempt, session, content == 2 ? "stereo-world" : "menu-panel")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .portalRendererReady, object: nil,
                        userInfo: ["attempt": attempt, "session": session, "world": content == 2])
                }
            }
            group.leave()
        }
        #else
        command.addCompletedHandler { _ in group.leave() }
        #endif
        command.commit()
    }

    #if P2_GAME
    // Rising edge of the published pause action, for the pause -> window rule.
    private func notePause() {
        guard session != 0 else { return }
        var input = P2XRInput()
        let pressed = p2_xr_read(session, nil, &input) != 0 && input.buttons & UInt32(P2_XR_PAUSE.rawValue) != 0
        if pressed && !pauseHeld { PortalPresentation.shared.pausePressed(session) }
        pauseHeld = pressed
    }
    #endif

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
        let anchor = session == 0 ? nil : tracking.queryDeviceAnchor(atTimestamp: timestamp)
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
        var builtIn = true
        if #available(visionOS 26.0, *) { builtIn = drawable.target == .builtIn }
        if builtIn { p2_xr_publish_frame(session, &xr) }
        #if P2_GAME
        encodeGame(drawable: drawable,command: command,tracked: tracked,currentAnchor: anchor,builtIn: builtIn,
                   aim: xr.controllers.1)
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
                            tracked: Bool,currentAnchor: DeviceAnchor?,builtIn: Bool,aim: P2XRControllerPose) {
        if builtIn { requestEyeSize(drawable) }
        var frame = P2VisionGLFrame()
        // Only while this session owns presentation; otherwise a cleared frame.
        let leased = PortalPresentation.shared.acquireImmersive(session,&frame)
        let stereo = leased && frame.kind == P2_VISION_TRACKED_STEREO.rawValue &&
            frame.eye_count == 2 && frame.xr_session == session && frame.render_pose.tracked != 0
        let sourceAnchor = stereo ? anchors[frame.render_pose.sequence] : nil
        let worldReady = tracked && stereo && sourceAnchor != nil
        let menuReady = tracked && leased && frame.kind == P2_VISION_MONO.rawValue
        // The anchor must be the pose that rendered these pixels. A newer
        // compositor pose must never be attached to a stale engine image.
        // Overlays (menu panel, aim laser) are drawn from the attached pose.
        var renderHead: simd_float4x4?
        #if !targetEnvironment(simulator)
        if worldReady {
            drawable.deviceAnchor = sourceAnchor
            renderHead = sourceAnchor?.originFromAnchorTransform
        } else if menuReady {
            drawable.deviceAnchor = currentAnchor
            renderHead = currentAnchor?.originFromAnchorTransform
        }
        #endif
        if worldReady { menuPanel = nil }
        else if menuReady, menuPanel == nil, let head = renderHead {
            let panel = Self.panelPose(head: head, distance: 2)
            menuPanel = panel
            NSLog("[P2XR] Menu panel world-locked 2 m ahead at (%.2f, %.2f, %.2f) m, yaw only",
                  panel.columns.3.x, panel.columns.3.y, panel.columns.3.z)
        }
        let laser = worldReady && renderHead != nil ? laserSegment(aim) : nil
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
            let projection = drawable.computeProjection(convention: .rightUpBack,viewIndex: eye)
            if worldReady, let texture {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture,index: 0)
                let sourceProjection = eye == 1 ? frame.render_pose.eyes.1.projection : frame.render_pose.eyes.0.projection
                var crop = sourceProjection * simd_inverse(projection)
                encoder.setFragmentBytes(&crop,length: MemoryLayout<simd_float4x4>.stride,index: 1)
                // Color-only world submission uses far depth. Positional
                // reprojection awaits actual engine depth export; fresh game
                // frames still render from both complete six-DoF eye poses.
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
                if let laser, let head = renderHead {
                    var uniforms = LaserUniforms(projection: projection, eyeFromOrigin: simd_inverse(head * view.transform),
                                                 start: laser.start, end: laser.end)
                    encoder.setRenderPipelineState(laserPipeline)
                    encoder.setDepthStencilState(overlayDepth)
                    encoder.setVertexBytes(&uniforms,length: MemoryLayout<LaserUniforms>.stride,index: 1)
                    encoder.setFragmentBytes(&uniforms,length: MemoryLayout<LaserUniforms>.stride,index: 1)
                    encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 12)
                }
            } else if menuReady, let left, let panel = menuPanel, let head = renderHead {
                encoder.setRenderPipelineState(menuPipeline)
                encoder.setFragmentTexture(left,index: 0)
                // 1.6 m wide at 2 m (as before), at most 1.2 m tall.
                var halfWidth: Float = 0.8, halfHeight = 0.8 * Float(frame.height) / Float(max(frame.width, 1))
                if halfHeight > 0.6 { halfWidth *= 0.6 / halfHeight; halfHeight = 0.6 }
                var size = matrix_identity_float4x4
                size.columns.0.x = halfWidth
                size.columns.1.y = halfHeight
                var mvp = projection * simd_inverse(head * view.transform) * panel * size
                encoder.setVertexBytes(&mvp,length: MemoryLayout<simd_float4x4>.stride,index: 1)
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
            }
            encoder.endEncoding()
        }
        // Released by renderFrame's completion handler, after the GPU is done.
        if leased { frameLeases.append(frame.slot) }
        if builtIn { frameContent = worldReady ? 2 : menuReady ? 1 : 0 }
        if worldReady && !reportedGame {
            reportedGame = true
            let pose = frame.render_pose.sequence, image = frame.sequence
            command.addCompletedHandler { buffer in
                NSLog("[P2XR] Game stereo GPU submission completed: image=%llu pose=%llu eyes=2 status=%lu; physical acceptance pending",image,pose,buffer.status.rawValue)
            }
        }
    }

    // Yaw-only pose `distance` meters ahead of the head at head height, its +Z
    // facing the head. Uses the head's up vector so it stays defined while
    // looking straight up or down.
    private static func panelPose(head: simd_float4x4, distance: Float) -> simd_float4x4 {
        let look = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let up = SIMD3<Float>(head.columns.1.x, head.columns.1.y, head.columns.1.z)
        var forward = look - up * look.y
        forward.y = 0
        forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        let position = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z) + forward * distance
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
    }

    // Matches LaserUniforms in GameTexture.metal (192 bytes).
    private struct LaserUniforms {
        var projection: simd_float4x4
        var eyeFromOrigin: simd_float4x4
        var start: SIMD4<Float>
        var end: SIMD4<Float>
        var color = SIMD4<Float>(0.55, 0.85, 1.0, 0.45)
        var halfWidth: Float = 0.0012
        var dotRadius: Float = 0.012
        var padding = SIMD2<Float>(0, 0)
    }

    // 3 m aim laser from the right Sense controller's aim pose (ARKit origin
    // space), starting 3 cm ahead of it; nil while controller aim is off.
    private func laserSegment(_ aim: P2XRControllerPose) -> (start: SIMD4<Float>, end: SIMD4<Float>)? {
        guard aim.tracked != 0 else { return nil }
        // Engine-side Sense portal aim (aim_vision.c). The weak -1 fallback in
        // game_vision.m only answers in builds without aim_vision.c.
        let engine = p2_vision_controller_aim_active()
        let active: Bool
        if engine >= 0 { active = engine != 0 }
        else {
            // Fallback: the Sense pair owns the published input; the right
            // controller's tracking is checked by the guard above.
            var input = P2XRInput()
            active = p2_xr_read(session, nil, &input) != 0 && input.connected != 0 && input.spatial != 0
        }
        guard active else { return nil }
        let pose = aim.tracking_from_aim
        let axis = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        guard simd_length(axis) > 0.5 else { return nil }
        let forward = simd_normalize(axis), origin = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        if !laserShown {
            laserShown = true
            NSLog("[P2XR] Aim laser shown from the right Sense controller (gate: %@)",
                  engine >= 0 ? "engine controller aim" : "Sense pair owns input; engine aim query not linked")
        }
        return (SIMD4(origin + forward * 0.03, 1), SIMD4(origin + forward * 3, 1))
    }

    // Near-square per-eye engine size: the symmetric cover of the compositor
    // eye views (the frustum view_vision.c renders) at about the compositor's
    // pixel density, within P2_XR_EYE_PIXELS (default 1440x1440) and 640...2048
    // per side, in multiples of 8. P2_XR_EYE_RESIZE=0 keeps the windowed size.
    // Requested once per renderer; applied only while it owns engine frames.
    private func requestEyeSize(_ drawable: LayerRenderer.Drawable) {
        guard !eyeSizeRequested, session != 0, drawable.views.count == 2 else { return }
        eyeSizeRequested = true
        let environment = ProcessInfo.processInfo.environment
        if environment["P2_XR_EYE_RESIZE"] == "0" {
            NSLog("[P2XR] Eye render size: disabled by P2_XR_EYE_RESIZE=0; the engine keeps its windowed size")
            return
        }
        var budget = 1440.0 * 1440.0
        if let text = environment["P2_XR_EYE_PIXELS"] {
            if let value = Double(text), value >= 640 * 640, value <= 2048 * 2048 { budget = value }
            else { NSLog("[P2XR] P2_XR_EYE_PIXELS=%@ rejected (409600...4194304); using %.0f", text, budget) }
        }
        var halfX = 0.0, halfY = 0.0, density = 0.0
        var viewports: [String] = []
        for (index, view) in drawable.views.enumerated() {
            let p = drawable.computeProjection(convention: .rightUpBack, viewIndex: index)
            let sx = Double(p.columns.0.x), sy = Double(p.columns.1.y), viewport = view.textureMap.viewport
            guard sx > 0, sy > 0, viewport.width > 0, viewport.height > 0 else {
                NSLog("[P2XR] Eye render size: unusable view %ld; the engine keeps its windowed size", index)
                return
            }
            // Cover tangents as p2_xr_cover_projection; compositor pixels per tangent unit.
            halfX = max(halfX, (1 + abs(Double(p.columns.2.x))) / sx)
            halfY = max(halfY, (1 + abs(Double(p.columns.2.y))) / sy)
            density = max(density, viewport.width * sx / 2, viewport.height * sy / 2)
            viewports.append("\(Int(viewport.width))x\(Int(viewport.height))")
        }
        let aspect = halfX / halfY
        guard aspect.isFinite, aspect > 0.5, aspect < 2, density.isFinite, density > 0 else {
            NSLog("[P2XR] Eye render size: implausible eye frustum (aspect %.3f); the engine keeps its windowed size", aspect)
            return
        }
        let fullHeight = 2 * halfY * density
        var height = min(max(min(fullHeight, (budget / aspect).squareRoot()), 640), 2048)
        var width = height * aspect
        if width > 2048 { width = 2048; height = width / aspect }
        if width < 640 { width = 640; height = width / aspect }
        func pixels(_ value: Double) -> Int32 { Int32(min(max((value / 8).rounded() * 8, 640), 2048)) }
        let w = pixels(width), h = pixels(height)
        let granted = PortalPresentation.shared.requestEyeSize(session, width: w, height: h)
        NSLog("[P2XR] Eye render size: compositor views %@, cover tangents x %.3f y %.3f (aspect %.3f), full density %.0fx%.0f -> engine %dx%d per eye (budget %.2f MP)%@",
              viewports.joined(separator: " "), halfX, halfY, aspect, fullHeight * aspect, fullHeight, w, h, budget / 1e6,
              granted ? "" : "; not requested, this renderer does not own engine frames")
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
