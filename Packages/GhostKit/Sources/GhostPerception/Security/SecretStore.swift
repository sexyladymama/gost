import Foundation
#if canImport(Security)
import Security
#endif

/// Stockage de secrets (jetons OAuth).
public protocol SecretStore: Sendable {
    func load(_ key: String) throws -> Data?
    func save(_ data: Data, for key: String) throws
    func delete(_ key: String) throws
}

/// Stockage en mémoire, réservé aux tests et au mode simulation.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    public func save(_ data: Data, for key: String) throws { lock.withLock { values[key] = data } }
    public func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

#if canImport(Security)
/// Stockage dans le Trousseau macOS (éléments « mot de passe générique »),
/// accessible uniquement lorsque la session est déverrouillée, jamais
/// synchronisé avec iCloud.
public struct KeychainSecretStore: SecretStore {
    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    private let service: String
    /// Séparation par utilisateur : chaque profil GHOST a son propre compte.
    private let profileID: String

    public init(service: String = "app.ghost.shell", profileID: String) {
        self.service = service
        self.profileID = profileID
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(profileID).\(key)"]
    }

    public func load(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    public func save(_ data: Data, for key: String) throws {
        let q = query(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
#endif
