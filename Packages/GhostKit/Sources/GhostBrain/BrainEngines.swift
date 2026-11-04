import Foundation
import GhostPerception
import GhostContext

/// Tout ce dont un moteur a besoin pour analyser un événement. Les moteurs sont
/// des fonctions pures : mêmes entrées, mêmes sorties (stabilité des décisions).
struct BrainInput {
    let event: GhostEvent
    let signals: BrainSignals
    let lens: ContextLens
    let state: BrainState
    let grants: GrantSnapshot
    let now: Date
    let config: BrainConfig
}

enum BrainFormat {
    static func date(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE d MMMM 'à' HH'h'mm"
        return f.string(from: date)
    }
}

// MARK: - A. GOAL ENGINE

/// Détermine ce qui est réellement attendu. Une demande d'un tiers n'est jamais
/// une autorisation d'agir : le Goal décrit un besoin, pas un droit.
enum GoalEngine {
    static func lowSpecificity(_ event: GhostEvent, _ s: BrainSignals) -> Bool {
        event.expectedOutput == nil && event.deadline == nil
            && (s.vaguePhrase != nil || s.vagueObject != nil || s.collective)
    }

    static func classify(_ event: GhostEvent, _ s: BrainSignals) -> GoalKind {
        if s.cancels { return .cancellation }
        if event.kind == .documentEvent { return .informationOnly }
        let actionable = event.tags.contains(.request) || event.tags.contains(.task) || event.tags.contains(.followUp)
        if !actionable {
            if event.tags.contains(.deadline) || event.kind == .deadline {
                return s.obligationPhrase != nil ? .obligation : .deadline
            }
            return .informationOnly
        }
        if s.isAutomated { return .informationOnly }
        if !event.isMissionCandidate { return .intention }
        if lowSpecificity(event, s) { return .intention }
        if event.kind == .followUp && !event.tags.contains(.request) && !event.tags.contains(.task) { return .implicitObjective }
        return .explicitRequest
    }

    static func formalize(_ input: BrainInput) -> Goal {
        let e = input.event
        let kind = classify(e, input.signals)
        let sender = e.people.first { $0.role == .sender }
        var available: [String] = []
        if let sender { available.append("Demandeur : \(sender.displayName)") }
        if let output = e.expectedOutput { available.append("Livrable : \(output)") }
        if let deadline = e.deadline { available.append("Échéance : \(deadline.text)") }
        for info in e.requiredInformation { available.append("Information mentionnée : \(info)") }
        var constraints: [String] = []
        if let deadline = e.deadline {
            constraints.append("Échéance : \(deadline.text) (\(BrainFormat.date(deadline.date, calendar: input.config.calendar)))")
        }
        constraints.append("Aucune action n'est exécutée sans validation explicite de l'utilisateur.")
        let project = input.lens.projects.first
        return Goal(
            kind: kind,
            expectedResult: e.expectedOutput ?? e.expectedAction ?? e.title,
            deliverable: e.expectedOutput,
            origin: "\(e.source.displayName) · \(e.title)",
            people: e.people.map { PersonRef(name: $0.displayName, email: $0.email, role: roleLabel($0.role)) },
            projectID: project?.id, projectTitle: project?.title,
            deadline: e.deadline?.date, deadlineText: e.deadline?.text,
            constraints: constraints, availableInfo: available, missingInfo: [],
            confidence: e.confidence, beliefs: [])
    }

    static func roleLabel(_ role: Person.Role) -> String {
        switch role { case .sender: return "demandeur"; case .recipient: return "destinataire"; case .copied: return "en copie" }
    }
}

// MARK: - B. REASONING ENGINE

struct Strategy: Hashable {
    var name: String
    var score: Double
    var rationale: String
}

struct Analysis {
    var workKind: WorkKind
    var resources: [ResourceRef]
    var missing: [MissingItem]
    var contradictions: [String]
    var dependencies: [String]
    var constraints: [String]
    var strategies: [Strategy]
    var chosen: Strategy
    var usedElements: [String]

    var blockingMissing: [MissingItem] { missing.filter { $0.severity == .block } }
    var clarifyMissing: [MissingItem] { missing.filter { $0.severity == .clarify } }
}

