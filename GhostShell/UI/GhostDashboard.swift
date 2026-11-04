import SwiftUI
import GhostKit

/// Petite fenêtre de contrôle affichée au clic sur l'icône de la barre de menus.
///
/// La vue ne contient aucune logique métier : elle affiche l'état fourni par
/// ``GhostStateManager`` et lui transmet les actions de l'utilisateur.
struct GhostDashboard: View {

    let stateManager: GhostStateManager

    /// Action « Quitter », injectée pour garder la vue indépendante d'AppKit
    /// (et donc prévisualisable).
    let onQuit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusRow
            Divider()
            controls
        }
        .padding(16)
        .frame(width: 260)
    }

    // MARK: - Sous-vues

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GHOST")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
            Text("Shell \(Self.appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Text("Statut")
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(stateManager.state.color)
                .frame(width: 8, height: 8)
            Text(stateManager.state.displayName)
                .font(.system(.body, design: .monospaced).weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Statut : \(stateManager.state.displayName)")
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button(action: togglePause) {
                Label(toggleTitle, systemImage: toggleSymbol)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!stateManager.canTogglePause)

            Button(role: .destructive, action: onQuit) {
                Text("Quitter GHOST")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Actions & libellés

    private func togglePause() {
        // Le bouton est désactivé quand la bascule est impossible ;
        // une erreur ici serait donc une erreur de programmation.
        do {
            try stateManager.togglePause()
        } catch {
            assertionFailure("Bascule impossible : \(error)")
        }
    }

    private var toggleTitle: String {
        stateManager.state == .paused ? "Reprendre" : "Mettre en pause"
    }

    private var toggleSymbol: String {
        stateManager.state == .paused ? "play.fill" : "pause.fill"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

#Preview("Active") {
    GhostDashboard(stateManager: GhostStateManager(initialState: .active), onQuit: {})
}

#Preview("Paused") {
    GhostDashboard(stateManager: GhostStateManager(initialState: .paused), onQuit: {})
}
