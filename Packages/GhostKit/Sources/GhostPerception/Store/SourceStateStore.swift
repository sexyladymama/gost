import Foundation

/// Persistance de l'état interne des sources (curseur e-mail, instantané de dossier).
public protocol SourceStateStore: Sendable {
    func load(_ key: String) throws -> Data?
    func save(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
    func removeAll() throws
}

public final class InMemorySourceStateStore: SourceStateStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    public func save(_ data: Data, for key: String) throws { lock.withLock { values[key] = data } }
    public func remove(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    public func removeAll() throws { lock.withLock { values.removeAll() } }
}

/// Un fichier JSON par clé dans un répertoire du profil.
public final class FileSourceStateStore: SourceStateStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    public func load(_ key: String) throws -> Data? {
        try lock.withLock {
            do { return try Data(contentsOf: url(key)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
    }

    public func save(_ data: Data, for key: String) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(key), options: .atomic)
        }
    }

    public func remove(_ key: String) throws { try removeIfPresent(url(key)) }

    public func removeAll() throws { try removeIfPresent(directory) }

    private func removeIfPresent(_ url: URL) throws {
        try lock.withLock {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
    }
}
