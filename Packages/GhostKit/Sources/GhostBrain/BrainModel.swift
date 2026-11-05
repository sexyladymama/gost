import Foundation
import GhostPerception

/// Contrat de données de GHOST BRAIN. Tous les types sont `Codable`, versionnés
/// (``BrainSchema``) et dotés d'identifiants stables : le futur moteur
/// d'autonomie (Mission 005) consomme ``Mission`` sans réécriture.
public enum BrainSchema {
    public static let version = 1
}

// MARK: - Décisions

public enum DecisionKind: String, Codable, CaseIterable, Sendable {
    case ignore = "IGNORE"
    case monitor = "MONITOR"
    case remember = "REMEMBER"
    case clarify = "CLARIFY"
    case createMission = "CREATE_MISSION"
    case updateMission = "UPDATE_MISSION"
    case completeMission = "COMPLETE_MISSION"

    public var label: String {
        switch self {
        case .ignore: return "Ignorer"
        case .monitor: return "Surveiller"
        case .remember: return "Mémoriser"
        case .clarify: return "Clarifier"
        case .createMission: return "Créer une mission"
        case .updateMission: return "Actualiser une mission"
        case .completeMission: return "Terminer une mission"
        }
    }
}

public struct Alternative: Codable, Hashable, Sendable {
    public var kind: DecisionKind
    public var whyRejected: String
    public init(kind: DecisionKind, whyRejected: String) { self.kind = kind; self.whyRejected = whyRejected }
}

/// Trace complète d'une décision : justifiable et vérifiable a posteriori.
public struct DecisionRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: DecisionKind
    public var missionID: String?
    public var eventIDs: [UUID]
    /// Éléments effectivement utilisés (champs d'événement, nœuds de contexte…).
    public var usedElements: [String]
    public var reasons: [String]
    public var confidence: Double
    public var alternatives: [Alternative]
    public var uncertainties: [String]
    /// `rules` ou `rules+model`.
    public var engine: String
    public var modelProvider: String?
    public var modelIsSimulated: Bool
    public var schemaVersion: Int

    public init(id: UUID = UUID(), date: Date, kind: DecisionKind, missionID: String? = nil, eventIDs: [UUID],
                usedElements: [String], reasons: [String], confidence: Double, alternatives: [Alternative],
                uncertainties: [String], engine: String = "rules", modelProvider: String? = nil,
                modelIsSimulated: Bool = false) {
        self.id = id; self.date = date; self.kind = kind; self.missionID = missionID; self.eventIDs = eventIDs
        self.usedElements = usedElements; self.reasons = reasons; self.confidence = confidence
        self.alternatives = alternatives; self.uncertainties = uncertainties; self.engine = engine
        self.modelProvider = modelProvider; self.modelIsSimulated = modelIsSimulated
        self.schemaVersion = BrainSchema.version
    }
}

// MARK: - Priorité

public enum MissionPriority: String, Codable, CaseIterable, Comparable, Sendable {
    case low = "LOW", normal = "NORMAL", high = "HIGH", critical = "CRITICAL"

    public var rank: Int {
        switch self { case .low: return 0; case .normal: return 1; case .high: return 2; case .critical: return 3 }
    }
    public static func < (lhs: MissionPriority, rhs: MissionPriority) -> Bool { lhs.rank < rhs.rank }
    public var label: String {
        switch self { case .low: return "Basse"; case .normal: return "Normale"; case .high: return "Haute"; case .critical: return "Critique" }
    }
}

public struct PriorityFactor: Codable, Hashable, Sendable {
    public var name: String
    /// Valeur normalisée entre 0 et 1.
    public var value: Double
    public var weight: Double
    public var explanation: String
    public init(name: String, value: Double, weight: Double, explanation: String) {
        self.name = name; self.value = value; self.weight = weight; self.explanation = explanation
    }
}

public struct PriorityAssessment: Codable, Hashable, Sendable {
    public var level: MissionPriority
    public var score: Double
    public var factors: [PriorityFactor]
    public var notes: [String]
    public var computedAt: Date
    public init(level: MissionPriority, score: Double, factors: [PriorityFactor], notes: [String], computedAt: Date) {
        self.level = level; self.score = score; self.factors = factors; self.notes = notes; self.computedAt = computedAt
    }
}

// MARK: - Incertitude

public enum EpistemicLevel: String, Codable, CaseIterable, Sendable {
    case known, deduced, assumed, unknown
    public var label: String {
        switch self { case .known: return "Je sais"; case .deduced: return "Je déduis"; case .assumed: return "Je suppose"; case .unknown: return "J'ignore" }
    }
}

