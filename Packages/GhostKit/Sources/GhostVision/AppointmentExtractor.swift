import Foundation
import GhostPerception

/// Rendez-vous détecté dans un texte lu à l'écran.
public struct AppointmentDraft: Codable, Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    /// L'heure figure explicitement dans le texte (« à 21h »). Sans heure, rien n'est ajouté automatiquement.
    public var hasExplicitTime: Bool
    /// Sûr à ajouter directement : événement nommé, date et heure explicites, ni question ni hypothèse.
    public var certain: Bool
    public var confidence: Double
    public var excerpt: String
    public var location: String?
}

/// Détecte « un dîner le 10 novembre à 21h », « rdv jeudi à 14h30 », etc. Règles explicites, sans IA.
/// Garde-fous : une question (« on dîne le 10 à 21h ? »), une hypothèse (« peut-être »), une annulation, une promotion
/// ou une simple échéance (« avant vendredi ») ne sont jamais ajoutées automatiquement.
public struct AppointmentExtractor: Sendable {
    public var calendar: Calendar
    public var deadlines: DeadlineExtractor

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        deadlines = DeadlineExtractor(calendar: calendar)
    }

    /// (mot normalisé, titre affiché, durée en heures)
    static let nouns: [(String, String, Double)] = [
        ("petit dejeuner", "Petit-déjeuner", 1), ("diner", "Dîner", 2), ("dejeuner", "Déjeuner", 1.5), ("rendez vous", "Rendez-vous", 1),
        ("rdv", "Rendez-vous", 1), ("reunion", "Réunion", 1), ("meeting", "Réunion", 1), ("call", "Appel", 0.5), ("visio", "Visio", 1),
        ("soiree", "Soirée", 3), ("apero", "Apéro", 2), ("afterwork", "Afterwork", 2), ("brunch", "Brunch", 2), ("anniversaire", "Anniversaire", 3),
        ("mariage", "Mariage", 4), ("concert", "Concert", 3), ("spectacle", "Spectacle", 2), ("match", "Match", 2), ("cinema", "Cinéma", 2.5),
        ("resto", "Restaurant", 2), ("restaurant", "Restaurant", 2), ("entretien", "Entretien", 1), ("consultation", "Consultation", 1),
        ("dentiste", "Dentiste", 1), ("medecin", "Médecin", 1), ("coiffeur", "Coiffeur", 1), ("seance", "Séance", 1),
        ("formation", "Formation", 2), ("conference", "Conférence", 2), ("barbecue", "Barbecue", 3), ("bbq", "Barbecue", 3)
    ]
    static let hypothesis = ["si", "peut etre", "peut-etre", "on verra", "a voir", "eventuellement", "ou pas", "pas sur", "je ne sais pas"]
    static let cancellation = ["annule", "annulee", "annuler", "reporte", "reportee", "decale", "decalee", "plus de", "pas de"]
    static let promotion = ["offre", "promo", "profitez", "gratuit", "inscrivez", "inscription", "webinaire", "webinar", "reduction", "soldes",
                            "newsletter", "abonnez", "vente privee", "cliquez", "billets", "reservez", "% de remise"]
    static let deadlineMarkers = ["pour", "avant", "d'ici", "au plus tard", "jusqu'a", "jusqu'au", "by", "before", "due", "until"]

    public func drafts(in text: String, reference: Date) -> [AppointmentDraft] {
        var result: [AppointmentDraft] = []
        for sentence in Self.sentences(text) {
            let normalized = Self.normalize(sentence)
            guard !Self.containsWord(normalized, in: Self.promotion), !Self.containsWord(normalized, in: Self.cancellation) else { continue }
            guard let noun = Self.nouns.first(where: { Self.containsWord(normalized, in: [$0.0]) }) else { continue }
            guard let deadline = deadlines.extract(from: sentence, reference: reference) else { continue }
            let marker = Self.normalize(deadline.text)
            if Self.deadlineMarkers.contains(where: { marker.hasPrefix($0 + " ") }) { continue }   // « avant vendredi » = échéance, pas rendez-vous
            let explicitTime = deadline.precision == .exact
            let question = sentence.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            let uncertain = Self.containsWord(normalized, in: Self.hypothesis)
            var confidence = 0.45 + 0.25 + (explicitTime ? 0.2 : 0) + 0.1
            if question { confidence -= 0.25 }
            if uncertain { confidence -= 0.3 }
            let start = explicitTime ? deadline.date : (calendar.date(bySettingHour: 12, minute: 0, second: 0, of: deadline.date) ?? deadline.date)
            let person = Self.person(in: sentence)
            let place = Self.place(in: sentence)
            result.append(AppointmentDraft(
                title: noun.1 + (person.map { " avec \($0)" } ?? ""),
                start: start, end: start.addingTimeInterval(noun.2 * 3600),
                hasExplicitTime: explicitTime, certain: explicitTime && !question && !uncertain && confidence >= 0.8,
                confidence: max(0.05, min(0.99, confidence)), excerpt: String(sentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                location: place))
        }
        return result.sorted { $0.confidence > $1.confidence }
    }

    static func sentences(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[^.!?\n]+[.!?]?"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 8 }
    }
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
    }
    static func containsWord(_ text: String, in words: [String]) -> Bool {
        let padded = " " + text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "%'")).inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        return words.contains { padded.contains(" " + $0.replacingOccurrences(of: "-", with: " ") + " ") }
    }
    static func person(in sentence: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"\bavec\s+([A-ZÀ-ÝÉ][\p{L}'’\-]+(?:\s+[A-ZÀ-ÝÉ][\p{L}'’\-]+)?)"#)
        let ns = sentence as NSString
        guard let m = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
    static func place(in sentence: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"\b(chez\s+[A-ZÀ-ÝÉ][\p{L}'’\-]+(?:\s+[A-ZÀ-ÝÉ][\p{L}'’\-]+)?|au\s+[A-ZÀ-ÝÉ][\p{L}'’\-]+(?:\s+[A-ZÀ-ÝÉ][\p{L}'’\-]+)?)"#)
        let ns = sentence as NSString
        guard let m = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
