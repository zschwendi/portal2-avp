import AppKit
import SwiftUI

private enum Palette {
    static let canvas = Color.white
    static let wash = Color(red: 244 / 255, green: 247 / 255, blue: 252 / 255)
    static let ink = Color(red: 23 / 255, green: 40 / 255, blue: 61 / 255)
    static let secondary = Color(red: 76 / 255, green: 97 / 255, blue: 120 / 255)
    static let blue = Color(red: 0, green: 92 / 255, blue: 184 / 255)
    static let orange = Color(red: 181 / 255, green: 71 / 255, blue: 8 / 255)
    static let orangeArt = Color(red: 239 / 255, green: 118 / 255, blue: 34 / 255)
    static let line = Color(red: 214 / 255, green: 224 / 255, blue: 236 / 255)
}

private struct LauncherPaths: Decodable {
    let engine: String
    let images: String
    let game: String
    let depot: String
    let saves: String
    let log: String
}

@MainActor
private final class LibraryModel: ObservableObject {
    @Published private(set) var unavailable: String?
    @Published private(set) var failure: String?
    @Published private var process: Process?
    @Published private(set) var preparingSaves = false
    @Published private(set) var saveOperation = false

    let saveSession: PortalCloudSaves?
    private var preflight: Task<Void, Never>?
    private var playRequest = 0
    private var lease: PortalSaveWriterLease?
    private let bundle: Bundle
    private let paths: LauncherPaths?
    private var worker: URL? { bundle.resourceURL?.appendingPathComponent("launch-game") }

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        paths = bundle.url(forResource: "launch", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(LauncherPaths.self, from: $0) }
        saveSession = paths.map {
            PortalCloudSaves(userDirectory: URL(fileURLWithPath: $0.saves, isDirectory: true), bundle: bundle)
        }
        recheck()
    }

    var launching: Bool { process != nil }
    var canPlay: Bool { unavailable == nil && canUseSaveControls }
    var canUseSaveControls: Bool { !launching && !preparingSaves && !saveOperation }
    var canPlayOffline: Bool { unavailable == nil && !launching && (preparingSaves || saveOperation) }
    var gameFolder: String? { paths?.game }
    var saveFolder: String? { paths?.saves }
    var logFile: String? { paths?.log }

    func recheck() {
        let files = FileManager.default
        guard let paths, let worker else {
            unavailable = "Launcher settings are missing. Rebuild the launcher to restore them."
            return
        }

        if !files.isExecutableFile(atPath: paths.engine) || !files.isExecutableFile(atPath: worker.path) {
            unavailable = "The game executable is missing. Build the Mac game to enable Play."
        } else if !isDirectory(paths.game) {
            unavailable = "Game files are unavailable. Connect the game drive and recheck."
        } else if !isDirectory(paths.images) || !isDirectory(paths.depot) {
            unavailable = "Prepared game files are missing. Prepare the Mac game data and recheck."
        } else {
            unavailable = nil
        }
    }

    func play() {
        guard !launching else { return }
        recheck()
        guard canPlay, let paths, let saveSession else { return }

        do {
            lease = try PortalSaveWriterLease(userDirectory: URL(fileURLWithPath: paths.saves, isDirectory: true))
        } catch {
            failure = error.localizedDescription
            return
        }
        failure = saveSession.layoutIssue
        guard let saves = saveSession.controller else {
            finishPreflight(true)
            return
        }
        preparingSaves = true
        playRequest += 1
        let request = playRequest
        preflight = Task { [weak self] in
            let ready = await saves.prepareForPlay()
            guard let self, playRequest == request, !Task.isCancelled else { return }
            finishPreflight(ready)
        }
    }

    func playOffline() {
        guard canPlayOffline, let saves = saveSession?.controller else { return }
        playRequest += 1
        preflight?.cancel()
        saveOperation = false
        finishPreflight(saves.playOffline())
    }

    private func finishPreflight(_ ready: Bool) {
        preparingSaves = false
        preflight = nil
        guard ready, let worker, let lease else {
            self.lease = nil
            failure = saveSession?.controller?.status
            return
        }

        let child = Process()
        child.executableURL = worker
        child.arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        child.standardInput = lease.handle
        var environment = ProcessInfo.processInfo.environment
        environment[PortalSaveWriterLease.inheritedEnvironment] = "1"
        child.environment = environment
        child.terminationHandler = { [weak self] task in
            let status = task.terminationStatus
            Task { @MainActor [weak self] in await self?.finished(status: status) }
        }

        process = child
        do {
            try child.run()
        } catch {
            process = nil
            self.lease = nil
            saveSession?.controller?.gameplayDidEnd()
            failure = "Portal 2 couldn’t start. \(error.localizedDescription)"
        }
    }

    private func finished(status: Int32) async {
        // Process termination is the proof its native and guest writers exited.
        saveOperation = true
        let request = playRequest
        process = nil
        if status != 0 {
            failure = "Portal 2 stopped with status \(status). Open the launch log for details."
        }
        if let saves = saveSession?.controller {
            saves.gameplayDidEnd()
            await saves.syncNow()
        }
        guard playRequest == request else { return }
        lease = nil
        saveOperation = false
        recheck()
    }

    func withIdleSaveLease(_ action: () async -> Void) async {
        guard canUseSaveControls, let paths else { return }
        do {
            lease = try PortalSaveWriterLease(userDirectory: URL(fileURLWithPath: paths.saves, isDirectory: true))
        } catch {
            failure = error.localizedDescription
            return
        }
        saveOperation = true
        let request = playRequest
        await action()
        guard playRequest == request else { return }
        lease = nil
        saveOperation = false
    }

    func canReveal(_ path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func reveal(_ path: String?) {
        guard let path, canReveal(path) else { return }
        let url = URL(fileURLWithPath: path)
        if isDirectory(path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct PortalArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                LinearGradient(
                    colors: [Palette.wash, .white, Palette.wash],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Canvas { context, size in
                    var seams = Path()
                    for step in 1...6 {
                        let x = size.width * CGFloat(step) / 7
                        seams.move(to: CGPoint(x: x, y: 0))
                        seams.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for fraction in [0.25, 0.56, 0.84] {
                        let y = size.height * fraction
                        seams.move(to: CGPoint(x: 0, y: y))
                        seams.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(seams, with: .color(Palette.line.opacity(0.55)), lineWidth: 1)
                }
                portal(Palette.blue)
                    .frame(width: height * 0.48, height: height * 0.73)
                    .rotationEffect(.degrees(-15))
                    .position(x: width * 0.38, y: height * 0.56)
                portal(Palette.orangeArt)
                    .frame(width: height * 0.42, height: height * 0.64)
                    .rotationEffect(.degrees(13))
                    .position(x: width * 0.63, y: height * 0.44)
            }
        }
        .accessibilityHidden(true)
    }

    private func portal(_ color: Color) -> some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Palette.ink.opacity(0.15), color.opacity(0.38)],
                                     center: .center, startRadius: 8, endRadius: 96))
            Ellipse()
                .strokeBorder(color.opacity(0.4), lineWidth: 9)
                .blur(radius: 12)
            Ellipse()
                .strokeBorder(LinearGradient(colors: [.white, color, color],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 6)
            Ellipse()
                .inset(by: 7)
                .strokeBorder(.white.opacity(0.67), lineWidth: 1)
        }
        .shadow(color: color.opacity(0.22), radius: 14, x: 0, y: 8)
    }
}

private struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @State private var showsSaves = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Library")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button("Show Game Files") { model.reveal(model.gameFolder) }
                        .disabled(!model.canReveal(model.gameFolder))
                    Button("Saves…") { showsSaves = true }
                        .disabled(model.saveSession == nil)
                    Button("Open Saves Folder") { model.reveal(model.saveFolder) }
                        .disabled(!model.canReveal(model.saveFolder))
                    Button("Show Launch Log") { model.reveal(model.logFile) }
                        .disabled(!model.canReveal(model.logFile))
                    Divider()
                    Button("Recheck Game Files", action: model.recheck)
                } label: {
                    Label("Portal 2", systemImage: "ellipsis.circle")
                        .font(.subheadline.weight(.medium))
                }
                .fixedSize()
                .foregroundStyle(Palette.ink)
            }

            VStack(spacing: 0) {
                PortalArtwork()
                    .frame(minHeight: 194, idealHeight: 254, maxHeight: .infinity)
                Divider().overlay(Palette.line)
                HStack(spacing: 22) {
                    status
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        if model.canPlayOffline { model.playOffline() }
                        else { model.play() }
                    } label: {
                        Label(model.canPlayOffline ? "Play Offline" : "Play", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 85)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(PlayButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPlayOffline && !model.canPlay)
                    .accessibilityLabel(model.canPlayOffline ? "Play Portal 2 offline" : "Play Portal 2")
                }
                .padding(18)
                .background(Palette.canvas)
            }
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17).strokeBorder(Palette.line, lineWidth: 1)
            }
            .shadow(color: Palette.ink.opacity(0.07), radius: 12, x: 0, y: 6)
        }
        .padding(30)
        .frame(minWidth: 550, minHeight: 390)
        .background(LinearGradient(colors: [Palette.canvas, Palette.wash],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.light)
        .sheet(isPresented: $showsSaves) {
            LibrarySaveSheet(model: model)
        }
    }

    @ViewBuilder private var status: some View {
        if let warning = model.unavailable ?? model.failure {
            Label(warning, systemImage: "exclamationmark.circle")
                .foregroundStyle(Palette.orange)
        } else if model.preparingSaves {
            ProgressView(model.saveSession?.cloudConfigured == true ? "Checking iCloud saves…" : "Checking local saves…")
        } else if model.saveOperation {
            ProgressView("Checking saves…")
        } else if model.launching {
            Label("Game session active", systemImage: "play.circle")
                .foregroundStyle(Palette.secondary)
        } else {
            Label("Ready to play", systemImage: "checkmark.circle")
                .foregroundStyle(Palette.secondary)
        }
    }
}

