import Foundation
import GhostPerception
import GhostContext

/// Changement à appliquer à une mission existante.
enum MissionChange {
    case followUp
    case newDeadline(DeadlineClaim, supersede: Bool)
    case newInfo([String])
    case cancel(String)
    case complete(evidence: [String])
    case artifact(ResourceRef, resolvesDependency: Bool)
    case reopen
}

struct DecisionOutcome {
    var kind: DecisionKind
    var missionID: String?
    var dedupeKey: String
    var goal: Goal?
    var analysis: Analysis?
    var changes: [MissionChange] = []
    var reasons: [String] = []
    var alternatives: [Alternative] = []
    var uncertainties: [String] = []
    var confidence: Double = 0.5
    var used: [String] = []
    var watch: Watch?
    var removeWatchID: String?
    var initialState: MissionState?
    var clarification: String?
}

// MARK: - DECISION ENGINE

/// Choisit entre IGNORE, MONITOR, REMEMBER, CLARIFY, CREATE_MISSION,
/// UPDATE_MISSION et COMPLETE_MISSION. La capacité à ne rien faire compte
/// autant que celle d'agir : chaque garde-fou ci-dessous évite une mission inutile.
enum DecisionEngine {
    static func senderEmail(_ e: GhostEvent) -> String? {
        e.people.first { $0.role == .sender }?.email?.lowercased()
    }

    static func dedupeKey(_ input: BrainInput) -> String {
        let e = input.event
        if let thread = e.metadata["thread"], !thread.isEmpty { return input.lens.namespace + "|thread|" + thread }
        let tokens = BrainText.tokens((e.expectedAction ?? e.title) + " " + (e.expectedOutput ?? "")).sorted().joined(separator: "-")
        return input.lens.namespace + "|" + (senderEmail(e) ?? "?") + "|" + tokens
    }

    static func eventTokens(_ e: GhostEvent) -> Set<String> {
        BrainText.tokens(e.title + " " + (e.expectedAction ?? "") + " " + (e.expectedOutput ?? "") + " " + e.requiredInformation.joined(separator: " "))
    }

    static func missionTokens(_ m: Mission) -> Set<String> {
        BrainText.tokens(m.title + " " + m.goal.expectedResult + " " + m.triggers.map(\.summary).joined(separator: " "))
    }

    static func isRequester(_ email: String?, of m: Mission) -> Bool {
        guard let email else { return false }
        return m.people.contains { $0.role == "demandeur" && $0.email?.lowercased() == email }
    }

    /// Retrouve la mission déjà créée pour la même situation (dédoublonnage).
    static func findMatch(_ input: BrainInput, key: String) -> (mission: Mission, strength: Double)? {
        let e = input.event, s = input.signals
        let candidates = input.state.missions.values.filter { $0.namespace == input.lens.namespace }
        if let m = candidates.first(where: { $0.dedupeKey == key }) { return (m, 1.0) }
        if let thread = e.metadata["thread"], !thread.isEmpty,
           let m = candidates.first(where: { $0.triggers.contains { $0.threadID == thread } }) { return (m, 1.0) }
        let sender = senderEmail(e)
        let tokens = eventTokens(e)
        let followUp = e.tags.contains(.followUp)
        var best: (Mission, Double)?
        for m in candidates {
            let sameSender = isRequester(sender, of: m)
            let sim = BrainText.jaccard(tokens, missionTokens(m))
            var score = 0.0
            if sameSender && sim >= 0.5 { score = 0.7 + 0.3 * sim }
            else if sameSender && followUp && sim >= 0.2 { score = 0.65 }
            else if sameSender && (s.cancels || s.deadlineChangePhrase != nil || s.acknowledges) && sim >= 0.15 { score = 0.6 }
            if score > 0, score > (best?.1 ?? 0) { best = (m, score) }
        }
        if let best { return (best.0, best.1) }
        // Dernier recours prudent : un seul sujet ouvert avec ce demandeur et un signal de changement.
        if s.cancels || s.deadlineChangePhrase != nil {
            let open = candidates.filter { $0.isOpen && isRequester(sender, of: $0) }
            if open.count == 1 { return (open[0], 0.5) }
        }
        return nil
    }

