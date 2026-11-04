import SwiftUI
import GhostPerception

/// Représentation visuelle des types d'événements (couche interface uniquement).
extension GhostEventKind {
    var label: String {
        switch self {
        case .information: return "Information"
        case .request: return "Demande"
        case .task: return "Tâche"
        case .deadline: return "Échéance"
        case .followUp: return "Relance"
        case .documentEvent: return "Document"
        case .conversation: return "Conversation"
        }
    }

    var symbolName: String {
        switch self {
        case .information: return "info.circle"
        case .request: return "questionmark.bubble"
        case .task: return "checklist"
        case .deadline: return "calendar.badge.clock"
        case .followUp: return "arrow.uturn.forward.circle"
        case .documentEvent: return "doc"
        case .conversation: return "bubble.left.and.bubble.right"
        }
    }

    var color: Color {
        switch self {
        case .information: return .secondary
        case .request: return .blue
        case .task: return .purple
        case .deadline: return .orange
        case .followUp: return .pink
        case .documentEvent: return .teal
        case .conversation: return .gray
        }
    }
}

extension EngineState {
    var label: String {
        switch self {
        case .running: return "Perception active"
        case .paused: return "En pause — aucune collecte"
        case .stopped: return "Perception arrêtée"
        }
    }
}

extension SourceStatus.Health {
    var label: String {
        switch self {
        case .waiting: return "En attente de la première collecte"
        case .ok: return "Fonctionne"
        case .error: return "Erreur"
        case .disabled: return "Désactivée"
        case .unauthorized: return "Non autorisée"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .waiting: return .blue
        case .error: return .red
        case .disabled, .unauthorized: return .secondary
        }
    }
}

/// Pastille du type d'événement.
struct EventKindBadge: View {
    let kind: GhostEventKind
    var body: some View {
        Label(kind.label, systemImage: kind.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.color.opacity(0.12), in: Capsule())
    }
}

/// Mention « SIMULATION » pour les données fictives.
struct SimulationBadge: View {
    var body: some View {
        Text("SIMULATION")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(.orange))
            .accessibilityLabel("Données simulées")
    }
}
