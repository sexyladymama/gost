import Foundation
import GhostPerception
import GhostContext

enum BrainText {
    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: " ").replacingOccurrences(of: "'", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let stopwords: Set<String> = [
        "le", "la", "les", "un", "une", "des", "du", "de", "d", "l", "et", "ou", "a", "au", "aux", "en", "pour", "par",
        "sur", "avec", "dans", "ce", "ces", "cet", "cette", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
        "que", "qui", "te", "me", "se", "il", "elle", "on", "je", "tu", "vous", "nous", "the", "of", "to", "and", "in",
        "for", "by", "me", "my", "your", "please", "merci", "bonjour", "demain", "avant", "apres", "est", "sont",
        "peux", "pourrais", "pouvez", "stp", "svp", "matin", "soir"
    ]

    static func tokens(_ s: String) -> Set<String> {
        Set(normalized(s).split(separator: " ").map(String.init).filter { $0.count > 2 && !stopwords.contains($0) })
    }

    /// Premier marqueur trouvé (comparaison sur mots entiers).
    static func firstPhrase(in normalizedText: String, of phrases: [String]) -> String? {
        let padded = " " + normalizedText + " "
        return phrases.first { padded.contains(" " + $0 + " ") }
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

/// Indices linguistiques lus dans un événement. Lexiques explicites : le Brain
/// ne s'appuie jamais sur un modèle pour ces garde-fous.
struct BrainSignals {
    var text: String
    var cancelPhrase: String?
    var ackPhrase: String?
    var deadlineChangePhrase: String?
    var vaguePhrase: String?
    var vagueObject: String?
    var collective: Bool
    var urgentWord: String?
    var consequenceWord: String?
    var importantWord: String?
    var availabilityRequest: Bool
    var obligationPhrase: String?
    var isAutomated: Bool
    var hasEvidence: Set<String>

    var cancels: Bool { cancelPhrase != nil }
    var acknowledges: Bool { ackPhrase != nil }

    static let cancel = ["annule", "annulee", "annulation", "plus besoin", "finalement pas", "laisse tomber",
                         "oublie ma demande", "n est plus necessaire", "inutile de", "no longer needed", "cancel",
                         "cancelled", "canceled", "never mind", "disregard", "ignore my previous", "ne fais pas"]
    static let ack = ["bien recu", "bien recue", "merci pour le fichier", "merci pour l envoi", "c est parfait",
                      "parfait merci", "c est bien recu", "received the file", "thanks for sending", "got it thanks",
                      "bien recu merci", "c est exactement ce qu il fallait"]
    static let deadlineChange = ["decale", "decalee", "reporte", "reportee", "repousse", "repoussee", "finalement pour",
                                 "nouvelle echeance", "nouvelle date", "changement d echeance", "au lieu de",
                                 "postponed", "rescheduled", "moved to", "now due", "pushed back", "delai prolonge",
                                 "avance a", "avancee"]
    static let vague = ["prochainement", "un de ces jours", "a l occasion", "quand on aura le temps", "a un moment",
                        "un jour", "bientot", "dans un futur proche", "at some point", "sometime soon",
                        "when we get a chance", "one of these days", "eventually", "plus tard"]
    static let vagueObject = ["ca", "cela", "ce sujet", "le truc", "ce truc", "this", "that", "ce point"]
    static let urgent = ["urgent", "urgente", "urgence", "asap", "immediatement", "critique", "prioritaire",
                         "au plus vite", "des que possible", "en urgence", "tres urgent"]
    static let important = ["important", "importante", "essentiel", "essentielle", "crucial", "cruciale", "capital"]
    static let consequence = ["contrat", "facture", "devis", "client", "juridique", "legal", "audit", "paiement",
                              "reglement", "signature", "penalite", "conseil d administration", "comite de direction",
                              "contract", "invoice", "quote", "payment", "legal", "compliance"]
    static let availability = ["disponible", "disponibilite", "dispo", "libre", "available", "availability",
                               "reunion", "rendez vous", "rdv", "point jeudi", "point lundi", "point mardi",
                               "point mercredi", "point vendredi", "meeting"]
    static let obligation = ["doit", "doivent", "obligatoire", "est requis", "est exige", "il faut absolument", "must",
                             "required", "mandatory", "imperatif"]

    static func read(_ event: GhostEvent) -> BrainSignals {
        var parts = [event.title, event.summary, event.expectedAction ?? ""]
        parts += event.evidence.compactMap(\.excerpt)
        parts += event.requiredInformation
        let text = BrainText.normalized(parts.joined(separator: " . "))
        func find(_ list: [String]) -> String? { BrainText.firstPhrase(in: text, of: list) }
        let collective = BrainText.firstPhrase(in: text, of: ["qu on regarde", "qu on voie", "on regarde", "on devrait", "qu on se", "we should", "we could"]) != nil
        return BrainSignals(
            text: text, cancelPhrase: find(cancel), ackPhrase: find(ack), deadlineChangePhrase: find(deadlineChange),
            vaguePhrase: find(vague), vagueObject: find(vagueObject), collective: collective,
            urgentWord: find(urgent), consequenceWord: find(consequence), importantWord: find(important),
            availabilityRequest: find(availability) != nil, obligationPhrase: find(obligation),
            isAutomated: event.evidence.contains { $0.rule == "information.automated" },
            hasEvidence: Set(event.evidence.map(\.rule)))
    }
}


/// Vue en lecture seule du graphe de contexte, restreinte à l'espace de noms
/// de l'événement : le Brain ne mélange jamais personnel et professionnel.
struct ContextLens {
    let graph: ContextSnapshot
    let eventNode: ContextNode?
    let namespace: String
    let projects: [ContextNode]
    let conversation: ContextNode?

    init(graph: ContextSnapshot, event: GhostEvent) {
        self.graph = graph
        let node = graph.nodes.values.first {
            $0.kind == .event && ($0.properties["eventID"] == event.id.uuidString
                                  || $0.provenance.contains { $0.fingerprint == event.fingerprint && $0.sourceID == event.source.id })
        }
        eventNode = node
        let scope = graph.scopes[event.source.id.rawValue] ?? .unclassified
        let boundary = scope == .unclassified ? "unclassified:\(event.source.id.rawValue)" : scope.rawValue
        namespace = node?.namespace ?? (boundary + (event.source.isSimulated ? ":simulation" : ":real"))
        func related(_ kind: ContextRelationKind) -> [ContextNode] {
            guard let node else { return [] }
            return graph.relations.values.filter { $0.kind == kind && $0.from == node.id }.compactMap { graph.nodes[$0.to] }
        }
        projects = related(.eventRelatesToProject).sorted { ($0.status == .confirmed ? 0 : 1, $0.title) < ($1.status == .confirmed ? 0 : 1, $1.title) }
        conversation = related(.eventInConversation).first
    }

    var contextRefs: [String] {
        ([eventNode?.id, conversation?.id] + projects.map(\.id)).compactMap { $0 }
    }

    /// Documents du même espace de noms pertinents pour des mots-clés.
    func resources(keywords: Set<String>, projectIDs: Set<String>) -> [ResourceRef] {
        var result: [ResourceRef] = []
        let linked = Set(graph.relations.values.filter { $0.kind == .documentBelongsToProject && projectIDs.contains($0.to) }.map(\.from))
        for doc in graph.nodes.values where doc.kind == .document && doc.namespace == namespace {
            if doc.properties["availability"] == "deleted" { continue }
            let tokens = BrainText.tokens(doc.title + " " + (doc.properties["path"] ?? ""))
            let overlap = tokens.intersection(keywords)
            let isLinked = linked.contains(doc.id)
            guard !overlap.isEmpty || isLinked else { continue }
            let why = isLinked && overlap.isEmpty ? "Document associé au projet"
                : "Titre ou chemin proche de : " + overlap.sorted().joined(separator: ", ")
            result.append(ResourceRef(nodeID: doc.id, title: doc.title, path: doc.properties["path"],
                                      sourceID: doc.provenance.compactMap { $0.sourceID?.rawValue }.first, why: why))
        }
        return result.sorted { $0.title < $1.title }
    }

    /// Nombre d'événements déjà vus avec une personne (force de la relation).
    func priorInteractions(email: String?) -> Int {
        guard let email = email?.lowercased(),
              let person = graph.nodes.values.first(where: { $0.kind == .person && $0.namespace == namespace && $0.properties["email"] == email })
        else { return 0 }
        return graph.relations.values.filter { $0.kind == .eventMentionsPerson && $0.to == person.id }.count
    }

    /// Préférences explicites de l'utilisateur mentionnant un terme.
    func preferences(matching terms: [String]) -> [ContextNode] {
        let normalizedTerms = terms.map(BrainText.normalized).filter { $0.count > 2 }
        return graph.nodes.values.filter { node in
            guard node.kind == .preference, namespace.hasPrefix(node.scope.rawValue) else { return false }
            let text = BrainText.normalized(node.title)
            return normalizedTerms.contains { text.contains($0) }
        }
    }
}