private struct LibrarySaveSheet: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saves").font(.headline)
            if let session = model.saveSession, let saves = session.controller {
                PortalSaveControls(saves: saves, cloudConfigured: session.cloudConfigured,
                    idle: !model.launching && !model.preparingSaves,
                    sync: { await model.withIdleSaveLease { await saves.syncNow() } },
                    resolve: { unit, id in
                        await model.withIdleSaveLease { await saves.resolve(unit: unit, keeping: id) }
                    })
            } else if let issue = model.saveSession?.layoutIssue {
                Text(issue)
            }
            if let failure = model.failure { Text(failure).font(.callout).foregroundStyle(.secondary) }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24).frame(minWidth: 360)
    }
}

private struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(enabled ? Palette.blue.opacity(configuration.isPressed ? 0.82 : 1) : Palette.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

@MainActor
private final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private let model = LibraryModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        installMenu()
        let controller = NSHostingController(rootView: LibraryView(model: model))
        let library = NSWindow(contentViewController: controller)
        library.title = "Library"
        library.titleVisibility = .hidden
        library.titlebarAppearsTransparent = true
        library.backgroundColor = .white
        library.contentMinSize = NSSize(width: 550, height: 390)
        library.setContentSize(NSSize(width: 690, height: 446))
        library.isReleasedWhenClosed = false
        library.center()
        library.makeKeyAndOrderFront(nil)
        window = library
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheck()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func installMenu() {
        let menubar = NSMenu()
        let application = NSMenuItem(title: "Portal 2", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Portal 2")
        applicationMenu.addItem(withTitle: "Quit Portal 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = applicationMenu
        menubar.addItem(application)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menubar.addItem(windowItem)
        NSApp.mainMenu = menubar
    }
}

@main
private struct Portal2Launcher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LauncherDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
