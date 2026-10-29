import SwiftUI
import CompositorServices

@main
struct Portal2AVPApp: App {
    var body: some Scene {
        #if P2_GAME
        WindowGroup(id: "game-window") { PortalGameView() }.defaultSize(width: 1000, height: 680)
        ImmersiveSpace(id: "game-world") {
            CompositorLayer(configuration: PortalLayerConfiguration()) { layer in PortalRenderer.start(layer: layer) }
        }
            .immersionStyle(selection: .constant(.full),in: .full)
        #else
        WindowGroup(id: "setup") {
            RendererCheckView()
        }.defaultSize(width: 540, height: 460)
        ImmersiveSpace(id: "renderer-check") {
            CompositorLayer(configuration: PortalLayerConfiguration()) { layer in
                PortalRenderer.start(layer: layer)
            }
        }.immersionStyle(selection: .constant(.full), in: .full)
        #endif
    }
}

private struct RendererCheckView: View {
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @Environment(\.scenePhase) private var phase
    @State private var open = false
    @State private var busy = false
    @State private var status = "Portal 2 game rendering is not connected yet."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Portal 2 AVP").font(.largeTitle)
            Text("Stereo renderer check").font(.title2)
            Text("This development check draws a scale grid and two boxes in an immersive space. It tests Metal presentation and head tracking. It does not launch Portal 2.")
                .fixedSize(horizontal: false, vertical: true)
            Text(status).font(.callout).foregroundStyle(.secondary)
            #if targetEnvironment(simulator)
            Text("The simulator uses a simulated pose. Physical head tracking requires Vision Pro.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            HStack {
                Button(open ? "Close renderer check" : "Open renderer check") {
                    Task { await toggleSpace() }
                }.disabled(busy)
            }
            Text("Gamepad input is captured for the engine bridge; it does not move the calibration scene.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .task {
            // Deterministic, explicit launch option for simulator verification.
            if ProcessInfo.processInfo.arguments.contains("--renderer-check") { await toggleSpace() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .portalRendererStopped)) { _ in
            open = false
            busy = false
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { PortalController.releaseAll() }
        }
    }

    @MainActor private func toggleSpace() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if open {
            await dismissSpace()
            open = false
        } else {
            switch await openSpace(id: "renderer-check") {
            case .opened: open = true
            case .userCancelled: status = "Opening was cancelled."
            case .error: status = "The immersive space could not open."
            @unknown default: status = "The system returned an unknown result."
            }
        }
    }
}

extension Notification.Name {
    static let portalRendererStopped = Notification.Name("Portal2RendererStopped")
    static let portalRequestWindow = Notification.Name("Portal2RequestWindow")
}