/// Examine la situation dans son ensemble en s'appuyant sur GHOST CONTEXT :
/// ne redemande jamais ce que le contexte contient déjà.
enum ReasoningEngine {
    static let produceWords = ["preparer", "prepare", "preparez", "rediger", "redige", "ecrire", "creer", "cree", "compiler",
                               "completer", "complete", "remplir", "remplis", "finaliser", "finalise", "mettre a jour",
                               "mets a jour", "organiser", "organise", "produire", "put together", "write", "draft",
                               "create", "update", "compile", "fill out", "fill in", "finalize", "prepare"]
    static let reviewWords = ["relire", "relis", "verifier", "verifie", "valider", "valide", "corriger", "corrige",
                              "analyser", "analyse", "regarder", "jeter un oeil", "jeter un coup d oeil", "review",
                              "check", "fix"]
    static let sendWords = ["envoyer", "envoie", "envoyez", "transmettre", "transmets", "partager", "partage",
                            "renvoyer", "renvoie", "send", "share"]
    static let dataDeliverables: Set<String> = ["Fichier Excel", "Rapport", "Présentation", "Budget", "Tableau de bord",
                                                "Devis", "Facture", "Contrat", "Compte rendu", "Document", "Document PDF"]

    static func workKind(action: String?, deliverable: String?) -> WorkKind {
        let a = BrainText.normalized(action ?? "")
        if let first = a.split(separator: " ").first.map(String.init) {
            if sendWords.contains(first) { return .send }
            if reviewWords.contains(first) { return .review }
            if produceWords.contains(first) { return .produce }
        }
        if BrainText.firstPhrase(in: a, of: produceWords) != nil { return .produce }
        if BrainText.firstPhrase(in: a, of: reviewWords) != nil { return .review }
        if BrainText.firstPhrase(in: a, of: sendWords) != nil { return .send }
        return deliverable != nil ? .produce : .reply
    }

    static func keywords(for event: GhostEvent) -> Set<String> {
        var words = BrainText.tokens(event.title + " " + (event.expectedAction ?? "") + " " + event.requiredInformation.joined(separator: " "))
        // Les mots génériques du livrable n'identifient pas un document précis.
        words.subtract(["fichier", "excel", "document", "rapport", "tableau", "mois", "presentation", "file", "report"])
        if let output = event.expectedOutput { words.formUnion(BrainText.tokens(output).subtracting(["fichier", "excel", "document"])) }
        return words
    }

