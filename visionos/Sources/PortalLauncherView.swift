#if P2_GAME
import SwiftUI

// The Library (Port Forge / Dark Eco front door): one direct card whose
// capsule imports, plays or resumes, with controller readiness beneath and
// Settings in the app-name menu. PortalGameView owns the engine and import
// state and passes it in.
struct PortalLibraryView: View {
    let state: PortalCardState
    let setup: PortalContentSetup?
    let message: String?
    @ObservedObject var importer: PortalContentImporter
    let importing: Bool
    let checking: Bool
    let play: () -> Void
    let resume: () -> Void
    let checkAgain: () -> Void
    let startImport: (URL) -> Void
    let cancelImport: () -> Void
    let dismissMessage: () -> Void
    @Binding var sheet: PortalLibrarySheet?
    @ObservedObject private var readiness = PortalControllerReadiness.shared
    @State private var explanation: String?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Library")
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: 620, alignment: .leading)
                        PortalGameCard(state: state, detail: cardDetail, focused: readiness.focused,
                                       activate: primary)
                            .frame(maxWidth: 620)
                        if case .needsFiles = state, canCheckAgain {
                            Button("Check Again", action: checkAgain)
                                .buttonStyle(PortalCapsuleButtonStyle(prominent: false))
                        }
                        PortalControllerStrip(route: readiness.route, lowBattery: readiness.lowBattery?.name)
                        if let message {
                            PortalBanner(message: message, dismiss: dismissMessage).frame(maxWidth: 560)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
                .scrollIndicators(.hidden)
            }
            .background { PortalBackdrop().ignoresSafeArea() }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Menu {
                        Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                        Button { sheet = .importFiles } label: { Label("Import Game Files\u{2026}", systemImage: "tray.and.arrow.down") }
                            .disabled(state == .paused || state == .stopped)
                        Button(action: checkAgain) { Label("Check Game Files", systemImage: "arrow.clockwise") }
                            .disabled(!canCheckAgain)
                    } label: {
                        PortalMenuLabel(name: Self.appName)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Main menu")
                }
            }
        }
        .portalThemed()
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .importFiles:
                    PortalImportSheet(setup: setup, importer: importer, importing: importing, checking: checking,
                                      start: startImport, cancel: cancelImport, checkAgain: checkAgain) { sheet = nil }
                case .settings:
                    PortalSettingsSheet(setup: setup, readiness: readiness) { sheet = nil }
                }
            }
            .portalThemed()
        }
        .alert("Not Available", isPresented: Binding(get: { explanation != nil }, set: { if !$0 { explanation = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(explanation ?? "") }
        .onAppear { readiness.refresh(); navigate() }
        // The closure holds this view's values: renew it when the action changes
        // (not on every import progress step, which would clear focus).
        .onChange(of: state.action) { navigate() }
        .onDisappear { readiness.endCardNavigation() }
    }

    // A controller acts on the card only while nothing covers it.
    private func navigate() {
        readiness.beginCardNavigation { [sheet = $sheet, explanation = $explanation] in
            guard sheet.wrappedValue == nil, explanation.wrappedValue == nil else { return }
            primary()
        }
    }

    private func primary() {
        switch state.action {
        case .importFiles, .showProgress: sheet = .importFiles
        case .play: play()
        case .resume: resume()
        case .explain(let reason): explanation = reason
        case .wait: break
        }
    }

    private var canCheckAgain: Bool {
        switch state {
        case .needsFiles, .ready: return !checking
        default: return false
        }
    }

    private var cardDetail: String {
        switch state {
        case .checking: return "Looking for your game files on this Vision Pro."
        case .needsFiles:
            guard let setup, !setup.nothingImported else { return "Import your own Portal 2 files from your Mac to play." }
            return setup.complete ? setup.headline : setup.detail
        case .importing: return importer.status
        case .ready: return "Play in this window, then use the expand arrows to play around you."
        case .starting: return "Starting Portal 2\u{2026}"
        case .paused: return "Your game is paused right where you left it."
        case .stopped: return PortalCardState.stoppedReason
        }
    }

    static var appName: String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String, !name.isEmpty { return name }
        }
        return "Portal 2"
    }
}

enum PortalLibrarySheet: String, Identifiable {
    case importFiles, settings
    var id: String { rawValue }
}

// The single direct card: tapping anywhere performs the capsule's action. The
// app is named Portal 2, so the identical game title is not repeated here.
struct PortalGameCard: View {
    let state: PortalCardState
    let detail: String
    let focused: Bool
    let activate: () -> Void

