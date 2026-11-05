import Foundation

/// Comprend la demande par règles explicites (français et anglais). Sert de base fiable, sans modèle ;
/// le modèle de langage rédige ensuite le contenu, il ne décide pas de ce qui est autorisé.
public enum IntentClassifier {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
    }
    static func has(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func capture(_ pattern: String, in text: String, group: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let range = m.range(withName: group)
        guard range.location != NSNotFound else { return nil }
        let value = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return value.isEmpty ? nil : value
    }

    /// Nom propre : majuscules **obligatoires**, même quand le reste du motif ignore la casse (`(?-i:…)`).
    static let name = #"(?-i:[A-ZÀ-Ý][\p{L}'’\-]+(?:\s+[A-ZÀ-Ý][\p{L}'’\-]+)?)"#

    public static func classify(_ text: String) -> MindIntent {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = fold(t)
        let create = #"\b(cree|creer|fais|faire|dessine|dessiner|concois|concevoir|genere|generer|prepare|preparer)\b"#
        let write = #"\b(ecris|ecrire|ecrit|redige|rediger|envoie|envoyer|prepare|preparer|write|send)\b"#
        let search = #"\b(trouve|trouver|cherche|chercher|recherche|rechercher|regarde|regarder|propose|proposer|find|search|look)\b"#

        if has(create, in: n), has(#"\b(logo|icone|identite visuelle|flyer|affiche|banniere|visuel)\b"#, in: n) { return .createLogo(brief: t) }
        if has(write + "|" + create, in: n), has(#"\b(document|lettre|compte rendu|compte-rendu|rapport|cv|devis|contrat|note de service|cahier des charges)\b"#, in: n),
           !has(#"\b(mail|e-mail|email|courriel)\b"#, in: n) { return .createDocument(brief: t) }
        if has(write, in: n), has(#"\b(mail|e-mail|email|courriel|message)\b"#, in: n) {
            let who = capture(#"(?<who>[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)"#, in: t, group: "who")
                ?? capture(#"\b(?:mail|e-mail|email|courriel|message)\b.{0,12}?\b(?:à|a|au|pour)\s+(?<who>"# + name + #")"#, in: t, group: "who")
                ?? capture(#"\b(?:à|a|au)\s+(?<who>"# + name + #")"#, in: t, group: "who")
            var topic = capture(#"(?:\b(?:à|a|au)\s+(?:"# + name + #"|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+)\s+|\bmail\s+|\bmessage\s+)(?<topic>(?:pour|afin de|en disant|en lui disant|que|concernant|à propos de)\b.+)$"#, in: t, group: "topic") ?? ""
            var stripped = true
            while stripped {
                stripped = false
                for lead in ["pour lui dire ", "en lui disant ", "en disant ", "afin de ", "pour ", "que ", "qu'", "qu’", "concernant ", "à propos de "] where topic.lowercased().hasPrefix(lead) {
                    topic = String(topic.dropFirst(lead.count)); stripped = true; break
                }
            }
            topic = topic.replacingOccurrences(of: #"[\s,]*(?:stp|s'il te pla[iî]t|s'il vous pla[iî]t|please|merci)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            return .writeMessage(recipient: who, topic: topic.isEmpty ? t : topic)
        }
        if has(search, in: n), has(#"\b(bar|bars|restaurant|restaurants|resto|restos|club|clubs|salle|salles|cafe|cafes|hotel|hotels|boulangerie|pharmacie|cinema|musee|parc|brasserie|coiffeur|dentiste|medecin|spa|gym|boite|cave|librairie|fleuriste|garage|hopital|supermarche|magasin|terrasse|rooftop|activite|sortie)\b"#, in: n) {
            let query = capture(#"\b(?:trouve|trouver|cherche|chercher|recherche|rechercher|regarde|regarder|propose|proposer)\b\s+(?:moi\s+)?(?:nous\s+)?(?:un|une|des|les|le|la|l')?\s*(?<q>[^,.;!?]+?)(?=\s+(?:vers|près de|pres de|autour de|à côté de|a cote de|dans|sur|à|au|aux|en|chez|genre|le\s+\d|pour|sympa)\b|[,.;!?]|$)"#, in: t, group: "q")
                ?? t
            var area = capture(#"\b(?:vers|près de|pres de|autour de|à côté de|a cote de|dans le coin de|dans|sur)\s+(?<a>chez\s+(?:nous|moi)|"# + name + #")"#, in: t, group: "a")
            if area == nil, has(#"\bchez\s+(nous|moi)\b"#, in: n) { area = "chez nous" }
            let when = capture(#"(?:genre\s+)?\b(?<w>le\s+\d{1,2}(?:\s+\p{L}+)?|demain(?:\s+soir)?|ce soir|ce week-end|samedi(?:\s+soir)?|dimanche(?:\s+soir)?|vendredi(?:\s+soir)?)\b"#, in: t, group: "w")
            return .findPlaces(query: query, area: area, when: when)
        }
        // Recherche web : un verbe de recherche explicite suivi d'un sujet (« regarde » et « propose » sont trop ambigus ici).
        let web = #"\b(trouve|trouver|cherche|chercher|recherche|rechercher|find|search|google|googler)\b"#
        if has(web, in: n), !has(#"\b(mail|e-mail|email|courriel|logo|document|fichier)\b"#, in: n),
           let query = capture(#"\b(?:trouve|trouver|cherche|chercher|recherche|rechercher|find|search for|search|google|googler)\b(?:-(?:moi|nous))?\s+(?:moi\s+)?(?:nous\s+)?(?:sur\s+(?:internet|google|le\s+web)\s+)?(?:des\s+infos?\s+(?:sur|à propos de)\s+|des\s+informations\s+(?:sur|à propos de)\s+)?(?<q>[^.;!?\n]{3,120})"#, in: t, group: "q"),
           query.split(separator: " ").count >= 2 {
            return .searchWeb(query: query.replacingOccurrences(of: #"\s+sur\s+(?:internet|google)$"#, with: "", options: [.regularExpression, .caseInsensitive]))
        }
        return .unsupported
    }
}
