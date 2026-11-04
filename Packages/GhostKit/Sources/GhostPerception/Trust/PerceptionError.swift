import Foundation

/// Erreurs du moteur de perception.
public enum PerceptionError: Error, Equatable, Sendable, LocalizedError {
    /// Aucune autorisation pour cette source ou cette ressource.
    case notAuthorized(source: SourceID, resource: String)
    /// Requête réseau vers une destination non autorisée, bloquée avant envoi.
    case egressDenied(host: String)
    /// L'utilisateur doit (re)connecter son compte.
    case authorizationRequired(source: SourceID)
    /// Échec d'authentification (jeton refusé).
    case authenticationFailed(String)
    /// Service injoignable, coupure réseau, erreur serveur.
    case connectionFailed(String)
    /// Trop de requêtes : le fournisseur limite le débit.
    case rateLimited
    /// Réponse illisible ou inattendue.
    case invalidResponse(String)
    /// Configuration incomplète (ex. identifiant client OAuth manquant).
    case misconfigured(String)
    /// Données locales illisibles ou impossibles à sauvegarder.
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notAuthorized(source, resource):
            return "Accès refusé : la source « \(source) » n'est pas autorisée pour \(resource)."
        case let .egressDenied(host):
            return "Transmission bloquée : \(host) n'est pas une destination autorisée."
        case let .authorizationRequired(source):
            return "La source « \(source) » doit être (re)connectée."
        case let .authenticationFailed(detail):
            return "Échec d'authentification : \(detail)"
        case let .connectionFailed(detail):
            return "Connexion impossible : \(detail)"
        case .rateLimited:
            return "Le service limite temporairement les requêtes."
        case let .invalidResponse(detail):
            return "Réponse inattendue du service : \(detail)"
        case let .misconfigured(detail):
            return "Configuration incomplète : \(detail)"
        case let .storageFailed(detail):
            return "Stockage local : \(detail)"
        }
    }
}
