import Foundation

/// Source dossier : détecte les fichiers créés, modifiés ou supprimés dans
/// **un dossier explicitement choisi par l'utilisateur**.
///
/// - Vérifie, avant chaque parcours, que le dossier est autorisé par le
///   ``TrustEngine`` ; chaque sous-dossier est revérifié avant d'être ouvert.
/// - Ne lit que des métadonnées (nom, type, taille, dates), jamais le contenu.
/// - Ne suit pas les liens symboliques, ignore les fichiers cachés et temporaires.
/// - Profondeur et nombre d'éléments limités.
/// - Le premier parcours établit une référence : les fichiers déjà présents
///   ne sont pas signalés comme nouveaux.
/// - N'écrit, ne déplace et ne supprime jamais rien.
public actor FolderSource: PerceptionSource {
    struct Entry: Codable, Hashable {
        var size: Int64
        var modifiedAt: Date
        var createdAt: Date?
    }

    public nonisolated let descriptor: EventSource
    public nonisolated let pollInterval: TimeInterval
    public nonisolated let root: URL
    private let trust: TrustEngine
    private let stateStore: SourceStateStore
    private let fileSystem: FileSystemReader
    private let maxDepth: Int
    private let maxEntries: Int
    private var snapshot: [String: Entry]?

    public init(id: SourceID = SourceID("folder"), root: URL, trust: TrustEngine,
                stateStore: SourceStateStore, fileSystem: FileSystemReader = LocalFileSystem(),
                pollInterval: TimeInterval = 5, maxDepth: Int = 4, maxEntries: Int = 5_000) {
        self.descriptor = EventSource(id: id, kind: .folder, displayName: "Dossier : \(root.lastPathComponent)")
        self.pollInterval = pollInterval
        self.root = root
        self.trust = trust
        self.stateStore = stateStore
        self.fileSystem = fileSystem
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    /// Une référence par dossier : changer de dossier ne compare pas deux dossiers différents.
    private var stateKey: String { "folder.\(descriptor.id.rawValue).\(StableHash.fnv1a(root.standardizedFileURL.path))" }

    public func poll() async throws -> [RawObservation] {
        let authorizedRoot = try await trust.requireFolderAccess(root, for: descriptor.id)
        var current: [String: Entry] = [:]
        var metadata: [String: FileMetadata] = [:]
        do {
            try await scan(authorizedRoot, base: authorizedRoot, depth: 0, into: &current, metadata: &metadata)
        } catch let error as PerceptionError {
            throw error
        } catch {
            throw PerceptionError.connectionFailed("dossier inaccessible (\(error.localizedDescription))")
        }

        let previous = loadSnapshot()
        snapshot = current
        if let data = try? JSONEncoder().encode(current) { stateStore.save(data, for: stateKey) }
        guard let previous else { return [] } // premier parcours : référence

        var changes: [FileChange] = []
        for (path, entry) in current.sorted(by: { $0.key < $1.key }) {
            guard let meta = metadata[path] else { continue }
            if let old = previous[path] {
                if old.size != entry.size || old.modifiedAt != entry.modifiedAt {
                    changes.append(FileChange(kind: .modified, relativePath: path, metadata: meta))
                }
            } else {
                changes.append(FileChange(kind: .created, relativePath: path, metadata: meta))
            }
        }
        for (path, old) in previous.sorted(by: { $0.key < $1.key }) where current[path] == nil {
            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension
            changes.append(FileChange(kind: .deleted, relativePath: path, metadata: FileMetadata(
                name: name, fileExtension: ext, category: .from(extension: ext),
                size: old.size, modifiedAt: old.modifiedAt, createdAt: old.createdAt)))
        }
        return changes.map(RawObservation.file)
    }

    public func revokeAccess() async throws {}

    public func resetState() async {
        snapshot = nil
        stateStore.remove(stateKey)
    }

    // MARK: - Parcours

    private func scan(_ directory: URL, base: URL, depth: Int,
                      into entries: inout [String: Entry], metadata: inout [String: FileMetadata]) async throws {
        // Défense en profondeur : chaque dossier ouvert doit être dans le périmètre.
        guard await trust.isInsideAuthorizedFolder(directory, for: descriptor.id) else {
            throw PerceptionError.notAuthorized(source: descriptor.id, resource: directory.path)
        }
        for url in try fileSystem.contentsOfDirectory(at: directory).sorted(by: { $0.path < $1.path }) {
            guard entries.count < maxEntries else { return }
            let name = url.lastPathComponent
            guard !Self.isIgnored(name) else { continue }
            guard let attributes = try? fileSystem.attributes(at: url) else { continue }
            let ext = url.pathExtension
            switch attributes.type {
            case .directory where !FileCategory.packageExtensions.contains(ext.lowercased()):
                if depth + 1 < maxDepth {
                    try await scan(url, base: base, depth: depth + 1, into: &entries, metadata: &metadata)
                }
            case .file, .directory:
                let relative = Self.relativePath(of: url, base: base)
                entries[relative] = Entry(size: attributes.size, modifiedAt: attributes.modifiedAt,
                                          createdAt: attributes.createdAt)
                metadata[relative] = FileMetadata(name: name, fileExtension: ext, category: .from(extension: ext),
                                                  size: attributes.size, modifiedAt: attributes.modifiedAt,
                                                  createdAt: attributes.createdAt)
            case .symbolicLink, .other:
                continue // jamais suivis
            }
        }
    }

    static func isIgnored(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasPrefix(".~lock") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["tmp", "part", "crdownload", "download", "swp"].contains(ext)
    }

    static func relativePath(of url: URL, base: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        return components.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private func loadSnapshot() -> [String: Entry]? {
        if let snapshot { return snapshot }
        guard let data = stateStore.load(stateKey) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: data)
    }
}
