import Foundation

/// Execution checkpoints only. Knowledge remains in GhostContext; mission identity remains in Brain.
actor AgentStore {
    let url: URL?
    let profileID: String
    private var cached: AgentArchive?
    init(url: URL?, profileID: String) { self.url = url; self.profileID = profileID }
    func snapshot() throws -> AgentArchive {
        if let cached { return cached }
        guard let url else { let value = AgentArchive(profileID: profileID); cached = value; return value }
        do {
            let value = try JSONDecoder().decode(AgentArchive.self, from: Data(contentsOf: url))
            guard value.schemaVersion == 1, value.profileID == profileID,
                  value.sessions.allSatisfy({ $0.key == $0.value.id }) else { throw CoreError.storage("Checkpoint Core incompatible ; fichier conservé.") }
            cached = value; return value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let value = AgentArchive(profileID: profileID); cached = value; return value
        } catch { throw CoreError.storage("Checkpoint Core illisible ou incompatible ; fichier conservé.") }
    }
    @discardableResult func commit<T: Sendable>(_ change: (inout AgentArchive) throws -> T) throws -> T {
        try Task.checkCancellation()
        var value = try snapshot(); let result = try change(&value)
        try Task.checkCancellation()
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(value).write(to: url, options: .atomic)
        }
        cached = value; return result
    }
}
