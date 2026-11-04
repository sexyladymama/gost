import Foundation

/// Attributs d'un élément du système de fichiers (jamais son contenu).
public struct FileAttributes: Sendable, Hashable {
    public enum ItemType: Sendable, Hashable { case file, directory, symbolicLink, other }
    public var type: ItemType
    public var size: Int64
    public var modifiedAt: Date
    public var createdAt: Date?

    public init(type: ItemType, size: Int64, modifiedAt: Date, createdAt: Date?) {
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}

/// Accès **en lecture seule aux métadonnées** du système de fichiers.
///
/// Volontairement, ce protocole n'offre aucune méthode pour lire le contenu,
/// écrire, déplacer ou supprimer un fichier.
public protocol FileSystemReader: Sendable {
    func contentsOfDirectory(at url: URL) throws -> [URL]
    /// Attributs sans suivre les liens symboliques.
    func attributes(at url: URL) throws -> FileAttributes
}

public struct LocalFileSystem: FileSystemReader {
    public init() {}

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }

    public func attributes(at url: URL) throws -> FileAttributes {
        // `attributesOfItem` ne suit pas les liens symboliques (lstat).
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type: FileAttributes.ItemType
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?: type = .file
        case .typeDirectory?: type = .directory
        case .typeSymbolicLink?: type = .symbolicLink
        default: type = .other
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return FileAttributes(type: type, size: size,
                              modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
                              createdAt: attributes[.creationDate] as? Date)
    }
}
