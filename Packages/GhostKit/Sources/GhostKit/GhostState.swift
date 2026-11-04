/// Les états de fonctionnement possibles de GHOST.
///
/// La valeur brute (`rawValue`) correspond au libellé affiché à l'utilisateur.
public enum GhostState: String, CaseIterable, Sendable {
    /// GHOST est en fonctionnement.
    case active = "ACTIVE"
    /// GHOST est suspendu temporairement et peut reprendre.
    case paused = "PAUSED"
    /// GHOST est arrêté (état initial et état final avant de quitter).
    case stopped = "STOPPED"

    /// Libellé affiché dans l'interface.
    public var displayName: String { rawValue }
}