    static func analyze(_ input: BrainInput, goal: Goal) -> Analysis {
        let e = input.event
        let kind = workKind(action: e.expectedAction, deliverable: e.expectedOutput)
        var used = ["événement \(e.id.uuidString.prefix(8))", "type \(e.kind.rawValue)", "confiance \(Int(e.confidence * 100)) %"]
        if let node = input.lens.eventNode { used.append("contexte : nœud événement \(node.id.prefix(8))") }
        for p in input.lens.projects { used.append("projet « \(p.title) » (\(p.status.label))") }

        // Ressources pertinentes déjà connues du contexte (même cloisonnement).
        let projectIDs = Set(input.lens.projects.map(\.id))
        let resources = input.lens.resources(keywords: keywords(for: e), projectIDs: projectIDs)
        for r in resources { used.append("document « \(r.title) »") }

        var missing: [MissingItem] = []
        let needsData = kind == .produce && (e.expectedOutput.map { dataDeliverables.contains($0) } ?? true)
        switch kind {
        case .produce:
            if e.expectedOutput == nil && goal.kind != .cancellation {
                missing.append(MissingItem(text: "Livrable attendu non précisé", severity: .clarify))
            }
            if needsData && resources.isEmpty {
                let what = e.requiredInformation.first ?? e.expectedOutput ?? "demandées"
                missing.append(MissingItem(text: "Données sources introuvables dans le contexte autorisé : \(what)", severity: .block))
            }
        case .review, .send:
            if resources.isEmpty {
                missing.append(MissingItem(text: "Document concerné introuvable dans le contexte autorisé", severity: .block))
            }
        case .reply:
            if input.signals.availabilityRequest {
                missing.append(MissingItem(text: "Aucun agenda connecté : disponibilité impossible à vérifier", severity: .block))
            }
        }
        if e.deadline == nil { missing.append(MissingItem(text: "Échéance non communiquée", severity: .minor)) }

        // Contradictions déjà présentes dans le contexte.
        var contradictions: [String] = []
        if let node = input.lens.eventNode {
            if let a = node.properties["ambiguity"] { contradictions.append(a) }
            let tasks = input.lens.graph.relations.values.filter { $0.kind == .eventSuggestsTask && $0.from == node.id }.compactMap { input.lens.graph.nodes[$0.to] }
            for task in tasks {
                let dates = Set(input.lens.graph.relations.values.filter { $0.kind == .taskHasDeadline && $0.from == task.id }
                    .compactMap { input.lens.graph.nodes[$0.to]?.occurredAt })
                if dates.count > 1 { contradictions.append("Plusieurs échéances connues du contexte pour « \(task.title) ».") }
            }
        }

        var dependencies: [String] = []
        if kind == .produce { dependencies.append("Le livrable dépend des données sources.") }
        if kind != .reply { dependencies.append("La remise dépend de la validation de l'utilisateur.") }

        // Comparaison de stratégies.
        var strategies: [Strategy] = []
        let critical = missing.contains { $0.severity == .clarify }
        strategies.append(Strategy(name: "clarifier d'abord", score: critical ? 0.9 : 0.2,
                                   rationale: critical ? "Une information essentielle de l'objectif manque." : "L'objectif est suffisamment précis."))
        if kind == .reply {
            strategies.append(Strategy(name: "répondre directement", score: input.signals.availabilityRequest ? 0.45 : 0.8,
                                       rationale: input.signals.availabilityRequest ? "La réponse dépend d'un agenda non connecté." : "Une réponse suffit, aucun livrable requis."))
        } else {
            strategies.append(Strategy(name: "produire à partir du contexte", score: resources.isEmpty ? 0.1 : min(0.95, 0.6 + 0.1 * Double(min(resources.count, 3))),
                                       rationale: resources.isEmpty ? "Aucun document pertinent dans le contexte." : "\(resources.count) document(s) pertinent(s) déjà connu(s)."))
            strategies.append(Strategy(name: "rassembler les données d'abord", score: resources.isEmpty && !critical ? 0.6 : 0.25,
                                       rationale: "Identifier les sources avant de produire, faute de document connu."))
        }
        let chosen = strategies.max { $0.score < $1.score } ?? strategies[0]
        var constraints = goal.constraints
        if !contradictions.isEmpty { constraints.append("Contradictions à lever avant toute remise.") }
        return Analysis(workKind: kind, resources: resources, missing: missing, contradictions: contradictions,
                        dependencies: dependencies, constraints: constraints, strategies: strategies,
                        chosen: chosen, usedElements: used)
    }
}

// MARK: - C. PRIORITY ENGINE

enum PriorityEngine {
    static func effortMinutes(kind: WorkKind, deliverable: String?) -> Double {
        switch kind {
        case .reply, .send: return 10
        case .review: return 45
        case .produce:
            if let d = deliverable, ["Fichier Excel", "Rapport", "Présentation", "Budget", "Tableau de bord", "Devis", "Facture", "Contrat", "Compte rendu"].contains(d) { return 120 }
            return 60
        }
    }