    var body: some View {
        let action = state.action
        Button(action: activate) {
            HStack(alignment: .center, spacing: 18) {
                PortalCover()
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: PortalStyle.cornerRadius - 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PortalStyle.cornerRadius - 4, style: .continuous)
                            .strokeBorder(PortalStyle.border, lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 10) {
                    status
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(PortalStyle.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .importing(let fraction) = state, let fraction {
                        ProgressView(value: fraction).tint(PortalStyle.accent)
                    }
                    HStack(spacing: 10) {
                        Label(action.title, systemImage: action.symbolName)
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .foregroundStyle(action.prominent ? PortalStyle.textOnAccent : PortalStyle.accent)
                            .background(action.prominent ? PortalStyle.accent : PortalStyle.controlFill, in: Capsule())
                        if focused, action.prominent {
                            Text("Press \u{2715} again").font(.caption).foregroundStyle(PortalStyle.accentGlow)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(PortalStyle.surface, in: RoundedRectangle(cornerRadius: PortalStyle.cornerRadius, style: .continuous))
            .shadow(color: PortalStyle.shadow, radius: 20, x: 0, y: 8)
            .overlay {
                RoundedRectangle(cornerRadius: PortalStyle.cornerRadius, style: .continuous)
                    .strokeBorder(focused ? PortalStyle.accentGlow : PortalStyle.border, lineWidth: focused ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: PortalStyle.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect { effect, active, _ in effect.scaleEffect(active ? 1.02 : 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Portal 2, \(state.statusLabel), \(action.title)")
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .checking, .starting, .importing(fraction: nil):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.statusLabel)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PortalStyle.accentGlow)
        default:
            Label(state.statusLabel, systemImage: state.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch state {
        case .ready: return PortalStyle.success
        case .paused: return PortalStyle.accent
        case .needsFiles(let incomplete): return incomplete ? PortalStyle.warning : PortalStyle.textSecondary
        case .stopped: return PortalStyle.danger
        case .checking, .starting, .importing: return PortalStyle.accentGlow
        }
    }
}

struct PortalControllerStrip: View {
    let route: PortalControllerRoute
    let lowBattery: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(route.ready ? PortalStyle.success : PortalStyle.warning)
                Text(route.summary).font(.callout.weight(.medium))
            }
            Text(lowBattery.map { "\($0) battery is low." } ?? route.detail)
                .font(.caption)
                .foregroundStyle(lowBattery == nil ? PortalStyle.textSecondary : PortalStyle.warning)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PortalStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(PortalStyle.border, lineWidth: 1) }
        .frame(maxWidth: 560)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch route {
        case .sensePair, .singleSense: return "hand.raised.fingers.spread"
        case .gamepad: return "gamecontroller.fill"
        case .none: return "gamecontroller"
        }
    }
}

struct PortalBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PortalStyle.warning)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(PortalStyle.textSecondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(PortalStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(PortalStyle.border, lineWidth: 1) }
    }
}

// Copies the player's own files from their Mac (tools/serve_owned_content.py).
// Files already here are verified and kept; a failed or cancelled import keeps
// everything already installed, saves included.
struct PortalImportSheet: View {
    let setup: PortalContentSetup?
    @ObservedObject var importer: PortalContentImporter
    let importing: Bool
    let checking: Bool
    let start: (URL) -> Void
    let cancel: () -> Void
    let checkAgain: () -> Void
    let close: () -> Void
    @State private var address = ""

    private var url: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), (try? PortalContentImporter.capabilityBase(url)) != nil else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let setup, !setup.complete {
                        PortalPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(setup.headline).font(.headline)
                                Text(setup.detail).font(.callout).foregroundStyle(PortalStyle.textSecondary)
                                if !setup.names.isEmpty {
                                    Text(setup.names.joined(separator: ", ") + (setup.moreNames ? ", \u{2026}" : ""))
                                        .font(.caption.monospaced()).foregroundStyle(PortalStyle.textSecondary)
                                        .lineLimit(3)
                                }
                                if !setup.space.isEmpty {
                                    Text(setup.space).font(.caption)
                                        .foregroundStyle(setup.spaceShort ? PortalStyle.warning : PortalStyle.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    PortalPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Copy your game files from your Mac").font(.headline)
                            Text("Portal 2 plays from your own copy of the game. On your Mac, start the file source described in AVP-INSTALL.md, then paste the import address it gives you. Keep this Vision Pro awake and allow Local Network access.")
                                .font(.callout).foregroundStyle(PortalStyle.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                TextField("Import address", text: $address)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .disabled(importing)
                                PasteButton(payloadType: String.self) { values in
                                    if let first = values.first { address = first }
                                }
                                .labelStyle(.iconOnly)
                                .disabled(importing)
                            }
                            if !address.isEmpty && url == nil {
                                Text("That isn\u{2019}t an import address. It ends in manifest.json.")
                                    .font(.caption).foregroundStyle(PortalStyle.warning)
                            }
                            if importing {
                                ProgressView(value: Double(importer.completedBytes), total: Double(max(importer.totalBytes, 1)))
                                    .tint(PortalStyle.accent)
                            }
                            if importing || importer.status != "Idle" {
                                Text(importer.status).font(.caption).foregroundStyle(PortalStyle.textSecondary)
                            }
                            HStack(spacing: 12) {
                                if importing {
                                    Button("Cancel Import", role: .cancel, action: cancel)
                                        .buttonStyle(PortalCapsuleButtonStyle(prominent: false))
                                } else {
                                    Button { if let url { start(url) } } label: {
                                        Label("Import", systemImage: "tray.and.arrow.down")
                                    }
                                    .buttonStyle(PortalCapsuleButtonStyle())
                                    .disabled(url == nil || checking)
                                    Button("Check Again", action: checkAgain)
                                        .buttonStyle(PortalCapsuleButtonStyle(prominent: false))
                                        .disabled(checking)
                                }
                                if checking { ProgressView().controlSize(.small) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .background { PortalBackdrop().ignoresSafeArea() }
            .navigationTitle("Game Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: close).disabled(importing) }
            }
        }
        .interactiveDismissDisabled(importing)
        .frame(minWidth: 560, minHeight: 520)
    }
}

struct PortalSettingsSheet: View {
    let setup: PortalContentSetup?
    @ObservedObject var readiness: PortalControllerReadiness
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Controllers") {
                    Label(readiness.route.summary, systemImage: readiness.route.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(readiness.route.ready ? PortalStyle.success : PortalStyle.warning)
                    ForEach(readiness.devices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            if let battery = device.battery {
                                Text(battery.formatted(.percent.precision(.fractionLength(0))))
                                    .foregroundStyle(battery < 0.15 ? PortalStyle.warning : PortalStyle.textSecondary)
                            }
                        }
                    }
                }
                .listRowBackground(PortalStyle.surface)
                Section("DualSense or gamepad") {
                    row("Move / look", "Left stick / right stick")
                    row("Blue / orange portal", "R2 / L2")
                    row("Jump \u{00B7} crouch \u{00B7} use", "\u{2715} \u{00B7} \u{25CB} \u{00B7} \u{25A1}")
                    row("Pause", "Options")
                }
                .listRowBackground(PortalStyle.surface)
                Section("PS VR2 Sense") {
                    row("Move / look", "Left stick / right stick")
                    row("Blue / orange portal", "Right / left trigger")
                    row("Jump \u{00B7} use", "\u{2715} \u{00B7} \u{25A1} or either grip")
                    row("Crouch", "\u{25B3} or \u{25CB}")
                    row("Aim (immersive)", "Point the right controller")
                }
                .listRowBackground(PortalStyle.surface)
                Section("Immersive view") {
                    Text("Use the expand arrows on the game window to play around you. Pause, or hold both stick buttons, to come back to the window. Press the left stick to recenter.")
                    Text("Without a controller, hand gestures work in immersive view.")
                        .foregroundStyle(PortalStyle.textSecondary)
                }
                .listRowBackground(PortalStyle.surface)
                Section("Saves and game files") {
                    row("Game files", setup.map { $0.complete ? "Complete" : "Incomplete" } ?? "Not checked yet")
                    Text("Saves and settings stay on this Vision Pro with the app. Deleting the app deletes them.")
                        .foregroundStyle(PortalStyle.textSecondary)
                }
                .listRowBackground(PortalStyle.surface)
                Section("Online") {
                    row("Steam Workshop", "Not available")
                    row("Online co-op", "Not available")
                    row("Cloud saves", "Not available")
                }
                .listRowBackground(PortalStyle.surface)
                Section {
                    row("Version", Self.version)
                }
                .listRowBackground(PortalStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background { PortalBackdrop().ignoresSafeArea() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(PortalStyle.textSecondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
#endif