public struct Belief: Codable, Hashable, Sendable {
    public var subject: String
    public var statement: String
    public var level: EpistemicLevel
    public var confidence: Double
    public var provenance: [String]
    public init(subject: String, statement: String, level: EpistemicLevel, confidence: Double, provenance: [String]) {
        self.subject = subject; self.statement = statement; self.level = level
        self.confidence = confidence; self.provenance = provenance
    }
}

// MARK: - Permissions

/// Capacités distinguées par le Trust Engine du Brain.
public enum Capability: String, Codable, CaseIterable, Sendable {
    case read, createFile, modifyFile, deleteFile, sendCommunication, externalAction

    public var label: String {
        switch self {
        case .read: return "Lire une information"
        case .createFile: return "Créer un fichier"
        case .modifyFile: return "Modifier un fichier"
        case .deleteFile: return "Supprimer un fichier"
        case .sendCommunication: return "Envoyer une communication"
        case .externalAction: return "Effectuer une action externe"
        }
    }
    public var risk: Risk {
        switch self {
        case .read: return .low
        case .createFile: return .medium
        case .modifyFile, .sendCommunication, .externalAction: return .high
        case .deleteFile: return .critical
        }
    }
    public enum Risk: String, Codable, Sendable { case low, medium, high, critical }
}

public enum PermissionStatus: String, Codable, Sendable {
    /// Lecture déjà autorisée par l'utilisateur pour cette source.
    case granted
    /// Autorisation de source manquante : l'utilisateur doit l'accorder.
    case missing
    /// Capacité d'écriture / d'envoi : jamais accordée automatiquement ;
    /// une validation explicite sera exigée au moment de l'exécution (Mission 005).
    case approvalRequired
}

public struct PermissionNeed: Codable, Hashable, Sendable {
    public var capability: Capability
    public var resource: String
    public var sourceID: String?
    public var status: PermissionStatus
    public var reason: String
    public init(capability: Capability, resource: String, sourceID: String? = nil,
                status: PermissionStatus, reason: String) {
        self.capability = capability; self.resource = resource; self.sourceID = sourceID
        self.status = status; self.reason = reason
    }
}

// MARK: - Objectif

public enum GoalKind: String, Codable, CaseIterable, Sendable {
    case explicitRequest, implicitObjective, obligation, deadline, intention
    case informationOnly, needsClarification, cancellation

    public var label: String {
        switch self {
        case .explicitRequest: return "Demande explicite"
        case .implicitObjective: return "Objectif implicite"
        case .obligation: return "Obligation"
        case .deadline: return "Échéance"
        case .intention: return "Intention"
        case .informationOnly: return "Information sans action"
        case .needsClarification: return "Clarification nécessaire"
        case .cancellation: return "Annulation"
        }
    }
}

public struct PersonRef: Codable, Hashable, Sendable {
    public var name: String
    public var email: String?
    public var role: String
    public init(name: String, email: String?, role: String) { self.name = name; self.email = email; self.role = role }
}

public struct DeadlineClaim: Codable, Hashable, Sendable {
    public var date: Date
    public var text: String
    public var sourceID: String
    public var sourceName: String
    public var eventID: UUID
    public var senderEmail: String?
    public var assertedAt: Date
    /// Remplacée par une assertion ultérieure explicite (jamais effacée).
    public var superseded: Bool
    public init(date: Date, text: String, sourceID: String, sourceName: String, eventID: UUID,
                senderEmail: String?, assertedAt: Date, superseded: Bool = false) {
        self.date = date; self.text = text; self.sourceID = sourceID; self.sourceName = sourceName
        self.eventID = eventID; self.senderEmail = senderEmail; self.assertedAt = assertedAt; self.superseded = superseded
    }
}

public struct Goal: Codable, Hashable, Sendable {
    public var kind: GoalKind
    public var expectedResult: String
    public var deliverable: String?
    public var origin: String
    public var people: [PersonRef]
    public var projectID: String?
    public var projectTitle: String?
    public var deadline: Date?
    public var deadlineText: String?
    public var constraints: [String]
    public var availableInfo: [String]
    public var missingInfo: [String]
    public var confidence: Double
    public var beliefs: [Belief]
}

// MARK: - Plan

