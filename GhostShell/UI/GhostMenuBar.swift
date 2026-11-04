import AppKit
import SwiftUI
import GhostKit
import GhostPerception

/// Icône de GHOST dans la barre de menus.
///
/// Un clic sur l'icône ouvre la petite fenêtre de contrôle (``GhostDashboard``).
/// L'icône reflète l'état courant et affiche, discrètement, le nombre
/// d'événements importants non consultés.
struct GhostMenuBar: Scene {

    let stateManager: GhostStateManager
    let perception: PerceptionController
    let windows: PerceptionWindowController

    var body: some Scene {
        MenuBarExtra {
            GhostDashboard(stateManager: stateManager, center: perception.center,
                           onOpenPerception: openPerception, onQuit: quit)
        } label: {
            let unseen = perception.center.unseenImportant.count
            HStack(spacing: 2) {
                Image(systemName: stateManager.state.symbolName)
                if unseen > 0 { Text("\(unseen)") }
            }
            .accessibilityLabel("GHOST — \(stateManager.state.displayName), \(unseen) événement(s) important(s)")
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func openPerception() {
        windows.show(stateManager: stateManager, perception: perception)
    }

    /// Quitte l'application. L'arrêt propre de GHOST est assuré par
    /// ``GhostAppDelegate/applicationWillTerminate(_:)``.
    @MainActor
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
