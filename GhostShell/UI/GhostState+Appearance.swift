import SwiftUI
import GhostKit

/// Représentation visuelle des états. Volontairement placée côté interface :
/// le package `GhostKit` ne connaît ni couleurs ni icônes.
extension GhostState {

    /// Symbole SF affiché dans la barre de menus.
    var symbolName: String {
        switch self {
        case .active: return "circle.hexagongrid.fill"
        case .paused: return "pause.circle"
        case .stopped: return "stop.circle"
        }
    }

    /// Couleur de l'indicateur de statut.
    var color: Color {
        switch self {
        case .active: return .green
        case .paused: return .orange
        case .stopped: return .secondary
        }
    }
}