    static func assess(deadline: Date?, conflict: Bool, text: String, kind: WorkKind, deliverable: String?,
                       context: PriorityContext, followUps: Int, missingCount: Int, totalInfo: Int,
                       now: Date) -> PriorityAssessment {
        var factors: [PriorityFactor] = []
        var notes: [String] = []
        let t = BrainText.normalized(text)

        // Urgence : proximité de l'échéance.
        let urgencyValue: Double
        let urgencyText: String
        if let deadline {
            let hours = deadline.timeIntervalSince(now) / 3600
            switch hours {
            case ..<0: urgencyValue = 1; urgencyText = "Échéance dépassée"
            case ..<6: urgencyValue = 1; urgencyText = "Échéance dans moins de 6 h"
            case ..<24: urgencyValue = 0.85; urgencyText = "Échéance dans moins de 24 h"
            case ..<48: urgencyValue = 0.7; urgencyText = "Échéance dans moins de 48 h"
            case ..<72: urgencyValue = 0.55; urgencyText = "Échéance dans moins de 3 jours"
            case ..<168: urgencyValue = 0.35; urgencyText = "Échéance dans la semaine"
            default: urgencyValue = 0.15; urgencyText = "Échéance lointaine"
            }
        } else { urgencyValue = 0.10; urgencyText = "Aucune échéance connue" }
        var urgency = urgencyValue
        if BrainText.firstPhrase(in: t, of: BrainSignals.urgent) != nil {
            // Urgence déclarée : au moins « sous 48 h », même sans date.
            urgency = min(1, max(urgency + 0.15, 0.75))
            notes.append("Le message est explicitement marqué urgent.")
        }
        factors.append(PriorityFactor(name: "Urgence", value: urgency, weight: 0.35,
                                      explanation: urgencyText + (conflict ? " (échéances contradictoires : la plus proche est retenue par prudence)" : "")))

        // Importance : relation, projet, préférences explicites.
        var importance = 0.3
        var why: [String] = []
        if context.senderInteractions >= 3 { importance += 0.2; why.append("interlocuteur fréquent (\(context.senderInteractions) échanges)") }
        else if context.senderInteractions >= 1 { importance += 0.1; why.append("interlocuteur déjà connu") }
        if context.projectConfirmed { importance += 0.2; why.append("projet confirmé par l'utilisateur") }
        if context.preferenceBoost > 0 { importance += context.preferenceBoost; why.append("préférence explicite de l'utilisateur") }
        if BrainText.firstPhrase(in: t, of: BrainSignals.important) != nil { importance += 0.15; why.append("marqué important") }
        importance = min(1, importance)
        factors.append(PriorityFactor(name: "Importance", value: importance, weight: 0.25,
                                      explanation: why.isEmpty ? "Aucun indice d'importance particulière" : why.joined(separator: " ; ")))

        // Conséquence d'un retard.
        var consequence = 0.2
        var consequenceText = "Conséquence d'un retard non identifiée"
        if let word = BrainText.firstPhrase(in: t, of: BrainSignals.consequence) {
            consequence = word == "client" ? 0.6 : 0.8
            consequenceText = "Sujet sensible (« \(word) »)"
        }
        factors.append(PriorityFactor(name: "Conséquence d'un retard", value: consequence, weight: 0.20, explanation: consequenceText))

        // Pression de l'effort : temps estimé vs temps disponible.
        let minutes = effortMinutes(kind: kind, deliverable: deliverable)
        var pressure = 0.2
        var pressureText = "Effort estimé \(Int(minutes)) min, sans échéance : pression faible"
        if let deadline {
            let hours = max(0.5, deadline.timeIntervalSince(now) / 3600)
            pressure = min(1, (minutes / 60) / (hours * 0.25))
            pressureText = "Effort estimé \(Int(minutes)) min pour \(Int(hours)) h disponibles (25 % du temps mobilisable)"
        }
        factors.append(PriorityFactor(name: "Effort vs temps", value: pressure, weight: 0.10, explanation: pressureText))

        // Relances.
        let follow = min(1, 0.4 * Double(followUps))
        factors.append(PriorityFactor(name: "Relances", value: follow, weight: 0.10,
                                      explanation: followUps == 0 ? "Aucune relance" : "\(followUps) relance(s) reçue(s)"))

        // Disponibilité de l'information.
        let availability = totalInfo == 0 ? 0.5 : max(0, 1 - Double(missingCount) / Double(max(totalInfo, 1)))
        factors.append(PriorityFactor(name: "Informations disponibles", value: availability, weight: 0.05,
                                      explanation: missingCount == 0 ? "Informations suffisantes" : "\(missingCount) information(s) manquante(s)"))

        let score = factors.reduce(0) { $0 + $1.value * $1.weight }
        var level: MissionPriority = score >= 0.75 ? .critical : score >= 0.45 ? .high : score >= 0.25 ? .normal : .low
        // Une échéance proche n'est pas, à elle seule, une obligation majeure.
        if level == .critical && importance < 0.5 && consequence < 0.7 {
            level = .high
            notes.append("Plafonnée à HAUTE : l'échéance seule ne suffit pas à rendre une mission critique.")
        }
        // Une obligation majeure reste haute même si l'échéance est lointaine.
        if level < .high && consequence >= 0.7 && importance >= 0.5 {
            level = .high
            notes.append("Relevée à HAUTE : obligation à forte conséquence, indépendamment de l'échéance.")
        }
        return PriorityAssessment(level: level, score: score, factors: factors, notes: notes, computedAt: now)
    }
}