    static func alternatives(_ chosen: DecisionKind, _ why: [DecisionKind: String]) -> [Alternative] {
        DecisionKind.allCases.filter { $0 != chosen }.compactMap { kind in why[kind].map { Alternative(kind: kind, whyRejected: $0) } }
    }

    // MARK: Décision principale

    static func decide(_ input: BrainInput) -> DecisionOutcome {
        let e = input.event, s = input.signals
        var goal = GoalEngine.formalize(input)
        let analysis = ReasoningEngine.analyze(input, goal: goal)
        goal.missingInfo = analysis.missing.map(\.text)
        goal.availableInfo += analysis.resources.map { "Document connu : \($0.title)" }
        goal.beliefs = UncertaintyEngine.beliefs(event: e, goal: goal, analysis: analysis, lens: input.lens)
        let key = dedupeKey(input)
        var out = DecisionOutcome(kind: .ignore, missionID: nil, dedupeKey: key, goal: goal, analysis: analysis,
                                  confidence: e.confidence, used: analysis.usedElements)
        out.used.append("objectif : \(goal.kind.label)")

        if input.state.suppressedKeys.contains(key) {
            out.reasons = ["La demande correspondante a été rejetée par l'utilisateur : elle n'est pas recréée."]
            out.alternatives = alternatives(.ignore, [.createMission: "Rejeté explicitement par l'utilisateur."])
            out.confidence = 0.95
            return out
        }

        let match = findMatch(input, key: key)
        if let match { out.missionID = match.mission.id; out.used.append("mission existante \(match.mission.id.prefix(8)) (correspondance \(Int(match.strength * 100)) %)") }

        switch goal.kind {
        case .cancellation: return decideCancellation(input, match: match, base: out)
        case .informationOnly, .deadline:
            if e.kind == .documentEvent { return decideFile(input, base: out) }
            return decideInformation(input, goal: goal, match: match, base: out)
        case .obligation, .intention, .needsClarification: return decideIntention(input, goal: goal, match: match, base: out)
        case .explicitRequest, .implicitObjective: return decideRequest(input, goal: goal, analysis: analysis, match: match, base: out)
        }
    }

    // MARK: Annulation

    static func decideCancellation(_ input: BrainInput, match: (mission: Mission, strength: Double)?, base: DecisionOutcome) -> DecisionOutcome {
        var out = base
        let phrase = input.signals.cancelPhrase ?? "annulation"
        guard let match, match.mission.isOpen else {
            out.kind = .ignore
            out.reasons = ["Annulation (« \(phrase) ») sans mission ouverte correspondante : rien à annuler."]
            out.alternatives = alternatives(.ignore, [.updateMission: "Aucune mission ouverte ne correspond."])
            return out
        }
        guard isRequester(senderEmail(input.event), of: match.mission) else {
            out.kind = .ignore
            out.reasons = ["Annulation reçue d'une personne qui n'est pas le demandeur : aucune annulation automatique."]
            out.uncertainties = ["L'annulation vient de quelqu'un d'autre que le demandeur d'origine."]
            out.alternatives = alternatives(.ignore, [.updateMission: "Seul le demandeur peut annuler sa demande."])
            return out
        }
        out.kind = .updateMission
        out.changes = [.cancel(phrase)]
        out.confidence = min(0.9, 0.6 + 0.3 * match.strength)
        out.reasons = ["Le demandeur annule sa demande (« \(phrase) ») dans l'échange de la mission."]
        out.alternatives = alternatives(.updateMission, [.ignore: "Une annulation du demandeur change l'objectif de la mission."])
        return out
    }

    // MARK: Information

