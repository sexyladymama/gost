import Foundation

/// Persistance de l'état interne des sources (curseur e-mail, instantané de dossier).
public protocol SourceStateStore: Sendable {
    func load(_ key: String) -> Data?
    func save(_ data: Data, for key: String)
    func remove(_ key: String)
    func removeAll()
}

public final class InMemorySourceStateStore: SourceStateStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(_ key: String) -> Data? { lock.withLock { values[key] } }
    public func save(_ data: Data, for key: String) { lock.withLock { values[key] = data } }
    public func remove(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
    public func removeAll() { lock.withLock { values.removeAll() } }
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

    public func load(_ key: String) -> Data? { lock.withLock { try? Data(contentsOf: url(key)) } }

    public func save(_ data: Data, for key: String) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url(key), options: .atomic)
        }
    }

    public func remove(_ key: String) { lock.withLock { try? FileManager.default.removeItem(at: url(key)) } }

    public func removeAll() { lock.withLock { try? FileManager.default.removeItem(at: directory) } }
}
