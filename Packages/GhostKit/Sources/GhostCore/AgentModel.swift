import Foundation
import GhostBrain
import GhostContext
import GhostAutonomy

public enum AgentPhase: String, Codable, Sendable {
    case pending, running, paused, clarification, approval, review, blocked, cancelled
    public var label: String {
        switch self {
        case .pending: return "Objectif reçu"; case .running: return "En cours"; case .paused: return "En pause"
        case .clarification: return "À préciser"; case .approval: return "Votre accord est requis"; case .review: return "Résultat prêt à relire"
        case .blocked: return "Bloquée"; case .cancelled: return "Annulée"
        }
    }
}
public enum AgentAction: String, Codable, Sendable {
    case finalResponse = "final_response", clarificationRequired = "clarification_required", createPlan = "create_plan"
    case toolCall = "tool_call", approvalRequired = "approval_required", `continue`, complete, blocked
}
public enum CoreToolID: String, Codable, Sendable, CaseIterable {
    case searchMemory = "search_memory", inspectProject = "inspect_project", findConversations = "find_conversations", retrieveDeadlines = "retrieve_deadlines"
    case listDocuments = "list_documents", readDocument = "read_document", createDocument = "create_document", verifyArtifact = "verify_artifact"
    case draftEmail = "draft_email", sendDraft = "send_draft", searchWeb = "search_web", searchPlaces = "search_places"
    case createSpreadsheet = "create_spreadsheet", createVisual = "create_visual", createPresentation = "create_presentation"
    case rememberPreference = "remember_preference"
}
public struct AgentToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var tool: CoreToolID
    public var arguments: [String: String]
    public var reason: String
    public var expectedResult: String
    public var missionID: String
    public init(id: String, tool: CoreToolID, arguments: [String: String], reason: String, expectedResult: String, missionID: String) {
        self.id = id; self.tool = tool; self.arguments = arguments; self.reason = reason; self.expectedResult = expectedResult; self.missionID = missionID
    }
    /// Empreinte de l'ACTION : outil, mission et tous les arguments. L'identifiant d'appel et la justification ne comptent pas : un modèle
    /// qui reformule la même action ne contourne ni la détection de boucle ni la liaison d'un accord à l'action exacte.
    public var fingerprint: String {
        let args = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}")
        return ExecutionIdentity.hash(Data((tool.rawValue + "|" + missionID + "|" + args).utf8))
    }
}
public struct AgentPlanItem: Codable, Sendable, Identifiable {
    public var id: String; public var title: String; public var dependsOn: [String]
}
public struct AgentDecision: Codable, Sendable {
    public var schemaVersion: Int
    public var missionID: String
    public var action: AgentAction
    public var text: String?
    public var plan: [AgentPlanItem]?
    public var toolCall: AgentToolCall?
    public var sourceIDs: [String]?
    public init(missionID: String, action: AgentAction, text: String? = nil, plan: [AgentPlanItem]? = nil, toolCall: AgentToolCall? = nil, sourceIDs: [String]? = nil) {
        schemaVersion = 1; self.missionID = missionID; self.action = action; self.text = text; self.plan = plan; self.toolCall = toolCall; self.sourceIDs = sourceIDs
    }
    public static func parse(_ text: String, missionID: String) throws -> Self {
        guard text.utf8.count <= 48_000, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "missionID", "action", "text", "plan", "toolCall", "sourceIDs"]) else { throw CoreError.invalid("Réponse JSON ou schéma invalide.") }
        if let call = object["toolCall"] as? [String: Any], !Set(call.keys).isSubset(of: ["id", "tool", "arguments", "reason", "expectedResult", "missionID"]) { throw CoreError.invalid("Champ d'outil inconnu.") }
        if let plan = object["plan"] as? [[String: Any]], plan.contains(where: { !Set($0.keys).isSubset(of: ["id", "title", "dependsOn"]) }) { throw CoreError.invalid("Champ de plan inconnu.") }
        let decision = try JSONDecoder().decode(Self.self, from: data)
        guard decision.schemaVersion == 1, decision.missionID == missionID,
              (decision.text?.count ?? 0) <= 8_000, (decision.sourceIDs?.count ?? 0) <= 30 else { throw CoreError.invalid("Version, mission ou taille de décision invalide.") }
        switch decision.action {
        case .toolCall, .approvalRequired:
            guard let call = decision.toolCall, call.missionID == missionID, (1...80).contains(call.id.count),
                  !call.reason.isEmpty, call.reason.count <= 500, !call.expectedResult.isEmpty, call.expectedResult.count <= 500,
                  decision.plan == nil else { throw CoreError.invalid("Appel d'outil incomplet.") }
            try ToolRegistry.validate(call)
        case .createPlan:
            guard decision.toolCall == nil, let plan = decision.plan, (1...12).contains(plan.count), Set(plan.map(\.id)).count == plan.count else { throw CoreError.invalid("Plan invalide.") }
            var seen: Set<String> = []
            for step in plan {
                guard (1...80).contains(step.id.count), (1...240).contains(step.title.count), Set(step.dependsOn).isSubset(of: seen) else { throw CoreError.invalid("Dépendance de plan invalide ou cyclique.") }
                seen.insert(step.id)
            }
        default:
            guard decision.toolCall == nil, decision.plan == nil else { throw CoreError.invalid("Action et paramètres incompatibles.") }
            if decision.action != .continue, decision.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw CoreError.invalid("Résultat ou question vide.") }
        }
        return decision
    }
}
public struct AgentLimits: Codable, Sendable {
    public var maxIterations = 16
    public var maxToolCalls = 10
    public var maxTokens = 80_000
    public var maxEstimatedCostUSD = 2.0
    /// Conservative user-configurable accounting rate, not a vendor billing quote.
    public var reservedUSDPerMillionTokens = 100.0
    public var maxSeconds = 180.0
    public var maxOutputBytes = 48_000
    public var maxProtocolRetries = 1
    public init() {}
}
public struct AgentEvidence: Codable, Sendable, Identifiable {
    public var id: String; public var kind: String; public var text: String; public var status: KnowledgeStatus
    public var confidence: Double; public var updatedAt: Date; public var sourceIDs: [String]; public var userConfirmed: Bool
}
public struct AgentArtifact: Codable, Sendable, Identifiable {
    public var id: String { fileName }
    public var fileName: String; public var hash: String; public var verified: Bool
}
public struct AgentToolReceipt: Codable, Sendable, Identifiable {
    public var id: String { call.id }
    public var call: AgentToolCall
    public var status: String
    public var content: String
    public var artifact: AgentArtifact?
    public var sources: [AgentEvidence] = []
    public var completedAt: Date
}
public struct AgentLog: Codable, Sendable, Identifiable {
    public var id = UUID(); public var date = Date(); public var message: String
}
public struct AgentApproval: Codable, Sendable {
    public var call: AgentToolCall; public var digest: String; public var preview: String
}
public struct AgentSession: Codable, Sendable, Identifiable {
    public var id: String
    public var missionID: String
    public var namespace: String
    public var objective: String
    public var privacy: ModelPrivacy
    public var scope: ContextScope = .professional
    public var clarificationAnswer: String?
    public var phase: AgentPhase = .pending
    public var plan: [AgentPlanItem] = []
    public var receipts: [AgentToolReceipt] = []
    public var evidence: [AgentEvidence] = []
    public var decisions: [AgentDecision] = []
    public var history: [AgentLog] = []
    public var clarification: String?
    public var answer: String?
    public var approval: AgentApproval?
    public var approvedDigest: String?
    public var inFlight: AgentToolCall?
    public var outputPath: String?
    public var iterations = 0
    public var toolCalls = 0
    public var reservedTokens = 0
    public var reservedCostUSD = 0.0
    public var elapsedSeconds = 0.0
    public var limits = AgentLimits()
    public var provider: String?
    public var model: String?
    public var isSimulated = false
    public var createdAt = Date()
    public var updatedAt = Date()
    public var error: String?
}
public struct AgentArchive: Codable, Sendable {
    public var schemaVersion = 1
    public var profileID: String
    public var sessions: [String: AgentSession] = [:]
}
public enum CoreError: Error, LocalizedError, Sendable {
    case invalid(String), limit(String), approval(String), unavailable(String), storage(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .limit(let s), .approval(let s), .unavailable(let s), .storage(let s): return s }
    }
}