public enum StepState: String, Codable, CaseIterable, Sendable {
    case pending = "PENDING", ready = "READY", blocked = "BLOCKED"
    case completed = "COMPLETED", failed = "FAILED", cancelled = "CANCELLED"
    public var label: String {
        switch self {
        case .pending: return "En attente"; case .ready: return "Prête"; case .blocked: return "Bloquée"
        case .completed: return "Terminée"; case .failed: return "Échec"; case .cancelled: return "Annulée"
        }
    }
}

public struct PlanStep: Codable, Hashable, Identifiable, Sendable {
    /// Identifiant stable : dérivé de la mission et de la clé d'étape.
    public var id: String
    public var key: String
    public var title: String
    public var detail: String
    public var state: StepState
    public var dependsOn: [String]
    public var needs: [PermissionNeed]
    public var resources: [String]
    public var verification: String
    public var blockedReason: String?
}

public struct MissionPlan: Codable, Hashable, Sendable {
    public var objective: String
    public var strategy: String
    public var steps: [PlanStep]
    public var resources: [String]
    public var dataSources: [String]
    public var successConditions: [String]
    public var risks: [String]
    public var verifications: [String]
    public var revision: Int
}

// MARK: - Mission

public enum MissionState: String, Codable, CaseIterable, Sendable {
    case detected = "DETECTED", analyzing = "ANALYZING", needsClarification = "NEEDS_CLARIFICATION"
    case proposed = "PROPOSED", ready = "READY", blocked = "BLOCKED", inProgress = "IN_PROGRESS"
    case completed = "COMPLETED", cancelled = "CANCELLED", failed = "FAILED"

    public var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
    public var label: String {
        switch self {
        case .detected: return "Détectée"; case .analyzing: return "Analyse en cours"
        case .needsClarification: return "À clarifier"; case .proposed: return "Proposée"
        case .ready: return "Prête"; case .blocked: return "Bloquée"; case .inProgress: return "En cours"
        case .completed: return "Terminée"; case .cancelled: return "Annulée"; case .failed: return "Échec"
        }
    }

    /// Transitions autorisées. Une mission terminée ne peut être que rouverte.
    public func canMove(to next: MissionState) -> Bool {
        if self == next { return true }
        switch self {
        case .detected, .analyzing:
            return [.analyzing, .needsClarification, .proposed, .blocked, .cancelled, .failed].contains(next)
        case .needsClarification:
            // `completed` : uniquement sur preuve observée (ex. accusé de réception du demandeur).
            return [.proposed, .blocked, .ready, .completed, .cancelled, .failed].contains(next)
        case .proposed:
            return [.ready, .blocked, .needsClarification, .inProgress, .completed, .cancelled, .failed].contains(next)
        case .ready:
            return [.proposed, .blocked, .needsClarification, .inProgress, .completed, .cancelled, .failed].contains(next)
        case .blocked:
            return [.proposed, .ready, .needsClarification, .completed, .cancelled, .failed].contains(next)
        case .inProgress:
            return [.completed, .blocked, .cancelled, .failed].contains(next)
        case .completed, .cancelled, .failed:
            return [.proposed, .needsClarification].contains(next)
        }
    }
}

public struct TriggerRef: Codable, Hashable, Sendable {
    public var eventID: UUID
    public var fingerprint: String
    public var kind: GhostEventKind
    public var sourceID: String
    public var sourceName: String
    public var summary: String
    public var threadID: String?
    public var detectedAt: Date
    public var occurredAt: Date
    public var senderEmail: String?
    /// Texte-signal borné (titre, résumé, extraits de preuve de Perception) : sert à recalculer la priorité plus tard.
    public var signalText: String
}

public struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var summary: String
    public var decisionID: UUID?
    public var before: String?
    public var after: String?
    public var byUser: Bool
    public init(id: UUID = UUID(), date: Date, kind: String, summary: String, decisionID: UUID? = nil,
                before: String? = nil, after: String? = nil, byUser: Bool = false) {
        self.id = id; self.date = date; self.kind = kind; self.summary = summary
        self.decisionID = decisionID; self.before = before; self.after = after; self.byUser = byUser
    }
}

public enum UserVerdict: String, Codable, Sendable { case none, confirmed, rejected }

public struct MissingItem: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case clarify, block, minor }
    public var text: String
    public var severity: Severity
}

/// Nature du travail demandé : détermine le modèle de plan.
public enum WorkKind: String, Codable, Sendable { case produce, review, send, reply }