    static func decideInformation(_ input: BrainInput, goal: Goal, match: (mission: Mission, strength: Double)?, base: DecisionOutcome) -> DecisionOutcome {
        var out = base
        let e = input.event, s = input.signals
        if let match, match.mission.isOpen || match.mission.state == .completed {
            // Accusé de réception du demandeur : preuve de bonne fin.
            if s.acknowledges, isRequester(senderEmail(e), of: match.mission), match.mission.isOpen,
               match.mission.state.canMove(to: .completed) {
                out.kind = .completeMission
                out.changes = [.complete(evidence: ["Le demandeur accuse réception (« \(s.ackPhrase ?? "") ») dans l'échange de la mission."])]
                out.confidence = 0.75
                out.reasons = ["Le demandeur confirme avoir reçu le résultat : preuve suffisante de bonne fin."]
                out.uncertainties = ["Preuve fondée sur un accusé de réception, pas sur le contenu du livrable."]
                out.alternatives = alternatives(.completeMission, [.updateMission: "Un accusé du demandeur est une preuve directe.", .ignore: "Cet accusé clôt la mission."])
                return out
            }
            let changes = diff(input, mission: match.mission, goal: goal, strength: match.strength)
            if !changes.isEmpty {
                out.kind = .updateMission; out.changes = changes
                out.confidence = min(0.9, 0.55 + 0.35 * match.strength)
                out.reasons = ["Nouvelle information liée à la mission existante : " + describe(changes)]
                out.alternatives = alternatives(.updateMission, [.ignore: "L'information modifie la mission.", .createMission: "Une mission correspondante existe déjà."])
                return out
            }
        }
        let known = input.lens.priorInteractions(email: senderEmail(e)) >= 2
        if s.isAutomated {
            out.reasons = ["Message automatisé ou informatif : aucune intervention nécessaire."]
            out.alternatives = alternatives(.ignore, [.remember: "Envoi automatisé sans valeur durable.", .createMission: "Aucune demande adressée à l'utilisateur."])
            out.confidence = 0.9
            return out
        }
        if e.deadline != nil || e.tags.contains(.deadline) || known {
            out.kind = .remember
            out.reasons = ["Information utile à conserver" + (e.deadline.map { " (échéance « \($0.text) »)" } ?? " (interlocuteur connu)") + " ; aucune action demandée."]
            out.alternatives = alternatives(.remember, [.createMission: "Aucune demande ni obligation adressée à l'utilisateur.", .ignore: "L'information peut servir plus tard."])
            out.confidence = max(0.6, e.confidence)
        } else {
            out.reasons = ["Information sans action attendue et sans valeur durable identifiée."]
            out.alternatives = alternatives(.ignore, [.createMission: "Aucune demande ni obligation.", .remember: "Rien de réutilisable : pas d'échéance, interlocuteur inconnu."])
            out.confidence = max(0.6, e.confidence)
        }
        return out
    }

    // MARK: Fichiers