// MARK: - D. PLANNING ENGINE

enum PlanningEngine {
    private struct Draft {
        var key: String, title: String, detail: String
        var deps: [String] = []
        var needs: [PermissionNeed] = []
        var resources: [String] = []
        var verification: String
        var completed = false
        var blockedReason: String?
        var userAction = false
    }

    static func build(missionID: String, goal: Goal, kind: WorkKind, resources: [ResourceRef],
                      missing: [MissingItem], strategy: String, deadline: Date?, deadlineConflict: Bool,
                      grants: GrantSnapshot, originSourceID: String, previous: MissionPlan?,
                      calendar: Calendar) -> MissionPlan {
        let deliverable = goal.deliverable ?? "livrable"
        let requester = goal.people.first { $0.role == "demandeur" }?.name ?? "le demandeur"
        let resourceNames = resources.map(\.title)
        let blockingData = missing.first { $0.severity == .block }
        let clarify = missing.first { $0.severity == .clarify }
        let dueText = deadline.map { BrainFormat.date($0, calendar: calendar) } ?? "échéance non communiquée"

        var drafts: [Draft] = []
        drafts.append(Draft(key: "understand", title: "Comprendre la demande",
                            detail: "Demande de \(requester) : \(goal.expectedResult). Origine : \(goal.origin).",
                            verification: "Reformulation de la demande conforme au message d'origine.", completed: true))
        var last = "understand"
        if let clarify {
            drafts.append(Draft(key: "clarify", title: "Clarifier : \(clarify.text.lowercased())",
                                detail: "Poser une question précise à \(requester) avant d'aller plus loin.",
                                deps: [last], verification: "La réponse précise l'information manquante.", userAction: true))
            last = "clarify"
        }
        func readNeed(_ resource: String, source: String?) -> PermissionNeed {
            BrainTrust.evaluate(.read, resource: resource, sourceID: source, grants: grants)
        }
        let dataSource = resources.compactMap(\.sourceID).first ?? "folder"

        switch kind {
        case .produce:
            drafts.append(Draft(key: "gather", title: "Retrouver les données sources",
                                detail: resourceNames.isEmpty ? "Aucun document connu : identifier où se trouvent les données (ou les fournir)."
                                                              : "Consulter : " + resourceNames.joined(separator: ", ") + ".",
                                deps: [last], needs: [readNeed(resourceNames.first ?? "Fichiers locaux", source: dataSource)],
                                resources: resourceNames, verification: "Liste des sources utilisées, avec leur date de modification.",
                                blockedReason: blockingData?.text))
            drafts.append(Draft(key: "build", title: "Produire le brouillon : \(deliverable)",
                                detail: "Construire le \(deliverable.lowercased()) à partir des sources retrouvées, sans l'envoyer.",
                                deps: ["gather"], needs: [BrainTrust.evaluate(.createFile, resource: deliverable, sourceID: nil, grants: grants)],
                                resources: resourceNames, verification: "Brouillon créé, contenu rattaché à chaque source."))
            drafts.append(Draft(key: "check", title: "Contrôler le brouillon",
                                detail: "Comparer le brouillon à la demande (« \(goal.expectedResult) ») et aux données.",
                                deps: ["build"], needs: [readNeed("Brouillon", source: nil)],
                                verification: "Chaque condition de réussite est vérifiée une à une."))
            drafts.append(Draft(key: "validate", title: "Soumettre le brouillon à l'utilisateur",
                                detail: "L'utilisateur relit et valide, corrige ou refuse.", deps: ["check"],
                                verification: "Validation explicite enregistrée.", userAction: true))
            drafts.append(Draft(key: "deliver", title: "Remettre le \(deliverable.lowercased()) à \(requester)",
                                detail: "Envoi après validation, avant : \(dueText).", deps: ["validate"],
                                needs: [BrainTrust.evaluate(.sendCommunication, resource: requester, sourceID: originSourceID, grants: grants)],
                                verification: "Accusé d'envoi observé dans la source autorisée."))
        case .review:
            drafts.append(Draft(key: "locate", title: "Localiser le document concerné",
                                detail: resourceNames.isEmpty ? "Document introuvable : demander ou autoriser sa source."
                                                              : "Document(s) : " + resourceNames.joined(separator: ", ") + ".",
                                deps: [last], needs: [readNeed(resourceNames.first ?? "Fichiers locaux", source: dataSource)],
                                resources: resourceNames, verification: "Version du document identifiée.",
                                blockedReason: blockingData?.text))
            drafts.append(Draft(key: "review", title: "Relire et lister les remarques",
                                detail: "Relever points à corriger ou à valider, sans modifier le document.",
                                deps: ["locate"], needs: [readNeed("Document", source: dataSource)],
                                verification: "Liste de remarques numérotées, chacune rattachée à un passage."))
            drafts.append(Draft(key: "validate", title: "Soumettre les remarques à l'utilisateur",
                                detail: "L'utilisateur confirme ou amende les remarques.", deps: ["review"],
                                verification: "Validation explicite enregistrée.", userAction: true))
            drafts.append(Draft(key: "reply", title: "Répondre à \(requester) avec les remarques",
                                detail: "Réponse envoyée après validation.", deps: ["validate"],
                                needs: [BrainTrust.evaluate(.sendCommunication, resource: requester, sourceID: originSourceID, grants: grants)],
                                verification: "Accusé d'envoi observé."))
        case .send:
            drafts.append(Draft(key: "locate", title: "Localiser le document à envoyer",
                                detail: resourceNames.isEmpty ? "Document introuvable dans le contexte autorisé."
                                                              : "Document(s) : " + resourceNames.joined(separator: ", ") + ".",
                                deps: [last], needs: [readNeed(resourceNames.first ?? "Fichiers locaux", source: dataSource)],
                                resources: resourceNames, verification: "Bon fichier, bonne version.",
                                blockedReason: blockingData?.text))
            drafts.append(Draft(key: "validate", title: "Faire confirmer le document et le destinataire",
                                detail: "L'utilisateur confirme ce qui sera envoyé et à qui.", deps: ["locate"],
                                verification: "Validation explicite enregistrée.", userAction: true))
            drafts.append(Draft(key: "deliver", title: "Envoyer à \(requester)",
                                detail: "Envoi après validation, avant : \(dueText).", deps: ["validate"],
                                needs: [BrainTrust.evaluate(.sendCommunication, resource: requester, sourceID: originSourceID, grants: grants)],
                                verification: "Accusé d'envoi observé."))
        case .reply:
            drafts.append(Draft(key: "facts", title: "Réunir les éléments de la réponse",
                                detail: blockingData?.text ?? "Retrouver dans le contexte ce qui est nécessaire à la réponse.",
                                deps: [last], needs: [readNeed("Échange d'origine", source: originSourceID)],
                                verification: "Éléments listés avec leur provenance.", blockedReason: blockingData?.text))
            drafts.append(Draft(key: "draft", title: "Rédiger un brouillon de réponse",
                                detail: "Brouillon à destination de \(requester), non envoyé.", deps: ["facts"],
                                verification: "Le brouillon répond à chaque point de la demande."))
            drafts.append(Draft(key: "validate", title: "Soumettre le brouillon à l'utilisateur",
                                detail: "L'utilisateur relit et valide.", deps: ["draft"],
                                verification: "Validation explicite enregistrée.", userAction: true))
            drafts.append(Draft(key: "send", title: "Envoyer la réponse à \(requester)",
                                detail: "Envoi après validation.", deps: ["validate"],
                                needs: [BrainTrust.evaluate(.sendCommunication, resource: requester, sourceID: originSourceID, grants: grants)],
                                verification: "Accusé d'envoi observé."))
        }

        // États : calculés, jamais supposés.
        var steps: [PlanStep] = []
        var stateByKey: [String: StepState] = [:]
        for draft in drafts {
            var state: StepState
            var reason: String? = nil
            if draft.completed { state = .completed }
            else if draft.deps.contains(where: { stateByKey[$0] != .completed }) { state = .pending }
            else if let missingNeed = draft.needs.first(where: { $0.status == .missing }) {
                state = .blocked; reason = "Autorisation manquante : \(missingNeed.reason)"
            } else if let r = draft.blockedReason { state = .blocked; reason = r }
            else { state = .ready }
            stateByKey[draft.key] = state
            let id = BrainID.make(missionID + "|" + draft.key)
            var step = PlanStep(id: id, key: draft.key, title: draft.title, detail: draft.detail, state: state,
                                dependsOn: draft.deps.map { BrainID.make(missionID + "|" + $0) }, needs: draft.needs,
                                resources: draft.resources, verification: draft.verification, blockedReason: reason)
            if let old = previous?.steps.first(where: { $0.id == id }), [.completed, .failed, .cancelled].contains(old.state) {
                step.state = old.state; step.blockedReason = nil
                stateByKey[draft.key] = old.state
            }
            steps.append(step)
        }

        var success = ["La demande de \(requester) est satisfaite : \(goal.expectedResult)."]
        if let d = deadline { success.append("Remise avant \(BrainFormat.date(d, calendar: calendar)).") }
        success.append("L'utilisateur a validé le résultat avant toute remise externe.")
        var risks: [String] = []
        if let blockingData { risks.append(blockingData.text) }
        if deadlineConflict { risks.append("Échéance contradictoire : risque de livrer trop tard ou trop tôt.") }
        if let d = deadline, d.timeIntervalSinceNow < 24 * 3600 { risks.append("Échéance proche : peu de marge pour clarifier.") }
        if kind == .produce || kind == .send || kind == .review { risks.append("Toute remise est externe : validation obligatoire, aucun envoi automatique.") }
        let sources = Array(Set(steps.flatMap(\.needs).filter { $0.capability == .read }.compactMap(\.sourceID))).sorted()
        return MissionPlan(objective: "\(goal.expectedResult)" + (deadline.map { " — avant \(BrainFormat.date($0, calendar: calendar))" } ?? ""),
                           strategy: strategy, steps: steps, resources: resourceNames, dataSources: sources,
                           successConditions: success, risks: risks, verifications: steps.map(\.verification),
                           revision: (previous?.revision ?? 0) + 1)
    }

