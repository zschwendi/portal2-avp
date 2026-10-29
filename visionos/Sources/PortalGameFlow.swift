#if P2_GAME
import Foundation
import UIKit

// CompositorLayer is scene content, not a SwiftUI View. Keep its return
// action alive after the setup window closes without adding View modifiers.
@MainActor
final class PortalGameFlow {
    static let shared = PortalGameFlow()
    var immersive = false
    private var returning = false
    private var returnAction: (@MainActor () async -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .portalRequestWindow,object: nil,queue: .main) { _ in
            Task { @MainActor in await Self.shared.returnToWindow() }
        })
        observers.append(center.addObserver(forName: .portalRendererStopped,object: nil,queue: .main) { _ in
            Task { @MainActor in
                if UIApplication.shared.applicationState == .active { await Self.shared.returnToWindow() }
                else { Self.shared.immersive = false }
            }
        })
    }

    func configure(returnAction: @escaping @MainActor () async -> Void) { self.returnAction = returnAction }

    private func returnToWindow() async {
        guard immersive, !returning, let returnAction else { return }
        returning = true
        immersive = false
        await returnAction()
        returning = false
    }
}
#endif
