import Foundation
import GhostPerception

public enum ContextScope: String, Codable, CaseIterable, Sendable {
    case unclassified, personal, professional
    public var label: String {
        switch self { case .unclassified: return "Non classé"; case .personal: return "Personnel"; case .professional: return "Professionnel" }
    }
}
public enum MemoryDomain: String, Codable, CaseIterable, Sendable {
    case identity, project, context, episodic, task
    public var label: String {
        switch self { case .identity: return "Identité"; case .project: return "Projets"; case .context: return "Contexte"; case .episodic: return "Historique"; case .task: return "Demandes" }
    }
}
public enum ContextEntityKind: String, Codable, CaseIterable, Sendable {
    case person, organization, project, event, document, conversation, taskCandidate, deadline, decision, preference
    public var domain: MemoryDomain {
        switch self {
        case .preference: return .identity
        case .project, .document, .decision: return .project
        case .person, .organization, .conversation: return .context
        case .event: return .episodic
        case .taskCandidate, .deadline: return .task
        }
    }
    public var label: String {
        switch self {
        case .person: return "Personne"; case .organization: return "Organisation"; case .project: return "Projet"
        case .event: return "Événement"; case .document: return "Document"; case .conversation: return "Conversation"
        case .taskCandidate: return "Demande candidate"; case .deadline: return "Échéance"; case .decision: return "Décision"; case .preference: return "Préférence"
        }
    }
}
public enum KnowledgeStatus: String, Codable, CaseIterable, Sendable {
    case confirmed, hypothesis, unknown
    public var label: String {
        switch self { case .confirmed: return "Confirmé"; case .hypothesis: return "Hypothèse"; case .unknown: return "Inconnu" }
    }
}
public enum ContextRelationKind: String, Codable, CaseIterable, Sendable {
    case personParticipatesInProject = "PERSON_PARTICIPATES_IN_PROJECT"
    case documentBelongsToProject = "DOCUMENT_BELONGS_TO_PROJECT"
    case eventRelatesToProject = "EVENT_RELATES_TO_PROJECT"
    case conversationInvolvesPerson = "CONVERSATION_INVOLVES_PERSON"
    case eventReferencesDocument = "EVENT_REFERENCES_DOCUMENT"
    case taskHasDeadline = "TASK_HAS_DEADLINE"
    case decisionBelongsToProject = "DECISION_BELONGS_TO_PROJECT"
    case personWorksWithPerson = "PERSON_WORKS_WITH_PERSON"
    case eventInConversation = "EVENT_IN_CONVERSATION"
    case eventMentionsPerson = "EVENT_MENTIONS_PERSON"
    case eventSuggestsTask = "EVENT_SUGGESTS_TASK"
    case taskRelatesToProject = "TASK_RELATES_TO_PROJECT"
    case conversationRelatesToProject = "CONVERSATION_RELATES_TO_PROJECT"
    case personAssociatedWithOrganization = "PERSON_ASSOCIATED_WITH_ORGANIZATION"
}
public struct ContextProvenance: Codable, Hashable, Sendable {
    public var eventID: UUID?
    public var sourceID: SourceID?
    public var fingerprint: String?
    public var explanation: String
    public var recordedAt: Date
    public var isUserProvided: Bool
    public init(eventID: UUID? = nil, sourceID: SourceID? = nil, fingerprint: String? = nil,
                explanation: String, recordedAt: Date = Date(), isUserProvided: Bool = false) {
        self.eventID = eventID; self.sourceID = sourceID; self.fingerprint = fingerprint
        self.explanation = explanation; self.recordedAt = recordedAt; self.isUserProvided = isUserProvided
    }
}
public struct ContextNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ContextEntityKind
    public var scope: ContextScope
    public var namespace: String
    public var isSimulated: Bool
    public var title: String
    public var status: KnowledgeStatus
    public var confidence: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var occurredAt: Date?
    public var properties: [String: String]
    public var provenance: [ContextProvenance]
    public var domain: MemoryDomain { kind.domain }
}
public struct ContextRelation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ContextRelationKind
    public var from: String
    public var to: String
    public var status: KnowledgeStatus
    public var confidence: Double
    public var createdAt: Date
    public var lastSupportedAt: Date
    public var lastConfirmedAt: Date?
    public var provenance: [ContextProvenance]
    public var userCorrected: Bool
}
public struct ContextCorrection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var targetID: String
    public var action: String
    public var date: Date
}
public struct ContextSnapshot: Codable, Sendable {
    public var nodes: [String: ContextNode] = [:]
    public var relations: [String: ContextRelation] = [:]
    public var scopes: [String: ContextScope] = [:]
    public var retainedSources: Set<String> = []
    public var suppressedNodes: Set<String> = []
    public var suppressedRelations: Set<String> = []
    public var corrections: [ContextCorrection] = []
    public var salt: String = UUID().uuidString
    public init() {}
    public func entities(in domain: MemoryDomain) -> [ContextNode] {
        nodes.values.filter { $0.domain == domain }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
public struct ContextProjectSummary: Sendable {
    public var project: ContextNode
    public var events: [ContextNode]
    public var documents: [ContextNode]
    public var people: [ContextNode]
    public var tasks: [ContextNode]
    public var decisions: [ContextNode]
    public var deadlines: [ContextNode]
    public var latestDeadline: ContextNode?
    public var ambiguities: [String]
    public var missingInformation: [String]
}
public enum ContextError: Error, LocalizedError, Sendable {
    case storage(String), invalid(String)
    public var errorDescription: String? {
        switch self { case .storage(let s): return "Mémoire locale : \(s)"; case .invalid(let s): return s }
    }
}

enum ContextText {
    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func id(_ s: String) -> String { Digest.sha256(Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