    /// Un plan est valide si ses identifiants sont uniques, ses dépendances existent et sans cycle.
    static func validate(_ plan: MissionPlan) -> [String] {
        var problems: [String] = []
        let ids = plan.steps.map(\.id)
        if Set(ids).count != ids.count { problems.append("Identifiants d'étapes dupliqués.") }
        let known = Set(ids)
        var seen: Set<String> = []
        for step in plan.steps {
            for dep in step.dependsOn where !known.contains(dep) || !seen.contains(dep) {
                problems.append("Dépendance invalide pour « \(step.title) ».")
            }
            seen.insert(step.id)
        }
        if plan.steps.isEmpty { problems.append("Plan vide.") }
        return problems
    }
}

// MARK: - E. UNCERTAINTY ENGINE

enum UncertaintyEngine {
    static func beliefs(event: GhostEvent, goal: Goal, analysis: Analysis, lens: ContextLens) -> [Belief] {
        let rules = Set(event.evidence.map(\.rule))
        var beliefs: [Belief] = []
        let explicit = rules.contains("request.marker") || rules.contains("request.imperative")
        beliefs.append(Belief(subject: "Demande",
                              statement: explicit ? "Une personne adresse une demande à l'utilisateur."
                                                  : "Un échange pourrait contenir une demande.",
                              level: explicit ? .known : .deduced, confidence: event.confidence,
                              provenance: event.evidence.map { $0.rule }))
        beliefs.append(Belief(subject: "Résultat attendu",
                              statement: event.expectedOutput.map { "Livrable : \($0)." } ?? "Le résultat attendu n'est pas précisé.",
                              level: event.expectedOutput != nil ? .known : .unknown,
                              confidence: event.expectedOutput != nil ? 0.9 : 0,
                              provenance: event.expectedOutput != nil ? ["task.deliverable"] : []))
        if let deadline = event.deadline {
            let explicitDeadline = rules.contains("deadline.explicit")
            beliefs.append(Belief(subject: "Échéance",
                                  statement: "« \(deadline.text) » → \(BrainFormat.date(deadline.date))",
                                  level: explicitDeadline && deadline.precision == .exact ? .known : .deduced,
                                  confidence: explicitDeadline ? 0.85 : 0.65, provenance: ["deadline"]))
        } else {
            beliefs.append(Belief(subject: "Échéance", statement: "Aucune échéance communiquée.", level: .unknown, confidence: 0, provenance: []))
        }
        if let project = lens.projects.first {
            beliefs.append(Belief(subject: "Projet", statement: "Associé au projet « \(project.title) ».",
                                  level: project.status == .confirmed ? .known : .assumed,
                                  confidence: project.confidence, provenance: ["contexte : \(project.id.prefix(8))"]))
        } else {
            beliefs.append(Belief(subject: "Projet", statement: "Aucun projet associé.", level: .unknown, confidence: 0, provenance: []))
        }
        beliefs.append(Belief(subject: "Ressources",
                              statement: analysis.resources.isEmpty ? "Aucun document pertinent dans le contexte."
                                                                    : "\(analysis.resources.count) document(s) pertinent(s).",
                              level: analysis.resources.isEmpty ? .unknown : .deduced,
                              confidence: analysis.resources.isEmpty ? 0 : 0.6,
                              provenance: analysis.resources.map(\.title)))
        beliefs.append(Belief(subject: "Autorisation d'agir",
                              statement: "Aucune autorisation d'exécuter n'a été accordée : une demande d'un tiers n'en est pas une.",
                              level: .known, confidence: 1, provenance: ["trust"]))
        return beliefs
    }