    static func decideFile(_ input: BrainInput, base: DecisionOutcome) -> DecisionOutcome {
        var out = base
        let e = input.event
        let name = e.title
        let ext = (name as NSString).pathExtension.lowercased()
        let fileTokens = BrainText.tokens(name + " " + (e.metadata["path"] ?? ""))
        let created = e.metadata["change"] != "deleted"
        let candidates = input.state.missions.values.filter { $0.namespace == input.lens.namespace && !$0.state.isTerminal }
        var best: (Mission, [String], Int)?
        for m in candidates {
            var evidence: [String] = []
            let missionWords = BrainText.tokens(m.title + " " + m.goal.expectedResult + " " + (m.goal.deliverable ?? ""))
                .subtracting(["fichier", "excel", "document", "rapport"])
            let overlap = fileTokens.intersection(missionWords)
            if !overlap.isEmpty { evidence.append("Nom proche de la mission : " + overlap.sorted().joined(separator: ", ")) }
            if let d = m.goal.deliverable, matches(ext: ext, deliverable: d) { evidence.append("Type de fichier (.\(ext)) conforme au livrable « \(d) »") }
            if e.occurredAt >= m.createdAt { evidence.append("Fichier apparu après la création de la mission") }
            if let pid = m.goal.projectID, input.lens.graph.relations.values.contains(where: { $0.kind == .documentBelongsToProject && $0.to == pid && input.lens.graph.nodes[$0.from]?.properties["path"] == e.metadata["path"] }) {
                evidence.append("Fichier rattaché au projet de la mission")
            }
            if !overlap.isEmpty, evidence.count > (best?.2 ?? 0) { best = (m, evidence, evidence.count) }
        }
        guard created, let (mission, evidence, count) = best else {
            let linked = input.lens.projects.first != nil
            out.kind = linked ? .remember : .ignore
            out.reasons = [linked ? "Document rattaché à un projet connu : conservé dans la mémoire." : "Fichier sans lien avec une mission ni un projet connus."]
            out.alternatives = alternatives(out.kind, [.createMission: "Un fichier seul n'exprime aucune demande.", .updateMission: "Aucune mission ne correspond."])
            out.confidence = 0.7
            return out
        }
        let ref = ResourceRef(nodeID: input.lens.eventNode?.id ?? "", title: name, path: e.metadata["path"], sourceID: e.source.id.rawValue,
                              why: evidence.joined(separator: " ; "))
        out.missionID = mission.id
        let waitingForData = mission.missingInfo.contains { $0.severity == .block }
        if waitingForData {
            // Le fichier est probablement une source de données attendue : dépendance résolue.
            out.kind = .updateMission
            out.changes = [.artifact(ref, resolvesDependency: true)]
            out.confidence = min(0.85, 0.5 + 0.1 * Double(count))
            out.reasons = ["Un document attendu par la mission est apparu : \(name).", "Preuves : " + evidence.joined(separator: " ; ")]
            out.uncertainties = ["Je suppose que ce fichier est la source de données attendue ; à confirmer."]
        } else if count >= 3 {
            out.kind = .completeMission
            out.changes = [.complete(evidence: evidence)]
            out.confidence = min(0.85, 0.5 + 0.1 * Double(count))
            out.reasons = ["Un fichier correspondant au livrable est apparu : \(name).", "Preuves : " + evidence.joined(separator: " ; ")]
            out.uncertainties = ["Le contenu du fichier n'a pas été lu : seule sa présence est observée."]
        } else {
            out.kind = .updateMission
            out.changes = [.artifact(ref, resolvesDependency: false)]
            out.confidence = 0.55
            out.reasons = ["Fichier possiblement lié à la mission, preuves insuffisantes pour la terminer (\(count)/3)."]
            out.uncertainties = ["Preuves insuffisantes pour conclure à la bonne fin."]
        }
        out.alternatives = alternatives(out.kind, [.ignore: "Le fichier est lié à une mission ouverte."])
        return out
    }

    static func matches(ext: String, deliverable: String) -> Bool {
        switch deliverable {
        case "Fichier Excel", "Budget", "Tableau de bord": return ["xls", "xlsx", "csv", "numbers"].contains(ext)
        case "Présentation": return ["ppt", "pptx", "key"].contains(ext)
        case "Document PDF": return ext == "pdf"
        case "Rapport", "Contrat", "Devis", "Facture", "Compte rendu", "Document": return ["doc", "docx", "pdf", "pages", "txt", "md"].contains(ext)
        default: return false
        }
    }

    // MARK: Intention / obligation

    static func decideIntention(_ input: BrainInput, goal: Goal, match: (mission: Mission, strength: Double)?, base: DecisionOutcome) -> DecisionOutcome {
        var out = base
        let e = input.event, s = input.signals
        if let match {
            let changes = diff(input, mission: match.mission, goal: goal, strength: match.strength)
            if !changes.isEmpty {
                out.kind = .updateMission; out.changes = changes
                out.confidence = min(0.85, 0.5 + 0.35 * match.strength)
                out.reasons = ["Information supplémentaire sur une mission existante : " + describe(changes)]
                out.alternatives = alternatives(.updateMission, [.ignore: "L'information modifie la mission.", .createMission: "Une mission correspondante existe déjà."])
                return out
            }
            out.reasons = ["Doublon d'une mission existante (\(match.mission.title)) : rien de nouveau."]
            out.alternatives = alternatives(.ignore, [.createMission: "Créerait un doublon.", .updateMission: "Aucune information nouvelle."])
            out.confidence = 0.85
            return out
        }
        var reasons: [String] = []
        if let phrase = s.vaguePhrase { reasons.append("Échéance vague (« \(phrase) »)") }
        if let obj = s.vagueObject { reasons.append("objet indéterminé (« \(obj) »)") }
        if s.collective { reasons.append("formulation collective, sans destinataire précis") }
        if e.expectedOutput == nil { reasons.append("aucun résultat attendu identifié") }
        if e.deadline == nil { reasons.append("aucune échéance") }
        let question = goal.kind == .obligation ? "Cette obligation vous concerne-t-elle, et qu'attend-on de vous exactement ?"
                                                 : "Que faut-il regarder exactement, et pour quand ?"
        out.kind = .monitor
        out.watch = makeWatch(input, reason: reasons.joined(separator: ", "), question: question)
        out.reasons = ["Intention possible mais insuffisamment précise pour justifier une mission : " + reasons.joined(separator: " ; ") + "."]
        out.uncertainties = ["Je pense qu'une demande existe, mais il me manque ce qui est attendu et pour quand."]
        out.clarification = question
        out.confidence = 0.7
        out.alternatives = alternatives(.monitor, [
            .createMission: "Objectif, résultat et échéance ne sont pas établis : une mission serait une interprétation excessive.",
            .ignore: "Le message adresse peut-être une demande réelle à l'utilisateur.",
            .clarify: "Aucune mission n'existe encore à clarifier ; la situation est seulement surveillée."])
        return out
    }

