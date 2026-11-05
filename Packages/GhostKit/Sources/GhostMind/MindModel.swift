import Foundation

/// Ce que l'utilisateur demande, compris par GHOST.
public enum MindIntent: Codable, Hashable, Sendable {
    case writeMessage(recipient: String?, topic: String)
    case findPlaces(query: String, area: String?, when: String?)
    case createLogo(brief: String)
    case createDocument(brief: String)
    case unsupported

    public var label: String {
        switch self {
        case .writeMessage: return "Écrire un message"
        case .findPlaces: return "Chercher des lieux"
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

public struct MindState: Codable, Sendable {
    public var schemaVersion = 1
    public var drafts: [String: MailDraft] = [:]
    /// Missions déjà traitées (clé : identifiant de mission) : un brouillon n'est jamais recréé en double.
    public var handled: [String: String] = [:]
    public init() {}
}

public enum MindError: Error, LocalizedError, Sendable {
    case notAllowed(String), invalid(String), sendFailed(String), storage(String)
    public var errorDescription: String? {
        switch self {
        case .notAllowed(let s), .invalid(let s), .sendFailed(let s), .storage(let s): return s
        }
    }
}
