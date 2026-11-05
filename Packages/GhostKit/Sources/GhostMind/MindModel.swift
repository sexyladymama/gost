import Foundation

/// Ce que l'utilisateur demande, compris par GHOST.
public enum MindIntent: Codable, Hashable, Sendable {
    case writeMessage(recipient: String?, topic: String)
    case findPlaces(query: String, area: String?, when: String?)
    case searchWeb(query: String)
    case createLogo(brief: String)
    case createDocument(brief: String)
    case unsupported

    public var label: String {
        switch self {
        case .writeMessage: return "Écrire un message"
        case .findPlaces: return "Chercher des lieux"
        case .searchWeb: return "Chercher sur le web"
        case .createLogo: return "Créer un logo ou un visuel"
        case .createDocument: return "Créer un document"
        case .unsupported: return "Demande non prise en charge"
        }
    }
}

public enum DraftStatus: String, Codable, Sendable {
    /// Aucun modèle de langage disponible : brouillon simplifié, à refaire dès que le modèle l'est.
    case needsModel
    case ready
    /// Envoi demandé par l'utilisateur et en cours. Jamais rejoué automatiquement après une interruption.
    case sending
    case sent
    case cancelled
    case failed
}

public struct MailDraft: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var missionID: String
    public var recipientName: String?
    public var recipientEmail: String?
    public var subject: String
    public var body: String
    public var status: DraftStatus
    public var version: Int
    public var generatedBy: String
    /// Phrase de demande sur laquelle le brouillon se fonde.
    public var basis: String
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public static func isValidAddress(_ s: String?) -> Bool {
        guard let s, s.count <= 254 else { return false }
        return s.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
    /// Envoyable : prêt, destinataire valide, objet et texte non vides.
    public var canSend: Bool {
        status == .ready && Self.isValidAddress(recipientEmail)
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum PlaceSearchStatus: String, Codable, Sendable {
    case done, noResults
    /// « chez nous » ou aucune zone : l'utilisateur doit préciser où chercher.
    case needsArea
    /// La recherche en ligne n'est pas autorisée dans GHOST.
    case notAuthorized
    case failed
}

public struct PlaceResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var phone: String?
    public var url: String?
    public var latitude: Double
    public var longitude: Double
    public var distanceMeters: Double?
    public init(id: String, name: String, address: String, phone: String? = nil, url: String? = nil,
                latitude: Double, longitude: Double, distanceMeters: Double? = nil) {
        self.id = id; self.name = name; self.address = address; self.phone = phone; self.url = url
        self.latitude = latitude; self.longitude = longitude; self.distanceMeters = distanceMeters
    }
}

public enum SearchKind: String, Codable, Sendable { case places, web }

/// Une recherche : de lieux (Apple Plans) ou sur le web. Pour le web, chaque résultat porte le titre (`name`), l'extrait (`address`) et le lien (`url`).
public struct PlaceSearch: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var missionID: String
    public var query: String
    public var area: String?
    public var when: String?
    public var basis: String
    public var status: PlaceSearchStatus
    public var results: [PlaceResult]
    public var note: String?
    public var hidden: Bool
    public var searchedAt: Date
    /// Absent dans les anciens fichiers : recherche de lieux.
    public var kind: SearchKind?
    public var isWeb: Bool { kind == .web }
}

public enum CreationKind: String, Codable, Sendable { case logo, document }

public enum CreationStatus: String, Codable, Sendable {
    case done
    /// Aucun modèle de langage disponible : rien n'est inventé, « Refaire » une fois le modèle disponible.
    case needsModel
    /// Aucun dossier de création choisi par l'utilisateur.
    case needsFolder
    case failed
}

public struct Creation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var missionID: String
    public var kind: CreationKind
    public var title: String
    public var basis: String
    public var status: CreationStatus
    /// Chemins complets des fichiers créés (jamais écrasés : une nouvelle version porte un nouveau nom).
    public var paths: [String]
    public var generatedBy: String?
    public var note: String?
    public var version: Int
    public var hidden: Bool
    public var createdAt: Date
    public var updatedAt: Date
}

public struct MindState: Codable, Sendable {
    public var schemaVersion = 1
    public var drafts: [String: MailDraft] = [:]
    /// Missions déjà traitées (clé : identifiant de mission) : un travail n'est jamais recréé en double.
    public var handled: [String: String] = [:]
    public var searches: [String: PlaceSearch] = [:]
    public var creations: [String: Creation] = [:]
    public init() {}

    private enum Keys: String, CodingKey { case schemaVersion, drafts, handled, searches, creations }
    /// Décodage tolérant : un fichier écrit avant l'ajout d'un champ reste lisible.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        drafts = try c.decodeIfPresent([String: MailDraft].self, forKey: .drafts) ?? [:]
        handled = try c.decodeIfPresent([String: String].self, forKey: .handled) ?? [:]
        searches = try c.decodeIfPresent([String: PlaceSearch].self, forKey: .searches) ?? [:]
        creations = try c.decodeIfPresent([String: Creation].self, forKey: .creations) ?? [:]
    }
}

public enum MindError: Error, LocalizedError, Sendable {
    case notAllowed(String), invalid(String), sendFailed(String), storage(String)
    public var errorDescription: String? {
        switch self {
        case .notAllowed(let s), .invalid(let s), .sendFailed(let s), .storage(let s): return s
        }
    }
}
