import AppKit
import SwiftUI
import GhostKit

/// Icône de GHOST dans la barre de menus.
///
/// Un clic sur l'icône ouvre la petite fenêtre de contrôle (``GhostDashboard``).
/// L'icône reflète l'état courant.
struct GhostMenuBar: Scene {

    let stateManager: GhostStateManager

    var body: some Scene {
        MenuBarExtra {
            GhostDashboard(stateManager: stateManager, onQuit: quit)
        } label: {
            Image(systemName: stateManager.state.symbolName)
                .accessibilityLabel("GHOST — \(stateManager.state.displayName)")
        }
        .menuBarExtraStyle(.window)
    }

    /// Quitte l'application. L'arrêt propre de GHOST est assuré par
    /// ``GhostAppDelegate/applicationWillTerminate(_:)``.
    @MainActor
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
