import Foundation
import SwiftUI

@MainActor
final class PortalCloudSaves {
    let controller: SnapshotSaveController?
    let layoutIssue: String?
    let cloudConfigured: Bool

    init(userDirectory: URL, bundle: Bundle = .main) {
        let container = PortalSavePaths.configuredContainer(in: bundle)
        cloudConfigured = container != nil
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            let paths = try PortalSavePaths(userDirectory: userDirectory, supportDirectory: support)
            controller = SnapshotSaveController(liveRoot: paths.liveRoot, storeRoot: paths.storeRoot,
                layout: .directory(id: PortalSavePaths.unit), containerIdentifier: container,
                namespace: PortalSavePaths.namespace)
            layoutIssue = nil
        } catch {
            controller = nil
            layoutIssue = error.localizedDescription
        }
    }

    #if !os(macOS)
    static let mobile = PortalCloudSaves(userDirectory: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("portal2-userdata", isDirectory: true))
    #endif
}

@MainActor
struct PortalSaveControls: View {
    @ObservedObject var saves: SnapshotSaveController
    let cloudConfigured: Bool
    let idle: Bool
    let sync: () async -> Void
    let resolve: (String, String) async -> Void
    @State private var selection: Selection?

    private struct Selection {
        let unit: String
        let choice: SnapshotSaveChoice
    }

    var body: some View {
        Text(saves.status).font(.callout)
        if saves.isSyncing {
            ProgressView().accessibilityLabel("Checking saves")
            if idle { Button("Cancel Sync", action: saves.cancelSync) }
        }
        if !cloudConfigured {
            Text("This build keeps backups on this device. An iCloud-enabled build can share them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !idle {
            Text("Close the game before checking or recovering saves.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button {
            Task { await sync() }
        } label: {
            Label(cloudConfigured ? "Sync Saves" : "Back Up Saves", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!idle || saves.isSyncing)
        if !saves.conflicts.isEmpty {
            Text("Choose the version to use. Both versions stay in recovery history.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(saves.conflicts, id: \.unit) { conflict in
                ForEach(conflict.choices, id: \.id) { choice in
                    Button(choice.label) { selection = Selection(unit: conflict.unit, choice: choice) }
                        .disabled(!idle || saves.isSyncing)
                }
            }
        }
        Color.clear.frame(height: 0)
            .confirmationDialog("Use this save version?", isPresented: Binding(
                get: { selection != nil }, set: { if !$0 { selection = nil } }),
                presenting: selection
            ) { item in
                Button("Use This Version") { Task { await resolve(item.unit, item.choice.id) } }
                    .disabled(!idle)
            }
    }
}
