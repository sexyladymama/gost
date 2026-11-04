import Foundation

/// E-mail tel que fourni par un ``MailProvider``.
///
/// Ne contient que les données nécessaires à la compréhension : en-têtes
/// utiles et partie texte (tronquée). Aucune pièce jointe.
public struct EmailMessage: Codable, Hashable, Sendable {
    /// Identifiant chez le fournisseur (ex. identifiant de message Gmail).
    public var id: String
    public var threadID: String?
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var date: Date
    /// Corps texte brut (tronqué par le fournisseur).
    public var bodyText: String
    /// Indices d'envoi automatisé (`List-Unsubscribe`, `Precedence: bulk`…).
    public var isBulk: Bool
    /// `true` si le message répond à un autre (`In-Reply-To`).
    public var isReply: Bool

    public init(id: String, threadID: String? = nil, from: String, to: [String], cc: [String] = [],
                subject: String, date: Date, bodyText: String, isBulk: Bool = false, isReply: Bool = false) {
        self.id = id
        self.threadID = threadID
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.bodyText = bodyText
        self.isBulk = isBulk
        self.isReply = isReply
    }
}

/// Changement constaté dans un dossier autorisé.
public struct FileChange: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case created, modified, deleted
    }
    public var kind: Kind
    /// Chemin relatif au dossier autorisé.
    public var relativePath: String
    public var metadata: FileMetadata

    public init(kind: Kind, relativePath: String, metadata: FileMetadata) {
        self.kind = kind
        self.relativePath = relativePath
        self.metadata = metadata
    }
}

/// Métadonnées d'un fichier. Le contenu du fichier n'est jamais lu.
public struct FileMetadata: Codable, Hashable, Sendable {
    public var name: String
    public var fileExtension: String
    public var category: FileCategory
    public var size: Int64
    public var modifiedAt: Date
    public var createdAt: Date?

    public init(name: String, fileExtension: String, category: FileCategory,
                size: Int64, modifiedAt: Date, createdAt: Date?) {
        self.name = name
        self.fileExtension = fileExtension
        self.category = category
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}

/// Observation brute produite par une source, avant normalisation.
public enum RawObservation: Hashable, Sendable {
    case email(EmailMessage, account: String?)
    case file(FileChange)
}

/// Format commun à toutes les sources, produit par l'``EventNormalizer``.
public struct NormalizedObservation: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case message
        case file(FileChange)
    }

    public var source: EventSource
    /// Identifiant de l'élément chez la source.
    public var externalID: String
    /// Version de l'élément (pour distinguer deux modifications d'un fichier).
    public var version: String
    public var occurredAt: Date
    public var title: String
    /// Texte nettoyé (citations et signatures retirées), vide pour un fichier.
    public var text: String
    public var people: [Person]
    public var content: Content
    /// Message automatisé (newsletter, notification, adresse « no-reply »).
    public var isAutomated: Bool
    public var isReply: Bool
    /// `true` si l'utilisateur est destinataire direct (champ « À »),
    /// `nil` si inconnu.
    public var userIsDirectRecipient: Bool?
    public var metadata: [String: String]

    /// Empreinte stable utilisée pour le dédoublonnage.
    public var fingerprint: String {
        "\(source.id.rawValue):\(externalID):\(version)"
    }
}
