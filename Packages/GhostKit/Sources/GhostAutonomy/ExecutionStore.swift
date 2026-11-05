import Foundation

/// Checkpoints atomiques : une erreur ne fait pas avancer l'état en mémoire.
public actor ExecutionStore {
    private let url: URL?
    private let profileID: String
    private var cached: ExecutionArchive?
    private var failSaves = 0
    public init(url: URL?, profileID: String) { self.url = url; self.profileID = profileID }
    public func snapshot() throws -> ExecutionArchive {
        if let cached { return cached }
        guard let url else { let empty = ExecutionArchive(profileID: profileID); cached = empty; return empty }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            let empty = ExecutionArchive(profileID: profileID); cached = empty; return empty
        }
        do {
            let archive = try JSONDecoder().decode(ExecutionArchive.self, from: data)
            guard archive.schemaVersion == 1, archive.profileID == profileID,
                  archive.executions.allSatisfy({ $0.key == $0.value.id && $0.value.profileID == profileID }) else {
                throw ExecutionError.storage("Version ou profil de checkpoint incompatible ; fichier conservé.")
            }
            cached = archive; return archive
        } catch { throw ExecutionError.storage("Checkpoint illisible ou incompatible ; aucune donnée n'a été écrasée.") }
    }
    public func commit(_ body: (inout ExecutionArchive) throws -> Void) throws {
        try Task.checkCancellation()
        var candidate = try snapshot(); try body(&candidate)
        try Task.checkCancellation()
        if failSaves > 0 { failSaves -= 1; throw ExecutionError.storage("Échec de checkpoint injecté pour le test.") }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(candidate).write(to: url, options: .atomic)
        }
        cached = candidate
    }
    func failNextSave() { failSaves += 1 }
}