    /// Phrase honnête résumant ce que GHOST sait et ne sait pas.
    static func statement(missing: [MissingItem], conflict: Bool, confidence: Double) -> String {
        let blockers = missing.filter { $0.severity != .minor }.map { $0.text.prefix(1).lowercased() + $0.text.dropFirst() }
        if conflict { return "Je pense qu'une mission existe, mais deux sources donnent des échéances différentes : je ne choisis pas à votre place." }
        if blockers.isEmpty { return "Je pense qu'une mission existe et je dispose des éléments pour la planifier (confiance \(Int(confidence * 100)) %)." }
        return "Je pense qu'une mission existe, mais il me manque : " + blockers.joined(separator: " ; ") + "."
    }
}

// MARK: - F. TRUST (sécurité décisionnelle, indépendante des modèles)

/// Instantané des autorisations accordées par l'utilisateur, lu dans le ``TrustEngine``.
struct GrantSnapshot: Sendable {
    var grants: [String: Permission]

    static let empty = GrantSnapshot(grants: [:])

    static func load(from trust: TrustEngine) async -> GrantSnapshot {
        var map: [String: Permission] = [:]
        for grant in await trust.allGrants() { map[grant.sourceID.rawValue] = grant.permission }
        return GrantSnapshot(grants: map)
    }
}