    // MARK: Demande explicite

    static func decideRequest(_ input: BrainInput, goal: Goal, analysis: Analysis, match: (mission: Mission, strength: Double)?, base: DecisionOutcome) -> DecisionOutcome {
        var out = base
        let e = input.event
        if let match {
            var changes = diff(input, mission: match.mission, goal: goal, strength: match.strength)
            if match.mission.state.isTerminal, !changes.contains(where: { if case .cancel = $0 { return true } else { return false } }) {
                changes.insert(.reopen, at: 0)
            }
            if !changes.isEmpty {
                out.kind = .updateMission; out.changes = changes
                out.confidence = min(0.9, 0.55 + 0.35 * match.strength)
                out.reasons = ["Cette demande correspond à la mission « \(match.mission.title) » : " + describe(changes)]
                out.alternatives = alternatives(.updateMission, [.createMission: "Une mission pour la même situation existe : aucun doublon.", .ignore: "Le message apporte du nouveau."])
                return out
            }
            out.kind = .ignore
            out.reasons = ["Doublon de la mission « \(match.mission.title) » : aucune information nouvelle."]
            out.alternatives = alternatives(.ignore, [.createMission: "Créerait un doublon.", .updateMission: "Rien de nouveau à ajouter."])
            out.confidence = 0.85
            return out
        }
        var confidence = goal.confidence
        if !analysis.contradictions.isEmpty { confidence -= 0.05 }
        confidence = max(0.05, min(0.99, confidence))
        out.confidence = confidence

        // Une watch antérieure sur le même fil est fusionnée dans la mission.
        if let watch = input.state.watches.values.first(where: { $0.namespace == input.lens.namespace && (($0.threadID != nil && $0.threadID == e.metadata["thread"]) || ($0.senderEmail != nil && $0.senderEmail == senderEmail(e))) }) {
            out.removeWatchID = watch.id
            out.reasons.append("Une surveillance antérieure du même échange est fusionnée.")
        }
        guard e.isMissionCandidate, confidence >= input.config.missionThreshold else {
            out.kind = .monitor
            out.reasons.append("Confiance insuffisante (\(Int(confidence * 100)) % < \(Int(input.config.missionThreshold * 100)) %) pour créer une mission ferme.")
            out.alternatives = alternatives(.monitor, [.createMission: "Confiance trop faible.", .ignore: "Une demande est probable."])
            return out
        }
        let clarifyItem = analysis.clarifyMissing.first
        if let clarifyItem {
            out.kind = .clarify
            out.initialState = .needsClarification
            out.clarification = question(for: clarifyItem)
            out.reasons.append("Demande détectée, mais une information essentielle manque : \(clarifyItem.text.lowercased()).")
            out.uncertainties = ["Je pense qu'une mission existe, mais il me manque : \(clarifyItem.text.lowercased())."]
            out.alternatives = alternatives(.clarify, [.createMission: "L'objectif n'est pas assez précis pour planifier.", .ignore: "La demande est adressée à l'utilisateur."])
        } else {
            out.kind = .createMission
            out.initialState = analysis.blockingMissing.isEmpty ? .proposed : .blocked
            out.reasons.append("Demande explicite adressée à l'utilisateur (confiance \(Int(confidence * 100)) %).")
            if let output = e.expectedOutput { out.reasons.append("Résultat attendu identifié : \(output).") }
            if let d = e.deadline { out.reasons.append("Échéance extraite : « \(d.text) ».") }
            if !analysis.resources.isEmpty { out.reasons.append("\(analysis.resources.count) document(s) pertinent(s) retrouvé(s) dans le contexte.") }
            for b in analysis.blockingMissing { out.uncertainties.append(b.text) }
            out.alternatives = alternatives(.createMission, [
                .ignore: "Une demande explicite avec résultat attendu mérite d'être suivie.",
                .monitor: "Objectif et résultat suffisamment établis : surveiller serait insuffisant.",
                .remember: "Il s'agit d'une demande, pas d'une simple information."])
        }
        return out
    }

