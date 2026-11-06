import Foundation
import GhostBrain
import GhostPerception

public enum ExecutionState: String, Codable, CaseIterable, Sendable {
    case pending, authorized, running, waitingForApproval = "waiting_for_approval", paused, verifying, completed, failed, cancelled
    public var isTerminal: Bool { [.completed, .cancelled].contains(self) }
    public func canMove(to next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .pending: return [.authorized, .waitingForApproval, .cancelled].contains(next)
        case .authorized: return [.running, .paused, .cancelled, .waitingForApproval, .failed].contains(next)
        case .running: return [.verifying, .paused, .waitingForApproval, .failed, .cancelled].contains(next)
        case .verifying: return [.running, .completed, .failed, .paused, .waitingForApproval, .cancelled].contains(next)
        case .paused, .waitingForApproval, .failed: return [.authorized, .cancelled, .waitingForApproval].contains(next)
        case .completed, .cancelled: return false
        }
    }
    public var label: String {
        switch self {
        case .pending: return "En attente"; case .authorized: return "Autorisée"; case .running: return "En cours"
        case .waitingForApproval: return "Validation requise"; case .paused: return "En pause"; case .verifying: return "Vérification"
        case .completed: return "Livrable local vérifié"; case .failed: return "Échec"; case .cancelled: return "Annulée"
        }
    }
}
public enum ExecutionCapability: String, Codable, Sendable { case local, cloud }
public enum ToolRisk: String, Codable, Sendable { case low, sensitive, external }
public enum ToolID: String, Codable, CaseIterable, Sendable {
    case readAuthorizedFile = "ReadAuthorizedFile", listAuthorizedFiles = "ListAuthorizedFiles"
    case createDocument = "CreateDocument", createSpreadsheet = "CreateSpreadsheet", saveArtifact = "SaveArtifact"
    case verifyArtifact = "VerifyArtifact", notifyUser = "NotifyUser"
}
/// Déclaration d'un outil du catalogue fermé. Rien n'est évalué à partir d'un nom fourni par un modèle :
/// un identifiant absent du catalogue est refusé (`ToolID(rawValue:)` renvoie nil).
public struct ToolDefinition: Sendable {
    public var id: ToolID
    public var description: String
    public var inputSchema: String
    public var outputSchema: String
    /// Permissions d'exécution exigées (accordées séparément de la perception).
    public var permissions: [String]
    /// Niveau de risque du Trust : `.low` (niveau 1), `.sensitive` (niveau 2), `.external` (niveau 3).
    public var risk: ToolRisk
    public var capability: ExecutionCapability
}
public enum ToolCatalog {
    public static let tools: [ToolDefinition] = [
        ToolDefinition(id: .listAuthorizedFiles, description: "Liste les CSV/TSV (100 au plus) du dossier source autorisé, sans suivre de lien symbolique.",
            inputSchema: "Aucun argument : le dossier est fixé par l'autorisation de cette exécution.",
            outputSchema: "Liste triée de noms de fichiers (jamais de chemin).",
            permissions: ["read_content"], risk: .low, capability: .local),
        ToolDefinition(id: .readAuthorizedFile, description: "Lit les fichiers listés (20 Mo au total, UTF-8) et calcule leur empreinte SHA-256.",
            inputSchema: "Noms issus de ListAuthorizedFiles ; un chemin, « .. » ou « / » est refusé.",
            outputSchema: "Par fichier : nom, empreinte SHA-256, texte UTF-8.",
            permissions: ["read_content"], risk: .low, capability: .local),
        ToolDefinition(id: .createDocument, description: "Prépare en mémoire un document texte UTF-8 (rien n'est écrit sur le disque).",
            inputSchema: "Texte UTF-8 non vide, 20 Mo au plus.",
            outputSchema: "Octets du document en mémoire.",
            permissions: [], risk: .low, capability: .local),
        ToolDefinition(id: .createSpreadsheet, description: "Construit un classeur XLSX natif à partir des lignes commerciales lues (formules SUM et quantité × prix).",
            inputSchema: "Sources lues, en-tête exact produit,quantite,prix_unitaire, 5 000 lignes au plus ; aucune formule venant d'une source.",
            outputSchema: "Octets XLSX en mémoire et lignes normalisées en centimes entiers.",
            permissions: [], risk: .low, capability: .local),
        ToolDefinition(id: .saveArtifact, description: "Crée un NOUVEAU fichier dans le dossier de sortie autorisé ; n'écrase jamais.",
            inputSchema: "Artefact préparé ; nom imposé par l'exécution (GHOST-<id>-v<n>.xlsx).",
            outputSchema: "Reçu : nom, empreinte SHA-256, taille, indicateur de reprise.",
            permissions: ["create_output"], risk: .low, capability: .local),
        ToolDefinition(id: .verifyArtifact, description: "Relit le fichier enregistré et contrôle paquet, XML, cellules, formules, totaux et provenance.",
            inputSchema: "Reçu de sauvegarde dont le nom est celui attendu.",
            outputSchema: "Rapport : passed, failed, warning ou needs_review, avec contrôles et problèmes.",
            permissions: ["read_output"], risk: .low, capability: .local),
        ToolDefinition(id: .notifyUser, description: "Prépare le message de fin, uniquement après une vérification réussie ; aucun envoi externe.",
            inputSchema: "Rapport de vérification passed et reçu du fichier.",
            outputSchema: "Texte du message affiché dans GHOST.",
            permissions: [], risk: .low, capability: .local)
    ]
    public static func definition(_ id: ToolID) -> ToolDefinition { tools.first { $0.id == id }! }
}