/// Données d'importance mémorisées pour pouvoir recalculer la priorité plus tard.
public struct PriorityContext: Codable, Hashable, Sendable {
    public var senderInteractions: Int
    public var projectConfirmed: Bool
    public var preferenceBoost: Double
    public var preferenceNotes: [String]
}

public struct ResourceRef: Codable, Hashable, Sendable {
    public var nodeID: String
    public var title: String
    public var path: String?
    public var sourceID: String?
    public var why: String
}

public struct Mission: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var schemaVersion: Int
    public var title: String
    public var summary: String
    public var goal: Goal
    public var originSourceID: String
    public var originSourceName: String
    public var triggers: [TriggerRef]
    public var contextRefs: [String]
    public var people: [PersonRef]
    public var deadline: Date?
    public var deadlineClaims: [DeadlineClaim]
    public var deadlineConflict: Bool
    public var priority: PriorityAssessment
    public var userPriority: MissionPriority?
    public var confidence: Double
    public var plan: MissionPlan
    public var permissions: [PermissionNeed]
    public var successConditions: [String]
    public var risks: [String]
    public var missingInfo: [MissingItem]
    public var clarificationQuestion: String?
    public var beliefs: [Belief]
    public var workKind: WorkKind
    public var resources: [ResourceRef]
    public var priorityContext: PriorityContext
    public var state: MissionState
    public var history: [HistoryEntry]
    public var decisionIDs: [UUID]
    public var dedupeKey: String
    public var namespace: String
    public var isSimulated: Bool
    public var verdict: UserVerdict
    public var notes: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public var effectivePriority: MissionPriority { userPriority ?? priority.level }
    public var isOpen: Bool { !state.isTerminal }
}

// MARK: - État persistant

/// Élément à surveiller : intention possible, pas encore une mission.
public struct Watch: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sourceID: String
    public var eventID: UUID
    public var threadID: String?
    public var senderEmail: String?
    public var namespace: String
    public var summary: String
    public var reason: String
    public var clarificationQuestion: String
    public var createdAt: Date
}

public struct LedgerEntry: Codable, Hashable, Sendable {
    public var eventID: UUID
    public var decisionID: UUID
    public var kind: DecisionKind
    public var processedAt: Date
}

public enum FeedbackKind: String, Codable, Sendable {
    case confirm, reject, correctGoal, changePriority, addNote, cancel
}

/// Correction de l'utilisateur, conservée localement comme donnée
/// d'apprentissage **contrôlée** : elle n'entraîne aucun modèle, elle ajuste
/// seulement des règles explicites et visibles (ex. clé supprimée).
public struct BrainFeedback: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var missionID: String
    public var kind: FeedbackKind
    public var before: String?
    public var after: String?
}

public struct BrainState: Codable, Sendable {
    public var schemaVersion: Int = BrainSchema.version
    public var missions: [String: Mission] = [:]
    public var decisions: [DecisionRecord] = []
    public var watches: [String: Watch] = [:]
    /// Clé : « source|empreinte ». Garantit qu'un événement n'est analysé qu'une fois.
    public var ledger: [String: LedgerEntry] = [:]
    public var feedback: [BrainFeedback] = []
    /// Missions rejetées par l'utilisateur : ne sont pas recréées.
    public var suppressedKeys: Set<String> = []
    /// Sources révoquées dont l'utilisateur a choisi de conserver l'historique.
    public var retainedSources: Set<String> = []
    public var salt: String = UUID().uuidString
    public init() {}
}

public struct BrainConfig: Sendable {
    /// Confiance minimale pour créer une mission ferme.
    public var missionThreshold: Double = 0.55
    /// Au-delà, une demande est considérée comme suffisamment sûre pour être PROPOSED sans doute.
    public var firmThreshold: Double = 0.7
    public var maxDecisionsKept: Int = 2_000
    public var calendar: Calendar = .current
    public init() {}
}

public enum BrainError: Error, LocalizedError, Sendable {
    case storage(String), invalid(String), unknownMission, staleProcessing, illegalTransition(from: MissionState, to: MissionState)
    public var errorDescription: String? {
        switch self {
        case .storage(let s): return "Cerveau : \(s)"
        case .invalid(let s): return s
        case .unknownMission: return "Mission introuvable."
        case .staleProcessing: return "Analyse interrompue par un changement d'état."
        case .illegalTransition(let a, let b): return "Transition impossible : \(a.label) → \(b.label)."
        }
    }
}

enum BrainID {
    static func make(_ s: String) -> String {
        String(Digest.sha256(Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}
