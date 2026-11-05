import Foundation

/// Catégories d'événements reconnues par l'``UnderstandingEngine``.
public enum GhostEventKind: String, Codable, CaseIterable, Sendable, Comparable {
    /// Événement informatif sans action évidente.
    case information = "INFORMATION"
    /// Demande adressée à l'utilisateur (y compris une question directe).
    case request = "REQUEST"
    /// Travail concret à effectuer.
    case task = "TASK"
    /// Échéance ou engagement temporel.
    case deadline = "DEADLINE"
    /// Relance ou action en attente.
    case followUp = "FOLLOW_UP"
    /// Nouveau document ou modification pertinente.
    case documentEvent = "DOCUMENT_EVENT"
    /// Échange qui ne constitue pas nécessairement une mission.
    case conversation = "CONVERSATION"

    /// Ordre de priorité pour déterminer le type principal (plus petit = prioritaire).
    var priority: Int {
        switch self {
        case .followUp: return 0
        case .task: return 1
        case .request: return 2
        case .deadline: return 3
        case .documentEvent: return 4
        case .conversation: return 5
        case .information: return 6
        }
    }

    public static func < (lhs: GhostEventKind, rhs: GhostEventKind) -> Bool {
        lhs.priority < rhs.priority
    }
}

/// Type technique d'une source de perception.
public enum SourceKind: String, Codable, Sendable {
    case email
    case folder
    /// Texte lu à l'écran (blocs utiles uniquement, jamais d'image).
    case screen

    /// Permission que l'utilisateur doit avoir accordée pour qu'une source de ce type soit lue.
    public var requiredPermission: Permission {
        switch self {
        case .email: return .readMail
        case .folder: return .watchFolder
        case .screen: return .observeScreen
        }
    }
}

/// Identifiant stable d'une source configurée (ex. `gmail`, `folder.main`).
public struct SourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Description de la source d'un événement.
public struct EventSource: Codable, Hashable, Sendable {
    public var id: SourceID
    public var kind: SourceKind
    /// Nom affichable, ex. « Gmail (simulation) » ou « Dossier : Projets ».
    public var displayName: String
    /// `true` si la source est un simulateur et non un service réel.
    public var isSimulated: Bool

    public init(id: SourceID, kind: SourceKind, displayName: String, isSimulated: Bool = false) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.isSimulated = isSimulated
    }
}

/// Personne liée à un événement.
public struct Person: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case sender, recipient, copied
    }
    public var name: String?
    public var email: String?
    public var role: Role

    public init(name: String?, email: String?, role: Role) {
        self.name = name
        self.email = email
        self.role = role
    }

    /// Nom à afficher : le nom s'il existe, sinon l'adresse.
    public var displayName: String { name ?? email ?? "Inconnu" }
}

/// Échéance extraite d'un texte.
public struct Deadline: Codable, Hashable, Sendable {
    public enum Precision: String, Codable, Sendable {
        /// Heure explicite (« à 14h »).
        case exact
        /// Moment de la journée (« demain matin »).
        case partOfDay
        /// Jour (« vendredi », « le 15 mars »).
        case day
        /// Semaine (« fin de semaine »).
        case week
        /// Mois (« fin du mois »).
        case month
    }

    /// Instant de référence de l'échéance (voir `Precision` pour son interprétation).
    public var date: Date
    /// Texte d'origine, ex. « pour demain matin ».
    public var text: String
    public var precision: Precision

    public init(date: Date, text: String, precision: Precision) {
        self.date = date
        self.text = text
        self.precision = precision
    }
}

/// Élément justifiant une interprétation : quelle règle, sur quel extrait.
public struct Evidence: Codable, Hashable, Sendable {
    /// Identifiant de la règle, ex. `request.marker`.
    public var rule: String
    /// Explication lisible.
    public var explanation: String
    /// Extrait du texte ayant déclenché la règle (court).
    public var excerpt: String?

    public init(rule: String, explanation: String, excerpt: String? = nil) {
        self.rule = rule
        self.explanation = explanation
        self.excerpt = excerpt
    }
}

/// Événement structuré produit par GHOST PERCEPTION.
///
/// Structure stable (``schemaVersion``) destinée aux futurs moteurs.
/// Volontairement, l'événement ne contient **pas** le contenu intégral de la
/// source (corps d'e-mail, contenu de fichier) : seulement un résumé, des
/// extraits justificatifs courts et des métadonnées.
public struct GhostEvent: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    /// Identifiant unique de l'événement.
    public var id: UUID
    /// Empreinte déterministe de l'observation d'origine, utilisée pour le
    /// dédoublonnage : `source:identifiantExterne:version`.
    public var fingerprint: String
    public var schemaVersion: Int

    /// Type principal.
    public var kind: GhostEventKind
    /// Toutes les catégories détectées (contient toujours `kind`).
    public var tags: Set<GhostEventKind>
    public var summary: String
    public var source: EventSource
    /// Date de détection par GHOST.
    public var detectedAt: Date
    /// Date de l'événement d'origine (réception de l'e-mail, modification du fichier).
    public var occurredAt: Date
    /// Titre d'origine (objet de l'e-mail, nom du fichier).
    public var title: String
    public var people: [Person]
    /// Action potentiellement attendue de l'utilisateur.
    public var expectedAction: String?
    /// Résultat attendu (ex. « Fichier Excel »).
    public var expectedOutput: String?
    /// Informations potentiellement nécessaires pour y répondre.
    public var requiredInformation: [String]
    public var deadline: Deadline?
    /// Niveau de confiance de l'interprétation, entre 0 et 1.
    public var confidence: Double
    public var evidence: [Evidence]
    /// `true` si l'événement pourrait devenir une mission. GHOST n'en crée
    /// aucune : il se contente de le signaler aux futurs moteurs.
    public var isMissionCandidate: Bool
    /// Métadonnées techniques utiles (type de fichier, taille…).
    public var metadata: [String: String]

    public init(id: UUID = UUID(),
                fingerprint: String,
                kind: GhostEventKind,
                tags: Set<GhostEventKind>,
                summary: String,
                source: EventSource,
                detectedAt: Date,
                occurredAt: Date,
                title: String,
                people: [Person] = [],
                expectedAction: String? = nil,
                expectedOutput: String? = nil,
                requiredInformation: [String] = [],
                deadline: Deadline? = nil,
                confidence: Double,
                evidence: [Evidence],
                isMissionCandidate: Bool,
                metadata: [String: String] = [:]) {
        self.id = id
        self.fingerprint = fingerprint
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.tags = tags.union([kind])
        self.summary = summary
        self.source = source
        self.detectedAt = detectedAt
        self.occurredAt = occurredAt
        self.title = title
        self.people = people
        self.expectedAction = expectedAction
        self.expectedOutput = expectedOutput
        self.requiredInformation = requiredInformation
        self.deadline = deadline
        self.confidence = confidence
        self.evidence = evidence
        self.isMissionCandidate = isMissionCandidate
        self.metadata = metadata
    }

    /// `true` si l'événement mérite d'être mis en avant dans l'interface.
    public var isImportant: Bool {
        isMissionCandidate || deadline != nil || kind == .followUp
    }
}
