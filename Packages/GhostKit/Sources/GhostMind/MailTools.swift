import Foundation
import GhostContext
import GhostPerception

/// Retrouve un destinataire dans la mémoire locale (personnes déjà vues, avec adresse), jamais en devinant.
public enum RecipientResolver {
    public struct Match: Sendable, Equatable { public var name: String; public var email: String }

    /// Une seule personne correspondante avec adresse → trouvée ; sinon `nil` (l'utilisateur choisit).
    public static func resolve(hint: String?, in graph: ContextSnapshot, namespace: String) -> Match? {
        guard let hint, hint.count > 1 else { return nil }
        // Adresse donnée telle quelle dans la demande : on l'utilise, sans la deviner.
        if MailDraft.isValidAddress(hint) { return Match(name: hint, email: hint) }
        let wanted = IntentClassifier.fold(hint)
        let candidates = graph.nodes.values.filter { node in
            guard node.kind == .person, node.namespace == namespace, let email = node.properties["email"], !email.isEmpty else { return false }
            let title = IntentClassifier.fold(node.title)
            return title == wanted || title.hasPrefix(wanted + " ") || title.split(separator: " ").first.map(String.init) == wanted
        }
        let unique = Set(candidates.compactMap { $0.properties["email"] })
        guard unique.count == 1, let email = unique.first, let node = candidates.first else { return nil }
        return Match(name: node.title, email: email)
    }
}

public protocol MailSender: Sendable {
    func send(to: String, subject: String, body: String) async throws
}

/// Envoie par l'application Mail de l'utilisateur (ses comptes, sa signature). macOS demande une fois l'autorisation
/// d'automatisation. Appelé **uniquement** après le clic de l'utilisateur sur « Envoyer ».
public struct AppleMailSender: MailSender {
    public init() {}

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\" & return & \"")
    }

    public func send(to: String, subject: String, body: String) async throws {
        guard MailDraft.isValidAddress(to) else { throw MindError.invalid("Adresse du destinataire invalide.") }
        let source = """
        tell application "Mail"
            set theMessage to make new outgoing message with properties {subject:"\(Self.escaped(subject))", content:"\(Self.escaped(body))", visible:false}
            tell theMessage to make new to recipient at end of to recipients with properties {address:"\(Self.escaped(to))"}
            send theMessage
        end tell
        """
        let failure: String? = await MainActor.run {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return "Script d'envoi invalide." }
            script.executeAndReturnError(&error)
            return (error?[NSAppleScript.errorMessage] as? String).map { $0 } ?? (error != nil ? "Envoi refusé par macOS ou par Mail." : nil)
        }
        if let failure { throw MindError.sendFailed(failure) }
    }
}

/// Rédaction d'un mail : modèle de langage si disponible, sinon brouillon simplifié clairement indiqué.
struct EmailDrafter {
    struct Content: Decodable { var subject: String; var body: String }

    static let system = """
    Tu rédiges des e-mails au nom de l'utilisateur, en français naturel, courtois et concis (tutoiement si la demande tutoie, sinon vouvoiement).
    N'invente aucun fait : pas de date, de chiffre, de lieu ni d'engagement qui ne figure pas dans la demande. Si une information manque, écris sans elle.
    Utilise le prénom du destinataire pour la formule d'appel.
    Réponds UNIQUEMENT par un objet JSON : {"subject":"objet court","body":"texte complet avec formule de politesse et signature"}.
    """

    static func prompt(request: String, recipient: String?, topic: String, user: String) -> String {
        let first = recipient.flatMap { $0.contains("@") ? nil : $0.split(separator: " ").first.map(String.init) }
        let payload: [String: Any] = ["demande": request, "destinataire": recipient ?? "inconnu", "prenom_destinataire": first ?? "inconnu",
                                      "sujet": topic, "expediteur": user]
        return String(data: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }

    /// Validation stricte : tout ce qui n'est pas exactement conforme est refusé.
    static func parse(_ text: String) -> Content? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let c = try? JSONDecoder().decode(Content.self, from: data) else { return nil }
        let subject = c.subject.trimmingCharacters(in: .whitespacesAndNewlines), body = c.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...140).contains(subject.count), (10...4_000).contains(body.count),
              !body.contains("{{"), !subject.contains("{{") else { return nil }
        return Content(subject: subject, body: body)
    }

    /// Brouillon sans IA : honnête sur ses limites.
    static func simplified(recipient: String?, topic: String, user: String) -> Content {
        let first = recipient.flatMap { $0.contains("@") ? nil : $0.split(separator: " ").first.map(String.init) }
        let subject = String(topic.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = topic.prefix(1).uppercased() + topic.dropFirst()
        return Content(subject: subject.isEmpty ? "Message" : subject.prefix(1).uppercased() + subject.dropFirst(),
                       body: "Bonjour\(first.map { " \($0)" } ?? ""),\n\n\(sentence).\n\nBien cordialement,\n\(user)")
    }
}