/// Contrôle déterministe des capacités. Aucune IA ne peut le contourner :
/// seules les lectures de sources déjà autorisées sont `granted` ; toute
/// écriture ou communication est `approvalRequired` et le reste.
enum BrainTrust {
    static func evaluate(_ capability: Capability, resource: String, sourceID: String?, grants: GrantSnapshot) -> PermissionNeed {
        switch capability {
        case .read:
            guard let sourceID else {
                return PermissionNeed(capability: .read, resource: resource, sourceID: nil, status: .granted,
                                      reason: "Élément produit par GHOST dans cette mission.")
            }
            if grants.grants[sourceID] != nil {
                return PermissionNeed(capability: .read, resource: resource, sourceID: sourceID, status: .granted,
                                      reason: "Lecture de « \(sourceID) » déjà autorisée par l'utilisateur.")
            }
            let label = sourceID == "gmail" ? "boîte e-mail" : sourceID == "folder" ? "dossier local" : sourceID
            return PermissionNeed(capability: .read, resource: resource, sourceID: sourceID, status: .missing,
                                  reason: "autoriser la lecture de la source « \(label) » dans Sources")
        case .createFile, .modifyFile, .deleteFile, .sendCommunication, .externalAction:
            return PermissionNeed(capability: capability, resource: resource, sourceID: sourceID, status: .approvalRequired,
                                  reason: "\(capability.label) : validation explicite exigée au moment de l'exécution (risque \(capability.risk.rawValue)).")
        }
    }

    /// Invariant de la Mission 004 : aucune mission n'est exécutable.
    /// `READY` n'est pas une autorisation (voir ``Mission``).
    static func executionAllowed(_ mission: Mission) -> Bool { false }
}
