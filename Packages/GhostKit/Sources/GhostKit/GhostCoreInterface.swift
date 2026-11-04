/// Point d'extension destiné à accueillir le futur moteur central de GHOST.
///
/// L'interface utilisateur ne parle jamais directement au moteur : elle passe
/// par ``GhostStateManager``, qui valide les transitions puis notifie le moteur
/// via ce protocole. Un futur moteur n'aura qu'à se conformer à ce protocole
/// pour être branché, sans modification de l'interface.
///
/// Les méthodes ne sont appelées par ``GhostStateManager`` qu'après validation
/// de la transition correspondante.
@MainActor
public protocol GhostCoreInterface: AnyObject {
    /// Nom lisible du moteur, affichable dans l'interface.
    var name: String { get }

    /// Appelé lors de la transition STOPPED → ACTIVE.
    func start()
    /// Appelé lors de la transition ACTIVE → PAUSED.
    func pause()
    /// Appelé lors de la transition PAUSED → ACTIVE.
    func resume()
    /// Appelé lors de la transition ACTIVE/PAUSED → STOPPED.
    /// Le moteur doit y libérer ses ressources.
    func stop()
}

/// Implémentation vide de ``GhostCoreInterface``.
///
/// Elle ne fait **rien** : aucune analyse, aucune observation, aucune
/// collecte de données, aucun accès réseau. Elle sert uniquement de
/// valeur par défaut tant que le véritable moteur n'existe pas.
@MainActor
public final class IdleGhostCore: GhostCoreInterface {
    public let name = "Aucun moteur connecté"

    /// `nonisolated` : l'objet n'a aucun état mutable, il peut donc être
    /// créé depuis n'importe quel contexte (ex. valeur par défaut d'argument).
    nonisolated public init() {}

    public func start() {}
    public func pause() {}
    public func resume() {}
    public func stop() {}
}
