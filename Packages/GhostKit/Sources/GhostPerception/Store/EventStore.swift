import Foundation

/// Stockage des événements détectés.
///
/// Garantie : un événement n'est jamais enregistré deux fois. L'unicité est
/// assurée par ``GhostEvent/fingerprint`` (source + identifiant externe + version).
public protocol EventStore: Sendable {
    /// Enregistre les événements et renvoie **uniquement** ceux qui étaient nouveaux.
    func insert(_ events: [GhostEvent]) async throws -> [GhostEvent]
    func contains(fingerprint: String) async throws -> Bool
    /// Tous les événements, du plus récent au plus ancien.
    func all() async throws -> [GhostEvent]
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
        try loadIfNeeded()
        var candidate = events
        var known = fingerprints
        var inserted: [GhostEvent] = []
        for event in newEvents where !known.contains(event.fingerprint) {
            known.insert(event.fingerprint)
            candidate.append(event)
            inserted.append(event)
        }
        if candidate.count > capacity {
            candidate.removeFirst(candidate.count - capacity)
        }
        // La mémoire ne devient officielle qu'après l'écriture atomique réussie.
        if !inserted.isEmpty { try save(candidate) }
        events = candidate
        fingerprints = Set(candidate.map(\.fingerprint))
        return inserted
    }

    public func contains(fingerprint: String) async throws -> Bool {
        try loadIfNeeded()
        return fingerprints.contains(fingerprint)
    }

    public func all() async throws -> [GhostEvent] {
        try loadIfNeeded()
        return events.reversed()
    }

    public func deleteAll() async throws {
        if let fileURL {
            do { try FileManager.default.removeItem(at: fileURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
        events.removeAll()
        fingerprints.removeAll()
        loaded = true
    }

    public func delete(source: SourceID) async throws {
        try loadIfNeeded()
        let candidate = events.filter { $0.source.id != source }
        try save(candidate)
        events = candidate
        fingerprints = Set(candidate.map(\.fingerprint))
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard let fileURL else { loaded = true; return }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loaded = true
            return
        }
        do {
            let saved = try AccessLog.decoder.decode([GhostEvent].self, from: data)
            events = saved
            fingerprints = Set(saved.map(\.fingerprint))
            loaded = true
        } catch {
            throw PerceptionError.storageFailed("Le fichier d'événements est illisible. Il a été conservé ; aucune donnée ne sera écrasée.")
        }
    }

    private func save(_ candidate: [GhostEvent]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AccessLog.encoder.encode(candidate).write(to: fileURL, options: .atomic)
    }
}
