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
        // Default: separate textures, no foveation (the drawables were
        // 1888x1792 per eye on device). Opt-in foveation is accepted only with
        // the dedicated layout, where every view has its own texture and rate
        // map (PortalRenderer.rateMap); anything else keeps the default.
        let foveation = PortalRenderQuality.requested
        if foveation.enabled, capabilities.supportsFoveation,
           capabilities.supportedLayouts(options: .foveationEnabled).contains(.dedicated) {
            configuration.isFoveationEnabled = true
            configuration.layout = .dedicated
            if #available(visionOS 26.0, *), let quality = foveation.quality {
                configuration.maxRenderQuality = LayerRenderer.RenderQuality(quality)
            }
            return
        }
        configuration.isFoveationEnabled = false
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .layered
    }
}

// Opt-in immersive render resolution (environment, read once):
//   P2_XR_FOVEATION=1          foveated dedicated drawables
//   P2_XR_RENDER_QUALITY=0...1 also raises CompositorServices render quality
//                              (implies foveation; visionOS 26+)
// Unsupported devices, the simulator and the layered layout keep the
// unfoveated default. No performance claim: measure with
// P2_VISION_FRAME_AUDIT=1 before making anything a default.
enum PortalRenderQuality {
    static let requested: (enabled: Bool, quality: Float?) = {
        let environment = ProcessInfo.processInfo.environment
        var quality: Float?
        if let text = environment["P2_XR_RENDER_QUALITY"] {
            if let value = Float(text), value >= 0, value <= 1 { quality = value }
            else { NSLog("[P2XR] P2_XR_RENDER_QUALITY=%@ rejected (0...1)", text) }
        }
        return (environment["P2_XR_FOVEATION"] == "1" || quality != nil, quality)
    }()
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
    private let reticlePipeline: MTLRenderPipelineState
    private let overlayDepth: MTLDepthStencilState
    private static let menuDistance: Float = 2
    private var anchors: [UInt64: DeviceAnchor] = [:]
    // originFromPanel of the menu panel shown now: placed when the menu first
    // appears, kept until a stereo world frame shows (the menu hid).
    private var menuPanel: simd_float4x4?
    private var eyeSizeRequested = false
    private var reportedGame = false
    private var frameLeases: [Int32] = []
    private var cadenceStart: Double?
    private var cadenceSubmissions = 0
    private var cadenceImages = 0
    private var cadenceReports = 0
    private var lastImageSequence: UInt64?
    private let auditCadence = ProcessInfo.processInfo.environment["P2_VISION_FRAME_AUDIT"] == "1"
    private enum FrameContent: String { case menu = "menu-panel", world = "stereo-world", simulator = "simulator-panel" }
    private var frameContent: FrameContent?
    #if targetEnvironment(simulator)
    private let simulatorPreview = ProcessInfo.processInfo.arguments.contains("--immersive-test")
    #endif
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
        let vertexName = "p2_world_vertex", fragmentName = "p2_world_fragment"
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
        descriptor.vertexFunction = library.makeFunction(name: "p2_reticle_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "p2_reticle_fragment")
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.sourceRGBBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        reticlePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        #endif
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        depthDescriptor.depthCompareFunction = .greaterEqual
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw NSError(domain: "Portal2XR", code: 2)
        }
        self.depth = depth
        #if P2_GAME
        // The opaque menu scene uses one depth plane. Compositor reprojection
        // would otherwise stretch the edge across the jump to the empty room.
        depthDescriptor.isDepthWriteEnabled = false
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
        let configuration = layer.configuration
        let foveated = configuration.isFoveationEnabled && configuration.layout == .dedicated
        if #available(visionOS 26.0, *), foveated, let quality = PortalRenderQuality.requested.quality {
            layer.renderQuality = LayerRenderer.RenderQuality(quality)
        }
        NSLog("[P2XR] Layer: layout=%@ foveation=%d requested=%d quality=%@", String(describing: configuration.layout),
              foveated ? 1 : 0, PortalRenderQuality.requested.enabled ? 1 : 0,
              PortalRenderQuality.requested.quality.map { String($0) } ?? "default")
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

    // Foveated (dedicated) drawables carry one rasterization rate map per
    // texture; every pass into that texture, including a clear, uses it.
    // False only when foveation is on and the map is missing.
    private var reportedMissingRateMap = false
    private func applyRateMap(_ pass: MTLRenderPassDescriptor, drawable: LayerRenderer.Drawable, index: Int) -> Bool {
        guard layer.configuration.isFoveationEnabled else { return true }
        let maps = drawable.rasterizationRateMaps
        if layer.configuration.layout == .dedicated, maps.indices.contains(index) {
            pass.rasterizationRateMap = maps[index]
            return true
        }
        if !reportedMissingRateMap {
            reportedMissingRateMap = true
            NSLog("[P2XR] Foveated drawable without a rate map for texture %ld (%ld maps, layout %@); clearing only",
                  index, maps.count, String(describing: layer.configuration.layout))
        }
        return false
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
        frameContent = nil
        command.addCompletedHandler { buffer in
            for slot in leases { p2_vision_gl_release(slot) }
            if let content, buffer.status == .completed,
               PortalPresentation.shared.completed(session, world: content == .world) {
                NSLog("[P2XR] First valid immersive frame completed: attempt=%llu session=%llu kind=%@",
                      attempt, session, content.rawValue)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .portalRendererReady, object: nil,
                        userInfo: ["attempt": attempt, "session": session, "kind": content.rawValue])
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

    private func secondsSinceEpoch(_ time: LayerRenderer.Clock.Instant) -> Double {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: time).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func encode(drawable: LayerRenderer.Drawable, command: MTLCommandBuffer) {
        let timestamp = secondsSinceEpoch(drawable.frameTiming.presentationTime)
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
        // The compositor predicts tracked accessories on their own per-frame clock.
        spatial?.writePoses(at: secondsSinceEpoch(drawable.frameTiming.trackableAnchorTime), into: &xr)
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
                   timestamp: timestamp)
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
            let mapped = applyRateMap(pass, drawable: drawable, index: index)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setViewport(view.textureMap.viewport)
            if drawCalibration && mapped {
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
                            tracked: Bool,currentAnchor: DeviceAnchor?,builtIn: Bool,
                            timestamp: Double) {
        #if targetEnvironment(simulator)
        let preview = simulatorPreview
        #else
        let preview = false
        if builtIn { requestEyeSize(drawable) }
        #endif
        var frame = P2VisionGLFrame()
        // Only while this session owns presentation; otherwise a cleared frame.
        let leased = PortalPresentation.shared.acquireImmersive(session,&frame)
        let stereo = leased && frame.kind == P2_VISION_TRACKED_STEREO.rawValue &&
            frame.eye_count == 2 && frame.xr_session == session && frame.render_pose.tracked != 0
        let sourceAnchor = stereo ? anchors[frame.render_pose.sequence] : nil
        let worldReady = tracked && stereo && sourceAnchor != nil
        let panelReady = (tracked || preview) && leased && PortalPresentation.usableMonoFrame(frame)
        // The anchor must be the pose that rendered these pixels. A newer
        // compositor pose must never be attached to a stale engine image.
        // Menu panels use the current tracking pose.
        var renderHead: simd_float4x4?
        #if targetEnvironment(simulator)
        // Draw the actual game surface in a fixed panel for lifecycle testing.
        // This synthetic pose stays local to the panel and never enters XR.
        if panelReady { renderHead = matrix_identity_float4x4 }
        #else
        if worldReady {
            drawable.deviceAnchor = sourceAnchor
        } else if panelReady {
            drawable.deviceAnchor = currentAnchor
            renderHead = currentAnchor?.originFromAnchorTransform
        }
        #endif
        if worldReady { menuPanel = nil }
        else if panelReady, menuPanel == nil, let head = renderHead {
            let panel = Self.panelPose(head: head, distance: Self.menuDistance)
            menuPanel = panel
            NSLog("[P2XR] %@ panel placed 2 m ahead at (%.2f, %.2f, %.2f) m, yaw only",
                  preview ? "Simulator" : "Tracked menu", panel.columns.3.x, panel.columns.3.y, panel.columns.3.z)
        }
        let left = leased ? gameTexture(frame.surface,frame: frame) : nil
        let right = stereo ? gameTexture(frame.right_surface,frame: frame) : nil
        var eyesDrawn = 0
        for (eye,view) in drawable.views.enumerated() {
            let index = view.textureMap.textureIndex, slice = view.textureMap.sliceIndex
            let projection = drawable.computeProjection(convention: .rightUpBack,viewIndex: eye)
            let range = drawable.depthRange
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
            if panelReady {
                // Preserve the original spatial panel projection in color,
                // with a continuous depth surface across the dark backdrop.
                let distance = min(max(Self.menuDistance, range.y), range.x)
                let clip = projection * SIMD4<Float>(0, 0, -distance, 1)
                pass.depthAttachment.clearDepth = Double(clip.z / clip.w)
            }
            // Without its rate map a foveated texture is only cleared: drawing
            // in physical coordinates would misplace the image.
            guard applyRateMap(pass, drawable: drawable, index: index),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                if let encoder = command.makeRenderCommandEncoder(descriptor: pass) { encoder.endEncoding() }
                continue
            }
            encoder.setViewport(view.textureMap.viewport)
            encoder.setDepthStencilState(depth)
            let texture = eye == 1 ? right : left
            if worldReady, let texture {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture,index: 0)
                var sourceProjection = eye == 1 ? frame.render_pose.eyes.1.projection : frame.render_pose.eyes.0.projection
                if eye == 0 && frame.flip_left_y != 0 {
                    // Reflect in source clip space after unprojecting the drawable's eye ray.
                    sourceProjection = simd_float4x4(diagonal: SIMD4<Float>(1, -1, 1, 1)) * sourceProjection
                }
                var crop = sourceProjection * simd_inverse(projection)
                encoder.setFragmentBytes(&crop,length: MemoryLayout<simd_float4x4>.stride,index: 1)
                // Use a finite background depth for compositor reprojection
                // until the engine exports depth per pixel.
                let distance = min(20, range.y + (range.x - range.y) * 0.5)
                let projected = projection * SIMD4<Float>(0, 0, -distance, 1)
                var backgroundDepth = projected.z / projected.w
                encoder.setVertexBytes(&backgroundDepth, length: MemoryLayout<Float>.size, index: 1)
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
                if frame.reticle.w == 1, let sourceAnchor {
                    let eyeFromTracking = simd_inverse(sourceAnchor.originFromAnchorTransform * view.transform)
                    encodeReticle(encoder, projection: projection, eyePoint: eyeFromTracking * frame.reticle)
                }
                eyesDrawn += 1
            } else if panelReady, let left, let panel = menuPanel, let head = renderHead {
                encoder.setRenderPipelineState(menuPipeline)
                encoder.setDepthStencilState(overlayDepth)
                encoder.setFragmentTexture(left,index: 0)
                let half = Self.panelHalfSize(width: frame.width, height: frame.height)
                let halfWidth = half.x, halfHeight = half.y
                var size = matrix_identity_float4x4
                size.columns.0.x = halfWidth
                size.columns.1.y = halfHeight
                var mvp = projection * simd_inverse(head * view.transform) * panel * size
                encoder.setVertexBytes(&mvp,length: MemoryLayout<simd_float4x4>.stride,index: 1)
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
                eyesDrawn += 1
            }
            encoder.endEncoding()
        }
        // Released by renderFrame's completion handler, after the GPU is done.
        if leased { frameLeases.append(frame.slot) }
        if builtIn && eyesDrawn > 0 && eyesDrawn == drawable.views.count {
            if worldReady {
                frameContent = .world
                recordWorldCadence(timestamp: timestamp, image: frame.sequence)
            } else if panelReady {
                frameContent = preview ? .simulator : .menu
            }
        }
        if frameContent == .world && !reportedGame {
            reportedGame = true
            let pose = frame.render_pose.sequence, image = frame.sequence
            command.addCompletedHandler { buffer in
                NSLog("[P2XR] Game stereo GPU submission completed: image=%llu pose=%llu eyes=2 status=%lu; physical acceptance pending",image,pose,buffer.status.rawValue)
            }
        }
    }

    private func encodeReticle(_ encoder: MTLRenderCommandEncoder, projection: simd_float4x4, eyePoint: SIMD4<Float>) {
        var center = projection * eyePoint
        guard center.w.isFinite, center.w > 0, center.z >= 0, center.z <= center.w,
              abs(center.x) <= center.w, abs(center.y) <= center.w else { return }
        // A small angular size avoids a dot that grows as the surface gets closer.
        var radius = SIMD2(abs(projection.columns.0.x), abs(projection.columns.1.y)) * 0.0035
        encoder.setRenderPipelineState(reticlePipeline)
        // Share the world image's reprojection surface so the dot stays on its pixels.
        encoder.setDepthStencilState(overlayDepth)
        encoder.setVertexBytes(&center, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setVertexBytes(&radius, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func recordWorldCadence(timestamp: Double, image: UInt64) {
        guard cadenceReports < 3 else { return }
        let limit = p2_vision_game_fps_limit()
        guard auditCadence || limit > 60 else { return }
        let start = cadenceStart ?? timestamp
        cadenceStart = start
        let elapsed = timestamp - start
        if elapsed >= 2 {
            NSLog("[P2XR] World cadence: eye submissions %.1f/s, distinct game images %.1f/s, engine cap %d FPS",
                  Double(cadenceSubmissions) / elapsed, Double(cadenceImages) / elapsed, limit)
            cadenceStart = timestamp
            cadenceSubmissions = 0
            cadenceImages = 0
            cadenceReports += 1
        }
        cadenceSubmissions += 1
        if image != lastImageSequence { cadenceImages += 1 }
        lastImageSequence = image
    }

    // Menu panel half extents (meters at 2 m), always the engine image's own
    // aspect (no distortion): 2.4 m wide (about 62 degrees), at most 1.35 m
    // tall (about 37 degrees, 16:9 at full width). A 32:9 image keeps the full
    // width and gets shorter; a tall image keeps the full height.
    static func panelHalfSize(width: UInt32, height: UInt32) -> SIMD2<Float> {
        let maxHalfWidth: Float = 1.2, maxHalfHeight: Float = 0.675
        guard width > 0, height > 0 else { return SIMD2(maxHalfWidth, maxHalfHeight) }
        let aspect = Float(width) / Float(height)
        var half = SIMD2(maxHalfWidth, maxHalfWidth / aspect)
        if half.y > maxHalfHeight { half = SIMD2(maxHalfHeight * aspect, maxHalfHeight) }
        return half
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
