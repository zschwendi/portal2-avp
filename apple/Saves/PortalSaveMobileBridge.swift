#if os(iOS)
import SwiftUI
import UIKit

@MainActor
@objc(P2SaveBridge)
final class PortalSaveMobileBridge: NSObject {
    private static var session: PortalCloudSaves?

    @objc(configureUserDirectory:)
    static func configure(userDirectory: String) {
        session = PortalCloudSaves(userDirectory: URL(fileURLWithPath: userDirectory, isDirectory: true))
    }

    @objc static var status: String {
        session?.controller?.status ?? session?.layoutIssue ?? "Save backups are unavailable."
    }

    @objc static var cloudConfigured: Bool { session?.controller != nil && session?.cloudConfigured == true }

    @objc static func playOffline() -> Bool {
        guard let session else { return false }
        return session.controller?.playOffline() ?? true
    }

    @objc(prepareWithCloud:completion:)
    static func prepare(withCloud: Bool, completion: @escaping (Bool) -> Void) {
        guard let saves = session?.controller else { completion(session != nil); return }
        guard withCloud else {
            completion(saves.playOffline())
            return
        }
        Task {
            completion(await saves.prepareForPlay())
        }
    }

    @objc static func launchDidNotStart() { session?.controller?.gameplayDidEnd() }

    @objc(presentFrom:savesChanged:)
    static func present(from parent: UIViewController, savesChanged: @escaping () -> Void) {
        guard let session else { return }
        let settings = PortalSaveMobileSettings(session: session, savesChanged: savesChanged)
        let sheet = UIHostingController(rootView: settings)
        sheet.modalPresentationStyle = .formSheet
        parent.present(sheet, animated: true)
    }
}

private struct PortalSaveMobileSettings: View {
    @Environment(\.dismiss) private var dismiss
    let session: PortalCloudSaves
    let savesChanged: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let saves = session.controller {
                    Section {
                        PortalSaveControls(saves: saves, cloudConfigured: session.cloudConfigured, idle: true,
                            sync: {
                                await saves.syncNow()
                                savesChanged()
                            }, resolve: {
                                await saves.resolve(unit: $0, keeping: $1)
                                savesChanged()
                            })
                    }
                } else if let problem = session.layoutIssue {
                    Text(problem)
                }
            }
            .navigationTitle("Saves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
