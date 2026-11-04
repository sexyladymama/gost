/// Erreurs levées lors d'une demande de changement d'état invalide.
public enum GhostTransitionError: Error, Equatable, Sendable {
    /// La transition demandée n'est pas autorisée par ``GhostStateMachine``.
    case invalidTransition(from: GhostState, to: GhostState)
}

/// Règles de transition entre les états de GHOST.
///
/// Fonctions pures, sans effet de bord, pour être testées isolément.
///
/// ```
///   STOPPED ──start──▶ ACTIVE ◀──resume── PAUSED
///      ▲                 │ ──pause──────────▶ │
///      └──────stop───────┴────────stop────────┘
/// ```
public enum GhostStateMachine {

    /// Indique si la transition `from` → `to` est autorisée.
    ///
    /// Une « transition » vers le même état n'est jamais autorisée.
    public static func canTransition(from: GhostState, to: GhostState) -> Bool {
        switch (from, to) {
        case (.stopped, .active),   // démarrage
             (.active, .paused),    // pause
             (.paused, .active),    // reprise
             (.active, .stopped),   // arrêt
             (.paused, .stopped):   // arrêt depuis la pause
            return true
        default:
            return false
        }
    }

    /// État cible de l'action « pause / reprise » depuis `state`,
    /// ou `nil` si cette action n'a pas de sens (GHOST arrêté).
    public static func toggledState(from state: GhostState) -> GhostState? {
        switch state {
        case .active: return .paused
        case .paused: return .active
        case .stopped: return nil
        }
    }
}
