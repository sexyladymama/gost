import Foundation

/// Stockage des événements détectés.
///
/// Garantie : un événement n'est jamais enregistré deux fois. L'unicité est
/// assurée par ``GhostEvent/fingerprint`` (source + identifiant externe + version).
public protocol EventStore: Sendable {
    /// Enregistre les événements et renvoie **uniquement** ceux qui étaient nouveaux.
    func insert(_ events: [GhostEvent]) async throws -> [GhostEvent]
    func contains(fingerprint: String) async -> Bool
    /// Tous les événements, du plus récent au plus ancien.
    func all() async -> [GhostEvent]
    /// Supprime toutes les données collectées.
    func deleteAll() async throws
    /// Supprime les données d'une source.
    func delete(source: SourceID) async throws
}

/// Stockage JSON dans le répertoire du profil de l'utilisateur.
public actor FileEventStore: EventStore {
    private let fileURL: URL?
    private var events: [GhostEvent] = []
    private var fingerprints: Set<String> = []
    private var loaded = false
    private let capacity: Int

    /// - Parameter fileURL: `nil` pour un stockage en mémoire.
    public init(fileURL: URL?, capacity: Int = 5_000) {
        self.fileURL = fileURL
        self.capacity = capacity
    }

    public static func inMemory() -> FileEventStore { FileEventStore(fileURL: nil) }

    public func insert(_ newEvents: [GhostEvent]) async throws -> [GhostEvent] {
        loadIfNeeded()
        var inserted: [GhostEvent] = []
        for event in newEvents where !fingerprints.contains(event.fingerprint) {
            fingerprints.insert(event.fingerprint)
            events.append(event)
            inserted.append(event)
        }
        if events.count > capacity {
            let removed = events.prefix(events.count - capacity)
            removed.forEach { fingerprints.remove($0.fingerprint) }
            events.removeFirst(removed.count)
        }
        if !inserted.isEmpty { try save() }
        return inserted
    }

    public func contains(fingerprint: String) async -> Bool {
        loadIfNeeded()
        return fingerprints.contains(fingerprint)
    }

    public func all() async -> [GhostEvent] {
        loadIfNeeded()
        return events.reversed()
    }

    public func deleteAll() async throws {
        events.removeAll()
        fingerprints.removeAll()
        loaded = true
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func delete(source: SourceID) async throws {
        loadIfNeeded()
        events.removeAll { $0.source.id == source }
        fingerprints = Set(events.map(\.fingerprint))
        try save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? AccessLog.decoder.decode([GhostEvent].self, from: data) else { return }
        events = saved
        fingerprints = Set(saved.map(\.fingerprint))
    }

    private func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AccessLog.encoder.encode(events).write(to: fileURL, options: .atomic)
    }
}
