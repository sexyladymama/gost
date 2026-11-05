import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DirectoryIdentity: Sendable { var device: UInt64; var inode: UInt64 }
struct ExecutionGrant: Sendable {
    var namespace: String
    var input: URL
    var output: URL
    var inputIdentity: DirectoryIdentity
    var outputIdentity: DirectoryIdentity
    var sensitiveApproved: Bool
}
public enum AuthorizationDecision: Equatable, Sendable { case allowed, approvalRequired, denied }

/// Autorisations de contenu et d'écriture indépendantes des permissions de perception.
/// Les opérations de fichiers bornées s'exécutent sans suspension au sein de cet actor.
public actor ExecutionTrust {
    private var grants: [String: ExecutionGrant] = [:]
    public init() {}
    public func authorize(executionID: String, namespace: String, input: URL, output: URL,
                          allowContentRead: Bool, allowCreate: Bool, sensitiveApproved: Bool = false) throws {
        guard allowContentRead, allowCreate else { throw ExecutionError.denied("La lecture du contenu et la création en sortie nécessitent un accord explicite.") }
        // Canonicalisation au seul moment du consentement (notamment /var → /private/var
        // sur macOS). Les accès suivants utilisent ces chemins figés et leurs inodes.
        let input = try SecureFiles.canonical(input), output = try SecureFiles.canonical(output)
        let i = try SecureFiles.identity(input), o = try SecureFiles.identity(output)
        guard i.device != o.device || i.inode != o.inode else { throw ExecutionError.denied("Choisissez un dossier de sortie distinct des sources.") }
        grants[executionID] = ExecutionGrant(namespace: namespace, input: input, output: output,
            inputIdentity: i, outputIdentity: o, sensitiveApproved: sensitiveApproved)
    }
    public func revoke(_ executionID: String) { grants[executionID] = nil }
    public func approveSensitive(_ executionID: String, namespace: String) throws {
        guard grants[executionID]?.namespace == namespace else { throw ExecutionError.denied("Autorisation absente ou révoquée.") }
        grants[executionID]?.sensitiveApproved = true
    }
    public func revokeAll() { grants.removeAll() }
    public func decision(executionID: String, namespace: String, risk: ToolRisk) -> AuthorizationDecision {
        guard let grant = grants[executionID], grant.namespace == namespace else { return .denied }
        if risk == .external { return .denied } // aucun outil externe enregistré dans cette version
        if risk == .sensitive && !grant.sensitiveApproved { return .approvalRequired }
        return .allowed
    }
    func perform<T: Sendable>(_ executionID: String, namespace: String, risk: ToolRisk = .low,
                              _ work: @Sendable (ExecutionGrant) throws -> T) throws -> T {
        try Task.checkCancellation()
        switch decision(executionID: executionID, namespace: namespace, risk: risk) {
        case .denied: throw ExecutionError.denied("Autorisation d'exécution absente, révoquée ou dans un autre contexte.")
        case .approvalRequired: throw ExecutionError.approval("Ces données sont déclarées sensibles : validation explicite requise.")
        case .allowed: break
        }
        guard let grant = grants[executionID] else { throw ExecutionError.denied("Autorisation révoquée.") }
        return try work(grant)
    }
}

