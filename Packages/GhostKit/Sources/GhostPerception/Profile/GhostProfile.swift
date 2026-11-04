import Foundation

/// Profil local d'un utilisateur. Toutes les données collectées, autorisations,
/// états de sources et journaux d'un utilisateur sont rangés dans son propre
/// répertoire : deux profils ne partagent jamais de données.
public struct GhostProfile: Sendable, Hashable {
    public let id: String
    public let directory: URL

    public init(id: String, baseDirectory: URL) {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        self.id = safe.isEmpty ? "default" : safe
        self.directory = baseDirectory.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(self.id, isDirectory: true)
    }

    /// Profil de l'utilisateur de la session courante.
    public static func current(baseDirectory: URL) -> GhostProfile {
        GhostProfile(id: ProcessInfo.processInfo.userName, baseDirectory: baseDirectory)
    }

    public var eventsURL: URL { directory.appendingPathComponent("events.json") }
    public var grantsURL: URL { directory.appendingPathComponent("grants.json") }
    public var accessLogURL: URL { directory.appendingPathComponent("access-log.jsonl") }
    public var sourceStateDirectory: URL { directory.appendingPathComponent("sources", isDirectory: true) }
}
