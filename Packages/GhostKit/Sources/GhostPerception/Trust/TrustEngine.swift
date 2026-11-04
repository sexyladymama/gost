import Foundation

/// Permission accordée explicitement par l'utilisateur à une source.
public enum Permission: String, Codable, Sendable {
    /// Lire les nouveaux e-mails d'un compte (lecture seule).
    case readMail
    /// Observer les métadonnées des fichiers d'un dossier choisi (lecture seule).
    case watchFolder
    /// Envoyer des données **masquées** à un modèle externe (GHOST BRAIN). Désactivée par défaut.
    case callExternalModel
}

/// Autorisation accordée par l'utilisateur.
public struct Grant: Codable, Hashable, Sendable {
    public var sourceID: SourceID
    public var permission: Permission
    /// Périmètre : chemin du dossier, ou compte e-mail.
    public var scope: String
    public var grantedAt: Date

    public init(sourceID: SourceID, permission: Permission, scope: String, grantedAt: Date) {
        self.sourceID = sourceID
        self.permission = permission
        self.scope = scope
        self.grantedAt = grantedAt
    }
}

/// Vérifie les autorisations **avant tout accès** à une source.
///
/// - Une source sans autorisation ne peut rien lire.
/// - Un dossier ne peut être inspecté que s'il se trouve à l'intérieur du
///   dossier explicitement choisi par l'utilisateur.
/// - Chaque vérification (accordée ou refusée) est inscrite dans l'``AccessLog``.
public actor TrustEngine {
    private var grants: [SourceID: Grant] = [:]
    private let storeURL: URL?
    public let accessLog: AccessLog
    private let clock: @Sendable () -> Date

    /// - Parameter storeURL: fichier JSON de persistance des autorisations
    ///   (`nil` : en mémoire uniquement).
    public init(accessLog: AccessLog, storeURL: URL? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.accessLog = accessLog
        self.storeURL = storeURL
        self.clock = clock
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let saved = try? AccessLog.decoder.decode([Grant].self, from: data) {
            grants = Dictionary(saved.map { ($0.sourceID, $0) }, uniquingKeysWith: { $1 })
        }
    }

    // MARK: - Gestion des autorisations

    /// Accorde une autorisation (action explicite de l'utilisateur).
    public func grant(_ sourceID: SourceID, permission: Permission, scope: String) async {
        let grant = Grant(sourceID: sourceID, permission: permission, scope: scope, grantedAt: clock())
        grants[sourceID] = grant
        persist()
        await accessLog.record(sourceID, operation: "trust.grant", target: scope, outcome: .allowed)
    }

    /// Révoque l'autorisation d'une source.
    public func revoke(_ sourceID: SourceID) async {
        let scope = grants[sourceID]?.scope ?? "-"
        grants[sourceID] = nil
        persist()
        await accessLog.record(sourceID, operation: "trust.revoke", target: scope, outcome: .allowed)
    }

    public func grant(for sourceID: SourceID) -> Grant? { grants[sourceID] }

    public func allGrants() -> [Grant] { Array(grants.values) }

    public func isAuthorized(_ sourceID: SourceID, _ permission: Permission) -> Bool {
        grants[sourceID]?.permission == permission
    }

    // MARK: - Contrôles d'accès

    /// Exige une autorisation ; journalise l'accès.
    ///
    /// - Throws: ``PerceptionError/notAuthorized(source:resource:)``.
    public func require(_ sourceID: SourceID, _ permission: Permission,
                        operation: String, target: String) async throws {
        guard isAuthorized(sourceID, permission) else {
            await accessLog.record(sourceID, operation: operation, target: target,
                                   outcome: .denied, detail: "aucune autorisation \(permission.rawValue)")
            throw PerceptionError.notAuthorized(source: sourceID, resource: target)
        }
        await accessLog.record(sourceID, operation: operation, target: target, outcome: .allowed)
    }

    /// Exige que `url` soit le dossier autorisé de la source, ou se trouve à
    /// l'intérieur. Les liens symboliques sont résolus avant comparaison,
    /// pour qu'un lien ne permette pas de sortir du périmètre.
    ///
    /// - Returns: le chemin résolu, à utiliser pour l'accès.
    @discardableResult
    public func requireFolderAccess(_ url: URL, for sourceID: SourceID,
                                    operation: String = "folder.scan") async throws -> URL {
        let resolved = Self.canonical(url)
        guard let grant = grants[sourceID], grant.permission == .watchFolder,
              Self.isInside(resolved, root: Self.canonical(URL(fileURLWithPath: grant.scope))) else {
            await accessLog.record(sourceID, operation: operation, target: resolved.path,
                                   outcome: .denied, detail: "hors du dossier autorisé")
            throw PerceptionError.notAuthorized(source: sourceID, resource: resolved.path)
        }
        await accessLog.record(sourceID, operation: operation, target: resolved.path, outcome: .allowed)
        return resolved
    }

    /// Variante synchrone, sans journalisation, pour vérifier chaque élément
    /// d'un parcours déjà autorisé (le parcours lui-même est journalisé).
    public func isInsideAuthorizedFolder(_ url: URL, for sourceID: SourceID) -> Bool {
        guard let grant = grants[sourceID], grant.permission == .watchFolder else { return false }
        return Self.isInside(Self.canonical(url), root: Self.canonical(URL(fileURLWithPath: grant.scope)))
    }

    // MARK: - Utilitaires

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.pathComponents
        let rootPath = root.pathComponents
        return path.count >= rootPath.count && Array(path.prefix(rootPath.count)) == rootPath
    }

    private func persist() {
        guard let storeURL else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? AccessLog.encoder.encode(Array(grants.values)) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
