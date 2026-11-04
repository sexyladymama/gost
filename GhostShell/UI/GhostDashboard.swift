import SwiftUI
import GhostKit
import GhostPerception

/// Petite fenêtre de contrôle affichée au clic sur l'icône de la barre de menus.
///
/// La vue ne contient aucune logique métier : elle affiche l'état fourni par
/// ``GhostStateManager`` et ``PerceptionCenter`` et leur transmet les actions
/// de l'utilisateur.
struct GhostDashboard: View {

    let stateManager: GhostStateManager
    let center: PerceptionCenter

    /// Ouvre la fenêtre GHOST Perception.
    let onOpenPerception: @MainActor () -> Void
    /// Action « Quitter », injectée pour garder la vue indépendante d'AppKit
    /// (et donc prévisualisable).
    let onQuit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusRow
            Divider()
            perceptionSummary
            Divider()
            controls
        }
        .padding(16)
        .frame(width: 300)
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

    private var perceptionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Perception").font(.headline)
                Spacer()
                Text(center.engineState.label).font(.caption).foregroundStyle(.secondary)
            }
            Text(sourcesLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)

            if !center.issues.isEmpty {
                Label("\(center.issues.count) anomalie(s) de perception", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            let recent = Array(center.importantEvents.prefix(3))
            if recent.isEmpty {
                Text("Rien d'important détecté pour l'instant.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(recent) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: event.kind.symbolName).foregroundStyle(event.kind.color).frame(width: 16)
                        Text(event.summary).font(.callout).lineLimit(2)
                        Spacer(minLength: 0)
                        if center.unseenImportant.contains(event.id) {
                            Circle().fill(.blue).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            Button("Voir ce que GHOST a détecté…", action: onOpenPerception)
                .buttonStyle(.link)
        }
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

            Button(action: toggleRunning) {
                Text(stateManager.state == .stopped ? "Démarrer la perception" : "Arrêter la perception")
                    .frame(maxWidth: .infinity)
            }

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

    private func toggleRunning() {
        if stateManager.state == .stopped {
            try? stateManager.start()
        } else {
            stateManager.stop()
        }
    }

    private var sourcesLine: String {
        let enabled = center.sources.filter(\.isEnabled).map(\.descriptor.displayName)
        return enabled.isEmpty ? "Aucune source active" : enabled.joined(separator: " · ")
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
    let perception = PerceptionController(persistent: false)
    return GhostDashboard(stateManager: GhostStateManager(core: perception.center, initialState: .active),
                          center: perception.center, onOpenPerception: {}, onQuit: {})
}
