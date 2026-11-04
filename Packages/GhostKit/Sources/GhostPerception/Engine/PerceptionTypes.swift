import Foundation

/// État du moteur de perception.
public enum EngineState: String, Sendable, Codable {
    /// Collecte en cours.
    case running
    /// Collecte suspendue : aucune source n'est interrogée.
    case paused
    /// Perception arrêtée : aucune source n'est interrogée.
    case stopped
}

/// État d'une source, affiché dans l'interface.
public struct SourceStatus: Sendable, Hashable, Identifiable {
    public enum Health: String, Sendable {
        case waiting, ok, error, disabled, unauthorized
    }
    public var id: SourceID { descriptor.id }
    public var descriptor: EventSource
    public var isEnabled: Bool
    public var isAuthorized: Bool
    public var lastPoll: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var consecutiveFailures: Int
    public var detectedCount: Int

    public var health: Health {
        if !isEnabled { return .disabled }
        if !isAuthorized { return .unauthorized }
        if lastError != nil { return .error }
        return lastSuccess == nil ? .waiting : .ok
    }
}

/// Anomalie ou erreur de perception, signalée à l'utilisateur.
public struct PerceptionIssue: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        /// Service ou dossier injoignable.
        case connection
        /// Compte à reconnecter, jeton refusé.
        case authorization
        /// Accès refusé par le Trust Engine.
        case access
        /// Autre anomalie.
        case other
    }
    public var id: UUID
    public var date: Date
    public var sourceID: SourceID
    public var kind: Kind
    public var message: String

    public init(id: UUID = UUID(), date: Date, sourceID: SourceID, kind: Kind, message: String) {
        self.id = id
        self.date = date
        self.sourceID = sourceID
        self.kind = kind
        self.message = message
    }
}

/// Mise à jour diffusée par le moteur.
public enum PerceptionUpdate: Sendable {
    case state(EngineState)
    case newEvents([GhostEvent])
    case issue(PerceptionIssue)
    case sources([SourceStatus])
    case dataCleared
}

/// Bilan d'un cycle de collecte.
public struct CycleReport: Sendable {
    public var polled: [SourceID] = []
    public var newEvents: [GhostEvent] = []
    public var issues: [PerceptionIssue] = []
    /// Le cycle n'a pas eu lieu (moteur en pause ou arrêté).
    public var skipped = false
}

/// Point de branchement des futurs moteurs de GHOST (planification,
/// mémoire…). Ils reçoivent les nouveaux événements structurés.
public protocol PerceptionEventConsumer: Sendable {
    func consume(_ events: [GhostEvent]) async
    func sourceWasRevoked(_ source: SourceID, retainHistory: Bool) async throws
    func deleteMemory() async throws
}

public extension PerceptionEventConsumer {
    func sourceWasRevoked(_ source: SourceID, retainHistory: Bool) async throws {}
    func deleteMemory() async throws {}
}
