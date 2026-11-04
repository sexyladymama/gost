import Foundation

/// Connecteur de source de perception.
///
/// Chaque connecteur est indépendant et ne fait que **lire** : il renvoie des
/// observations brutes que le moteur normalise, interprète et stocke.
///
/// Pour ajouter une source (calendrier, messagerie…), il suffit de créer un
/// type conforme à ce protocole, une ``Permission`` adaptée, et de
/// l'enregistrer auprès du ``PerceptionEngine``.
public protocol PerceptionSource: Sendable {
    var descriptor: EventSource { get }
    /// Intervalle minimal entre deux collectes.
    var pollInterval: TimeInterval { get }
    /// Collecte les nouvelles observations. Doit vérifier ses autorisations
    /// auprès du ``TrustEngine`` avant tout accès.
    func poll() async throws -> [RawObservation]
    /// Révoque l'accès externe de la source (ex. jeton OAuth), si applicable.
    func revokeAccess() async throws
    /// Oublie l'état interne (curseurs, instantanés) après suppression des données.
    func resetState() async
}