/// Où une opération peut s'exécuter. Un exécuteur cloud ne pilote jamais une application du Mac :
/// il ne peut traiter que des opérations sans dépendance à l'environnement local.
public protocol ExecutionBackend: Sendable {
    var capability: ExecutionCapability { get }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    func supports(_ tool: ToolID) -> Bool
}
public struct LocalExecutionBackend: ExecutionBackend {
    public init() {}
    public var capability: ExecutionCapability { .local }
    public var isAvailable: Bool { true }
    public var unavailableReason: String? { nil }
    public func supports(_ tool: ToolID) -> Bool { ToolCatalog.definition(tool).capability == .local }
}
/// Interface préparée, volontairement indisponible : aucune infrastructure cloud n'existe dans cette version.
public struct CloudExecutionBackend: ExecutionBackend {
    public init() {}
    public var capability: ExecutionCapability { .cloud }
    public var isAvailable: Bool { false }
    public var unavailableReason: String? { "Aucun exécuteur cloud n'existe dans cette version : GHOST n'exécute que localement, et un serveur ne peut jamais contrôler une application du Mac, surtout éteint." }
    public func supports(_ tool: ToolID) -> Bool { false }
}
public enum VerificationStatus: String, Codable, Sendable { case passed, failed, warning, needsReview = "needs_review" }
public struct VerificationReport: Codable, Sendable, Equatable {
    public var status: VerificationStatus
    public var checks: [String]
    public var problems: [String]
    public var artifactHash: String?
    public var verifiedAt: Date
}
public struct SalesRecord: Codable, Sendable, Equatable {
    public var product: String
    public var quantity: Int64
    public var unitCents: Int64
    public var source: String
    public var sourceRow: Int
    public var totalCents: Int64 { quantity * unitCents }
}
public struct InputReceipt: Codable, Sendable {
    public var name: String
    public var hash: String
    public var text: String
}
public struct ExecutionOperation: Codable, Sendable, Identifiable {
    public var id: String
    public var tool: ToolID
    public var dependsOn: [String]
    public var status: String = "pending"
    public var attempts: Int = 0
    public var detail: String?
}
public struct ExecutionLog: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var operationID: String?
    public var message: String
}
public struct ArtifactReceipt: Codable, Sendable, Equatable {
    public var fileName: String
    public var hash: String
    public var bytes: Int
    public var recovered: Bool
}
public struct ExecutionContext: Codable, Sendable, Identifiable {
    public var id: String
    public var profileID: String
    public var mission: Mission
    public var binding: String
    public var state: ExecutionState
    public var capability: ExecutionCapability = .local
    public var operations: [ExecutionOperation]
    public var inputNames: [String] = []
    public var inputs: [InputReceipt] = []
    public var records: [SalesRecord] = []
    public var stagedArtifact: Data?
    public var artifact: ArtifactReceipt?
    public var verification: VerificationReport?
    public var notification: String?
    public var error: String?
    public var approval: String?
    public var approvalKind: String?
    public var declaredSensitive = false
    public var inputPath: String?
    public var outputPath: String?
    public var outputVersion = 1
    public var brainReported = false
    public var history: [ExecutionLog] = []
    public var createdAt: Date
    public var updatedAt: Date
    public var progress: Double { Double(operations.filter { $0.status == "completed" }.count) / Double(max(1, operations.count)) }
    public var outputName: String { "GHOST-\(id.prefix(12))-v\(outputVersion).xlsx" }
}
public struct ExecutionArchive: Codable, Sendable {
    public var schemaVersion = 1
    public var profileID: String
    public var executions: [String: ExecutionContext] = [:]
}
public enum ExecutionError: Error, LocalizedError, Sendable {
    case denied(String), invalid(String), approval(String), transient(String), storage(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .denied(let s), .invalid(let s), .approval(let s), .transient(let s), .storage(let s): return s
        case .cancelled: return "Exécution interrompue."
        }
    }
}
public enum ExecutionIdentity {
    public static func hash(_ data: Data) -> String { Digest.sha256(data).map { String(format: "%02x", $0) }.joined() }
    public static func binding(_ mission: Mission) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return hash(try encoder.encode(mission.goal) + Data((mission.namespace + "|" + mission.workKind.rawValue).utf8))
    }
}
