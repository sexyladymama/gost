import Foundation

/// Trace d'un accès (ou d'une tentative d'accès) à une source.
///
/// Le journal ne contient jamais de contenu : uniquement qui, quoi, où, quand
/// et le résultat.
public struct AccessRecord: Codable, Hashable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case allowed, denied, failed
    }
    public var id: UUID
    public var date: Date
    public var sourceID: SourceID
    /// Opération, ex. `gmail.messages.list`, `folder.scan`, `network.request`.
    public var operation: String
    /// Cible de l'accès : hôte réseau ou chemin du dossier.
    public var target: String
    public var outcome: Outcome
    public var detail: String?

    public init(id: UUID = UUID(), date: Date, sourceID: SourceID, operation: String,
                target: String, outcome: Outcome, detail: String? = nil) {
        self.id = id
        self.date = date
        self.sourceID = sourceID
        self.operation = operation
        self.target = target
        self.outcome = outcome
        self.detail = detail
    }
}

/// Journal des accès aux sources.
///
/// Persisté au format JSON Lines (une ligne par accès) si un fichier est
/// fourni ; sinon conservé en mémoire (tests).
public actor AccessLog {
    private var records: [AccessRecord] = []
    private let fileURL: URL?
    private let clock: @Sendable () -> Date
    private let maxInMemory = 2_000

    public init(fileURL: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.clock = clock
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = Self.decoder
            records = data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? decoder.decode(AccessRecord.self, from: Data($0))
            }.suffix(maxInMemory).map { $0 }
        }
    }

    /// Enregistre un accès.
    @discardableResult
    public func record(_ sourceID: SourceID, operation: String, target: String,
                       outcome: AccessRecord.Outcome, detail: String? = nil) -> AccessRecord {
        let entry = AccessRecord(date: clock(), sourceID: sourceID, operation: operation,
                                 target: target, outcome: outcome, detail: detail)
        records.append(entry)
        if records.count > maxInMemory { records.removeFirst(records.count - maxInMemory) }
        append(entry)
        return entry
    }

    /// Accès enregistrés, du plus ancien au plus récent.
    public func all() -> [AccessRecord] { records }

    /// Efface le journal (mémoire et disque).
    public func clear() {
        records.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func append(_ entry: AccessRecord) {
        guard let fileURL, var line = try? Self.encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            _ = manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