    static func makeWatch(_ input: BrainInput, reason: String, question: String) -> Watch {
        let e = input.event
        let thread = e.metadata["thread"]
        let sender = senderEmail(e)
        let id = BrainID.make("watch|" + input.lens.namespace + "|" + (thread ?? (sender ?? "?") + "|" + eventTokens(e).sorted().joined(separator: "-")))
        return Watch(id: id, sourceID: e.source.id.rawValue, eventID: e.id, threadID: thread, senderEmail: sender,
                     namespace: input.lens.namespace, summary: e.summary, reason: reason, clarificationQuestion: question, createdAt: input.now)
    }

    static func question(for item: MissingItem) -> String {
        if item.text.hasPrefix("Livrable") { return "Quel est le livrable attendu (format, contenu) ?" }
        return "Pouvez-vous préciser : \(item.text.lowercased()) ?"
    }

    // MARK: Différences avec une mission existante

    static func diff(_ input: BrainInput, mission: Mission, goal: Goal, strength: Double) -> [MissionChange] {
        let e = input.event, s = input.signals
        guard !mission.triggers.contains(where: { $0.fingerprint == e.fingerprint && $0.sourceID == e.source.id.rawValue }) else { return [] }
        var changes: [MissionChange] = []
        if e.tags.contains(.followUp) { changes.append(.followUp) }
        if let d = e.deadline {
            let active = mission.deadlineClaims.filter { !$0.superseded }
            let alreadyKnown = active.contains { abs($0.date.timeIntervalSince(d.date)) < 6 * 3600 }
            if !alreadyKnown {
                // Seul l'auteur des assertions actuelles (le demandeur) peut les remplacer.
                // Une autre personne, même dans le même fil, crée une contradiction conservée.
                let sameAuthor = !active.isEmpty && active.allSatisfy { $0.senderEmail == senderEmail(e) }
                let supersede = sameAuthor && (s.deadlineChangePhrase != nil || isRequester(senderEmail(e), of: mission) || strength >= 0.6)
                let claim = DeadlineClaim(date: d.date, text: d.text, sourceID: e.source.id.rawValue, sourceName: e.source.displayName,
                                          eventID: e.id, senderEmail: senderEmail(e), assertedAt: e.occurredAt)
                changes.append(.newDeadline(claim, supersede: supersede || active.isEmpty))
            }
        }
        let known = Set(mission.goal.availableInfo)
        let fresh = e.requiredInformation.map { "Information mentionnée : \($0)" }.filter { !known.contains($0) }
        if !fresh.isEmpty { changes.append(.newInfo(fresh)) }
        return changes
    }

    static func describe(_ changes: [MissionChange]) -> String {
        changes.map { change -> String in
            switch change {
            case .followUp: return "relance reçue"
            case .newDeadline(let c, let supersede): return supersede ? "échéance modifiée (« \(c.text) »)" : "échéance divergente (« \(c.text) ») conservée à côté de l'existante"
            case .newInfo: return "nouvelles informations"
            case .cancel(let p): return "annulation (« \(p) »)"
            case .complete: return "preuves de bonne fin"
            case .artifact(let r, let resolves): return resolves ? "dépendance résolue (\(r.title))" : "fichier lié (\(r.title))"
            case .reopen: return "demande rouverte"
            }
        }.joined(separator: " ; ")
    }
}
