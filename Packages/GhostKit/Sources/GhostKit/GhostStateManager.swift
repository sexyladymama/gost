import Observation

/// Source de vérité unique de l'état de GHOST.
///
/// - Valide chaque changement d'état avec ``GhostStateMachine``.
/// - Notifie le moteur (``GhostCoreInterface``) des transitions acceptées.
/// - Est observable par SwiftUI grâce à `@Observable`.
///
/// Toutes les opérations s'exécutent sur le thread principal (`@MainActor`),
/// ce qui garantit des mises à jour d'interface cohérentes.
@MainActor
@Observable
public final class GhostStateManager {

    /// État courant. Modifiable uniquement via les méthodes du gestionnaire.
    public private(set) var state: GhostState

    /// Moteur notifié des changements d'état.
    @ObservationIgnored
    public let core: GhostCoreInterface

    /// - Parameters:
    ///   - core: moteur à notifier (par défaut, ``IdleGhostCore`` qui ne fait rien).
    ///   - initialState: état de départ (par défaut ``GhostState/stopped``).
    public init(core: GhostCoreInterface = IdleGhostCore(),
                initialState: GhostState = .stopped) {
        self.core = core
        self.state = initialState
    }

    // MARK: - Requêtes

    /// `true` si l'action « pause / reprise » est disponible.
    public var canTogglePause: Bool {
        GhostStateMachine.toggledState(from: state) != nil
    }

    // MARK: - Commandes

    /// STOPPED → ACTIVE.
    public func start() throws {
        try transition(to: .active)
        core.start()
    }

    /// ACTIVE → PAUSED.
    public func pause() throws {
        try transition(to: .paused)
        core.pause()
    }

    /// PAUSED → ACTIVE.
    public func resume() throws {
        guard state == .paused else {
            throw GhostTransitionError.invalidTransition(from: state, to: .active)
        }
        try transition(to: .active)
        core.resume()
    }

    /// Bascule ACTIVE ↔ PAUSED.
    ///
    /// - Throws: ``GhostTransitionError`` si GHOST est arrêté.
    public func togglePause() throws {
        switch state {
        case .active: try pause()
        case .paused: try resume()
        case .stopped:
            throw GhostTransitionError.invalidTransition(from: .stopped, to: .paused)
        }
    }

    /// ACTIVE/PAUSED → STOPPED.
    ///
    /// Idempotent : sans effet si GHOST est déjà arrêté, afin de pouvoir être
    /// appelé sans risque lors de la fermeture de l'application.
    public func stop() {
        guard state != .stopped else { return }
        state = .stopped
        core.stop()
    }

    // MARK: - Privé

    private func transition(to newState: GhostState) throws {
        guard GhostStateMachine.canTransition(from: state, to: newState) else {
            throw GhostTransitionError.invalidTransition(from: state, to: newState)
        }
        state = newState
    }
}