enum SecureFiles {
    static let maxBytes = 20 * 1_024 * 1_024
    /// Chemin canonique d'un dossier choisi par l'utilisateur (ex. `/var` → `/private/var`).
    /// Calculé à partir du descripteur ouvert : `realpath` échoue dans le bac à sable (parents illisibles).
    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw ExecutionError.denied("Dossier inexistant ou inaccessible.") }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)   // le chemin choisi dans le sélecteur peut passer par un lien système
        guard fd >= 0 else { throw ExecutionError.denied("Dossier inexistant ou inaccessible.") }
        defer { close(fd) }
        return URL(fileURLWithPath: try path(of: fd), isDirectory: true)
    }
    static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name.utf8.count <= 240 else { throw ExecutionError.denied("Chemin relatif invalide ou hors périmètre.") }
    }
    /// Chemin réel d'un descripteur déjà ouvert. Fonctionne dans le bac à sable de macOS, contrairement
    /// à `realpath` qui doit parcourir des dossiers parents que l'application n'a pas le droit de lire.
    static func path(of fd: Int32) throws -> String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw ExecutionError.denied("Chemin du dossier indisponible.") }
        return String(cString: buffer)
        #else
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = readlink("/proc/self/fd/\(fd)", &buffer, buffer.count - 1)
        guard n > 0 else { throw ExecutionError.denied("Chemin du dossier indisponible.") }
        buffer[n] = 0
        return String(cString: buffer)
        #endif
    }
    /// Ouverture **directe** du dossier autorisé. Le bac à sable ne donne accès qu'au dossier choisi et à son contenu,
    /// pas à ses parents : un parcours depuis « / » échoue (reproduit sous profil restrictif, même avec O_EVTONLY).
    /// La protection contre les liens et les échanges de dossier repose sur trois contrôles :
    /// 1. le dernier composant n'est jamais suivi s'il s'agit d'un lien (`O_NOFOLLOW`) ;
    /// 2. le chemin réel du descripteur doit être exactement le chemin canonique autorisé
    ///    (un parent remplacé par un lien est détecté) ;
    /// 3. l'identité (périphérique, inode) doit être celle du dossier autorisé (un dossier échangé est détecté).
    static func directory(_ url: URL, expected: DirectoryIdentity? = nil) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw ExecutionError.denied("Dossier invalide.") }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExecutionError.denied("Dossier inaccessible ou lien symbolique refusé (code \(errno)).") }
        if expected != nil, (try? path(of: fd)) != url.path {
            close(fd); throw ExecutionError.denied("Le dossier autorisé a été redirigé ou déplacé.")
        }
        if let expected {
            var info = stat()
            guard fstat(fd, &info) == 0, UInt64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode else {
                close(fd); throw ExecutionError.denied("Le dossier autorisé a été remplacé.")
            }
        }
        return fd
    }
    static func identity(_ url: URL) throws -> DirectoryIdentity {
        let fd = try directory(url); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ExecutionError.denied("Dossier inaccessible.") }
        return DirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
    static func list(_ grant: ExecutionGrant) throws -> [String] {
        let root = try directory(grant.input, expected: grant.inputIdentity); defer { close(root) }
        guard let stream = fdopendir(dup(root)) else { throw ExecutionError.denied("Lecture du dossier impossible.") }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name.hasPrefix(".") { continue }
            var info = stat()
            guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { continue }
            guard names.count < 100 else { throw ExecutionError.invalid("Plus de 100 fichiers : réduisez le dossier de cette mission.") }
            guard ["csv", "tsv"].contains((name as NSString).pathExtension.lowercased()) else {
                throw ExecutionError.approval("Format non pris en charge : \(name). Cette version exige uniquement des CSV/TSV commerciaux.")
            }
            names.append(name)
        }
        return names.sorted()
    }
    static func read(_ name: String, grant: ExecutionGrant, output: Bool = false) throws -> Data {
        try self.name(name)
        let root = try directory(output ? grant.output : grant.input, expected: output ? grant.outputIdentity : grant.inputIdentity)
        defer { close(root) }
        let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ExecutionError.denied("Fichier absent, inaccessible ou lien refusé : \(name).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maxBytes else { throw ExecutionError.denied("Fichier non régulier, partagé ou trop volumineux.") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let n = buffer.withUnsafeMutableBytes { ptr in
                #if canImport(Darwin)
                return Darwin.read(fd, ptr.baseAddress, ptr.count)
                #else
                return Glibc.read(fd, ptr.baseAddress, ptr.count)
                #endif
            }
            guard n >= 0 else { throw ExecutionError.transient("Lecture interrompue.") }
            if n == 0 { break }
            result.append(contentsOf: buffer.prefix(n))
            guard result.count <= maxBytes else { throw ExecutionError.invalid("Fichier trop volumineux.") }
        }
        return result
    }
    static func save(_ bytes: Data, name: String, grant: ExecutionGrant) throws -> ArtifactReceipt {
        try self.name(name)
        guard bytes.count <= maxBytes else { throw ExecutionError.invalid("Résultat trop volumineux.") }
        let hash = ExecutionIdentity.hash(bytes)
        let root = try directory(grant.output, expected: grant.outputIdentity); defer { close(root) }
        let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        if fd < 0 {
            guard errno == EEXIST else { throw ExecutionError.transient("Impossible de créer le résultat dans le dossier autorisé.") }
            let existing = try read(name, grant: grant, output: true)
            guard ExecutionIdentity.hash(existing) == hash else {
                throw ExecutionError.approval("Un fichier différent ou incomplet existe déjà. Autorisez une nouvelle version ; aucun fichier n'a été écrasé.")
            }
            return ArtifactReceipt(fileName: name, hash: hash, bytes: bytes.count, recovered: true)
        }
        defer { close(fd) }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let n = bytes.withUnsafeBytes { ptr in
                #if canImport(Darwin)
                return Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), min(64 * 1_024, bytes.count - offset))
                #else
                return Glibc.write(fd, ptr.baseAddress!.advanced(by: offset), min(64 * 1_024, bytes.count - offset))
                #endif
            }
            guard n > 0 else { throw ExecutionError.transient("Écriture interrompue ; le fichier partiel sera soumis à validation avant reprise.") }
            offset += n
        }
        guard fsync(fd) == 0, fsync(root) == 0 else { throw ExecutionError.transient("La synchronisation sur disque a échoué.") }
        return ArtifactReceipt(fileName: name, hash: hash, bytes: bytes.count, recovered: false)
    }
}
