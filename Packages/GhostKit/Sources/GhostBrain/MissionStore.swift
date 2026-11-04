import Foundation

/// Stockage durable des missions, décisions et du registre d'événements traités.
///
/// Garanties :
/// - une transaction (`commit`) est copiée, validée puis écrite **atomiquement** ;
///   l'état en mémoire n'avance qu'après réussite sur disque ;
/// - mission, décision et registre d'événements sont écrits **ensemble** : après une
///   panne, un événement est soit entièrement traité, soit pas du tout ;
/// - un fichier illisible ou d'une version plus récente n'est jamais écrasé.
public actor MissionStore {
    private let url: URL?
    private var state: BrainState?
    /// Pour les tests : nombre d'écritures à faire échouer.
    var failNextSaves = 0

    public init(url: URL?) { self.url = url }

    public func snapshot() throws -> BrainState {
        if let state { return state }
        let loaded = try load()
        state = loaded
        return loaded
    }

    public func commit(_ transform: (inout BrainState) throws -> Void) throws {
        var candidate = try snapshot()
        try transform(&candidate)
        try write(candidate)
        state = candidate
    }

    public func reset() throws {
        let fresh = BrainState()
        try write(fresh)
        state = fresh
    }

    func setFailNextSaves(_ n: Int) { failNextSaves = n }

    // MARK: Disque

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func load() throws -> BrainState {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return BrainState() }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw BrainError.storage("lecture impossible (\(error.localizedDescription)) ; fichier conservé") }
        struct Header: Decodable { var schemaVersion: Int }
        guard let header = try? Self.decoder().decode(Header.self, from: data) else {
            throw BrainError.storage("fichier des missions illisible ; il est conservé tel quel")
        }
        if header.schemaVersion > BrainSchema.version {
            throw BrainError.storage("fichier créé par une version plus récente de GHOST ; ouverture refusée pour préserver les données")
        }
        do { return try Self.decoder().decode(BrainState.self, from: data) }
        catch { throw BrainError.storage("fichier des missions illisible ; il est conservé tel quel") }
    }

    private func write(_ state: BrainState) throws {
        if failNextSaves > 0 { failNextSaves -= 1; throw BrainError.storage("écriture simulée en échec") }
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(state).write(to: url, options: .atomic)
        } catch {
            throw BrainError.storage("écriture impossible : \(error.localizedDescription)")
        }
    }
}
