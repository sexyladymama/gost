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
    @AppStorage(GhostAppearance.storageKey) private var appearanceRaw = GhostAppearance.dark.rawValue

    /// Ouvre la fenêtre GHOST Perception.
    let onOpenPerception: @MainActor () -> Void
    /// Action « Quitter », injectée pour garder la vue indépendante d'AppKit
    /// (et donc prévisualisable).
    let onQuit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusRow.padding(12).ghostGlass(cornerRadius: 14)
            perceptionSummary.padding(12).ghostGlass(cornerRadius: 14)
            controls
        }
        .padding(16)
        .frame(width: 320)
        .background(GhostBackdrop())
        .ghostAppearance(GhostAppearance(rawValue: appearanceRaw) ?? .dark)
    }

    // MARK: - Sous-vues

    private var header: some View {
        HStack(alignment: .top) {
            GhostWordmark(size: 26, subtitle: "shell v\(Self.appVersion)")
            Spacer()
            GhostAppearanceToggle()
        }
        .padding(.bottom, 2)
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
                            Circle().fill(GhostTheme.accent).frame(width: 6, height: 6).shadow(color: GhostTheme.accent, radius: 3)
                        }
                    }
                }
            }
            Button(action: onOpenPerception) {
                Text("Voir ce que GHOST a détecté…")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(GhostTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button(action: togglePause) {
                Label(toggleTitle, systemImage: toggleSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle(prominent: true))
            .disabled(!stateManager.canTogglePause)

            Button(action: toggleRunning) {
                Text(stateManager.state == .stopped ? "Démarrer la perception" : "Arrêter la perception")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle())

            Button(role: .destructive, action: onQuit) {
                Text("Quitter GHOST")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle(destructive: true))
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
