import Foundation

/// Interprète une observation normalisée et produit un ``GhostEvent``.
///
/// **Méthode** : règles linguistiques explicites (français et anglais) —
/// marqueurs de demande, verbes d'action, livrables, relances, marqueurs
/// informatifs — combinées à l'extraction d'échéances. Ce n'est pas un modèle
/// d'IA : chaque conclusion est accompagnée des règles qui l'ont déclenchée
/// (``Evidence``), et le niveau de confiance est un score additif documenté.
///
/// Garde-fous :
/// - un message automatisé ou explicitement informatif n'est jamais candidat mission ;
/// - un message où l'utilisateur n'est qu'en copie n'est pas candidat mission ;
/// - une mission n'est **jamais créée** : l'événement est seulement marqué
///   ``GhostEvent/isMissionCandidate`` pour les futurs moteurs.
public struct UnderstandingEngine: Sendable {
    public var deadlines: DeadlineExtractor
    /// Seuil de confiance au-delà duquel une demande devient candidate mission.
    public var missionThreshold: Double

    public init(deadlines: DeadlineExtractor = DeadlineExtractor(), missionThreshold: Double = 0.6) {
        self.deadlines = deadlines
        self.missionThreshold = missionThreshold
    }

    public func interpret(_ observation: NormalizedObservation, detectedAt: Date) -> GhostEvent {
        switch observation.content {
        case .file(let change): return interpretFile(change, observation, detectedAt: detectedAt)
        case .message: return interpretMessage(observation, detectedAt: detectedAt)
        }
    }

    // MARK: - Règles

    static let requestMarker = Pattern(#"\b(peux-tu|peux tu|pourrais-tu|pourrais tu|pouvez-vous|pouvez vous|pourriez-vous|pourriez vous|tu peux|tu pourrais|vous pouvez|vous pourriez|merci de (?!ta |ton |tes |votre |vos |ce |cette |l'|la )|je te demande|je vous demande|j'aurais besoin|j'ai besoin|il faudrait|il faut que (?:tu|vous)|n'oublie pas|n'oubliez pas|serait-il possible|serait il possible|est-ce que tu|est-ce que vous|je compte sur (?:toi|vous)|can you|could you|would you|will you|please|i need you to|would it be possible|don't forget to|make sure to|let me know)\b"#)
    /// Verbe d'action à l'impératif en début de phrase (« écris un mail à Paul », « trouve un club de boxe »), langage courant
    /// d'un message à quelqu'un. Limité à des verbes d'action explicites pour ne pas prendre une recette ou un titre pour une demande.
    static let imperativeStart = Pattern(#"^\s*(?:(?:stp|svp|s'il te pla[iî]t|alors|bon|et|ok|hey|salut|dis)[,\s]+)?(?:[A-ZÀ-Ý][\p{L}'’-]+,\s+)?(?:[ée]cris|r[ée]dige|cr[ée]e|trouve|cherche|recherche|regarde|envoie|pr[ée]pare|r[ée]serve|appelle|contacte|dessine|propose|organise|v[ée]rifie|commande|g[ée]n[èe]re|conçois|find|search|write|create|send|book|call|design)\b"#)
    static let politeness = Pattern(#"\b(stp|svp|s'il te pla[iî]t|s'il vous pla[iî]t)\b"#)
    static let secondPerson = Pattern(#"\b(tu|toi|vous|you|your|t'|te)\b|-tu\b|-vous\b"#)
    // Délimiteurs par lookaround et non `\b` : « m'envoyer », « l'envoyer » (élisions) doivent être reconnus.
    static let actionVerb = Pattern(#"(?<![\p{L}\p{N}])(pr[ée]parer|pr[ée]pare|pr[ée]parez|envoyer|envoie|envoyez|renvoyer|renvoie|transmettre|transmets|transmettez|r[ée]diger|r[ée]dige|r[ée]digez|[ée]crire|cr[ée]er|cr[ée]e|mettre à jour|mets à jour|compl[ée]ter|compl[èe]te|remplir|remplis|relire|relis|v[ée]rifier|v[ée]rifie|valider|valide|corriger|corrige|finaliser|finalise|analyser|analyse|compiler|organiser|organise|r[ée]server|r[ée]serve|appeler|appelle|rappeler|partager|partage|signer|signe|imprimer|imprime|r[ée]pondre|r[ée]ponds|regarder|jeter un (?:œil|oeil|coup d'œil|coup d'oeil)|[ée]cris|trouver|trouve|chercher|cherche|rechercher|recherche|regarde|contacter|contacte|dessiner|dessine|concevoir|conçois|g[ée]n[ée]rer|g[ée]n[èe]re|proposer|propose|noter|note|commander|commande|prepare|send|write|draft|create|update|review|find|search|look up|design|fill (?:out|in)|complete|finalize|share|schedule|book|call|check|fix|sign|print|compile|put together)(?![\p{L}\p{N}])"#)
    static let followUp = Pattern(#"\b(relance|relancer|je me permets de revenir|je reviens vers (?:toi|vous)|as-tu pu|avez-vous pu|as-tu eu le temps|avez-vous eu le temps|toujours en attente|j'attends toujours|sans nouvelles|petit rappel|following up|follow up|any update|gentle reminder|just checking in|did you get a chance|still waiting)\b"#)
    static let followUpSubject = Pattern(#"^\s*(relance|rappel|reminder|follow[- ]?up)\b"#)
    static let informational = Pattern(#"\b(pour info|pour information|pour ton information|pour votre information|fyi|à titre informatif|a titre informatif|newsletter|no action (?:is )?required|aucune action|ne pas r[ée]pondre|do not reply|unsubscribe|d[ée]sabonner|d[ée]sinscrire)\b"#)
    static let conversational = Pattern(#"^\s*(merci|thanks|thank you|super|parfait|top|génial|genial|ok|d'accord|bien reçu|bien recu|reçu|avec plaisir)\b"#)
    // Marqueurs de changement : n'alterent pas la classification, mais laissent une preuve
    // exploitable par les moteurs en aval (le corps du message n'est pas conservé).
    static let cancellation = Pattern(#"\b(annul(?:e|é|ée|er|ation)|plus besoin|finalement pas|laisse tomber|oublie ma demande|n'est plus nécessaire|inutile de|no longer needed|cancel(?:l?ed)?|never mind|disregard|ignore my previous)\b"#)
    static let acknowledgement = Pattern(#"\b(bien reçu|bien recu|merci pour (?:le fichier|l'envoi)|c'est parfait|parfait,? merci|received the file|thanks for sending|got it,? thanks)\b"#)
    static let deadlineChange = Pattern(#"\b(décalé(?:e)?|reporté(?:e)?|repoussé(?:e)?|finalement pour|nouvelle (?:échéance|date)|changement d'échéance|au lieu de|postponed|rescheduled|moved to|now due|pushed back|délai prolongé)\b"#)
    static let attachment = Pattern(#"\b(pi[eè]ce jointe|ci-joint|en pj|attached|attachment)\b"#)
    static let requiredInfo = Pattern(#"\b(?:avec|contenant|incluant|comprenant|reprenant|concernant|including|with)\s+((?:les|le|la|l'|des|du|nos|vos|tes|mes|ses|leurs|the|our|your|all)\b[^,;!?]*)"#)
    static let clauseCut = Pattern(#"\s+(pour|afin|d'ici|avant|by|before|for|stp|svp|merci)\b"#)

    static let deliverables: [(Pattern, String)] = [
        (Pattern(#"\b(fichier excel|tableur|feuille de calcul|excel|xlsx?|spreadsheet|google sheets?)\b"#), "Fichier Excel"),
        (Pattern(#"\b(pr[ée]sentation|powerpoint|pptx?|slides?|deck|keynote)\b"#), "Présentation"),
        (Pattern(#"\b(logo|ic[ôo]ne|identit[ée] visuelle|flyer|visuel|banni[èe]re)\b"#), "Logo ou visuel"),
        (Pattern(#"\b(e-?mail|courriel|mail)\b"#), "Mail"),
        (Pattern(#"\b(compte[- ]rendu|minutes|meeting notes)\b"#), "Compte rendu"),
        (Pattern(#"\b(rapport|report)\b"#), "Rapport"),
        (Pattern(#"\b(devis|quote|quotation)\b"#), "Devis"),
        (Pattern(#"\b(facture|invoice)\b"#), "Facture"),
        (Pattern(#"\b(contrat|contract)\b"#), "Contrat"),
        (Pattern(#"\b(tableau de bord|dashboard)\b"#), "Tableau de bord"),
        (Pattern(#"\b(pdf)\b"#), "Document PDF"),
        (Pattern(#"\b(document word|docx?|document)\b"#), "Document"),
        (Pattern(#"\b(budget)\b"#), "Budget")
    ]

    // MARK: - E-mails

    private func interpretMessage(_ obs: NormalizedObservation, detectedAt: Date) -> GhostEvent {
        var evidence: [Evidence] = []
        var tags: Set<GhostEventKind> = []
        var score = 0.3
        let sentences = TextTools.sentences(obs.text)
        let fullText = obs.title + "\n" + obs.text

        // 1. Demandes et questions directes.
        var requestSentence: String?
        for sentence in sentences {
            if let marker = Self.requestMarker.firstMatch(in: sentence) {
                requestSentence = requestSentence ?? sentence
                evidence.append(Evidence(rule: "request.marker", explanation: "Formule de demande « \(marker.text) »",
                                         excerpt: TextTools.excerpt(sentence)))
                break
            }
        }
        var isQuestion = false
        if requestSentence == nil,
           let question = sentences.first(where: { $0.hasSuffix("?") && Self.secondPerson.contains($0) }) {
            requestSentence = question
            isQuestion = true
            evidence.append(Evidence(rule: "request.question", explanation: "Question adressée directement au destinataire",
                                     excerpt: TextTools.excerpt(question)))
        }
        if requestSentence == nil, let direct = sentences.first(where: { Self.imperativeStart.contains($0) }) {
            requestSentence = direct
            evidence.append(Evidence(rule: "request.imperative-start", explanation: "Verbe d'action à l'impératif en début de phrase",
                                     excerpt: TextTools.excerpt(direct)))
        }
        if requestSentence == nil,
           let polite = sentences.first(where: { Self.politeness.contains($0) && Self.actionVerb.contains($0) }) {
            requestSentence = polite
            evidence.append(Evidence(rule: "request.imperative", explanation: "Formule de politesse accompagnant un verbe d'action",
                                     excerpt: TextTools.excerpt(polite)))
        }
        if requestSentence != nil {
            tags.insert(.request)
            score += isQuestion ? 0.2 : 0.3
        }

        // 2. Travail concret : verbe d'action dans la demande.
        var expectedAction: String?
        var actionClause: String?
        if let sentence = requestSentence, let verb = Self.actionVerb.firstMatch(in: sentence) {
            tags.insert(.task)
            score += 0.15
            let clause = (sentence as NSString).substring(from: verb.range.location)
            actionClause = clause
            evidence.append(Evidence(rule: "task.action-verb", explanation: "Verbe d'action « \(verb.text) » dans la demande",
                                     excerpt: TextTools.excerpt(clause)))
        }

        // 3. Échéance.
        let deadlineMatch = deadlines.bestMatch(in: requestSentence ?? fullText, reference: obs.occurredAt)
            ?? (requestSentence != nil ? deadlines.bestMatch(in: fullText, reference: obs.occurredAt) : nil)
        let deadline = deadlineMatch?.deadline
        if let match = deadlineMatch {
            tags.insert(.deadline)
            score += match.hasMarker ? 0.1 : 0.05
            evidence.append(Evidence(rule: match.hasMarker ? "deadline.explicit" : "deadline.date",
                                     explanation: "Échéance « \(match.deadline.text) » → \(Self.format(match.deadline))",
                                     excerpt: match.deadline.text))
        }

        if let clause = actionClause {
            expectedAction = Self.actionDescription(from: clause, deadline: deadline)
        } else if isQuestion {
            expectedAction = "Répondre à la question"
        } else if requestSentence != nil {
            expectedAction = "Répondre à la demande"
        }

        // 4. Résultat attendu et informations nécessaires.
        let deliverableScope = actionClause ?? requestSentence ?? ""
        let expectedOutput = Self.deliverables.first { $0.0.contains(deliverableScope) }?.1
        if let output = expectedOutput {
            score += 0.1
            evidence.append(Evidence(rule: "task.deliverable", explanation: "Livrable identifié : \(output)"))
        }
        var requiredInformation: [String] = []
        if let clause = actionClause, let info = Self.requiredInfo.firstMatch(in: clause), var phrase = info.groups[1] {
            if let deadline, let range = phrase.range(of: deadline.text, options: .caseInsensitive) {
                phrase = String(phrase[..<range.lowerBound])
            }
            if let cut = Self.clauseCut.firstMatch(in: phrase) {
                phrase = (phrase as NSString).substring(to: cut.range.location)
            }
            phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !phrase.isEmpty { requiredInformation.append(TextTools.capitalizedFirst(phrase)) }
        }
        if Self.attachment.contains(fullText) {
            requiredInformation.append("Pièce jointe mentionnée dans le message")
        }

        // 5. Relances.
        if let marker = Self.followUp.firstMatch(in: obs.text) ?? Self.followUpSubject.firstMatch(in: obs.title) {
            tags.insert(.followUp)
            score += 0.15
            evidence.append(Evidence(rule: "follow-up.marker", explanation: "Formule de relance « \(marker.text) »"))
            if expectedAction == nil { expectedAction = "Donner suite à la relance" }
        }

        // 5 bis. Annulation, accusé de réception, changement d'échéance (preuves seulement).
        for (pattern, rule, label) in [(Self.cancellation, "change.cancellation", "Formule d'annulation"),
                                       (Self.acknowledgement, "change.acknowledgement", "Accusé de réception"),
                                       (Self.deadlineChange, "change.deadline", "Changement d'échéance")] {
            if let marker = pattern.firstMatch(in: obs.text), !obs.isAutomated {
                let sentence = sentences.first { pattern.contains($0) } ?? marker.text
                evidence.append(Evidence(rule: rule, explanation: "\(label) « \(marker.text) »", excerpt: TextTools.excerpt(sentence)))
            }
        }

        // 6. Indices informatifs et automatisés.
        let infoMarker = Self.informational.firstMatch(in: fullText)
        if obs.isAutomated {
            score -= 0.4
            evidence.append(Evidence(rule: "information.automated",
                                     explanation: "Envoi automatisé (liste de diffusion ou adresse sans réponse)"))
        }
        if let marker = infoMarker {
            score -= 0.2
            evidence.append(Evidence(rule: "information.marker", explanation: "Marqueur informatif « \(marker.text) »"))
        }
        if obs.userIsDirectRecipient == false {
            score -= 0.2
            evidence.append(Evidence(rule: "recipient.copy", explanation: "L'utilisateur n'est pas destinataire direct"))
        } else if obs.userIsDirectRecipient == true {
            score += 0.05
        }

        // 7. Type principal.
        let actionable = tags.contains(.request) || tags.contains(.task) || tags.contains(.followUp)
        let primary: GhostEventKind
        if obs.isAutomated || (infoMarker != nil && !tags.contains(.request)) {
            primary = .information
            tags.insert(.information)
        } else if let first = tags.min() {
            primary = first
        } else if obs.isReply || Self.conversational.contains(obs.text) {
            primary = .conversation
            evidence.append(Evidence(rule: "conversation.reply", explanation: obs.isReply
                                     ? "Réponse dans un échange existant, sans demande" : "Message court de conversation"))
        } else {
            primary = .information
            evidence.append(Evidence(rule: "information.default", explanation: "Aucune demande, relance ni échéance détectée"))
        }
        if primary == .conversation || primary == .information, tags.isEmpty {
            score = max(score, 0.6) // confiance dans l'absence d'action
        }
        let confidence = min(0.99, max(0.05, score))
        // Texte d'écran : aucun destinataire connu, du texte de toute nature (articles, pages web…) :
        // seuil plus strict pour ne pas transformer une simple formule de politesse en mission.
        let isScreen = obs.metadata["origin"] == "screen"
        let threshold = isScreen ? max(missionThreshold, 0.75) : missionThreshold
        let isMission = actionable && primary != .information && !obs.isAutomated
            && obs.userIsDirectRecipient != false && confidence >= threshold
        if isMission {
            evidence.append(Evidence(rule: "mission.candidate",
                                     explanation: "Demande adressée à l'utilisateur, confiance \(Int(confidence * 100)) % ≥ \(Int(threshold * 100)) %"))
        }

        let sender = obs.people.first { $0.role == .sender }?.displayName
            ?? (isScreen ? "Vu dans \(obs.metadata["app"] ?? "l'écran")" : "Expéditeur inconnu")
        return GhostEvent(
            fingerprint: obs.fingerprint, kind: primary, tags: tags,
            summary: Self.summary(primary, sender: sender, title: obs.title, action: expectedAction,
                                  output: expectedOutput, deadline: deadline),
            source: obs.source, detectedAt: detectedAt, occurredAt: obs.occurredAt, title: obs.title,
            people: obs.people, expectedAction: expectedAction, expectedOutput: expectedOutput,
            requiredInformation: requiredInformation, deadline: deadline, confidence: confidence,
            evidence: evidence, isMissionCandidate: isMission, metadata: obs.metadata)
    }

    /// « préparer un fichier Excel … pour demain matin ? » → « Préparer un fichier Excel … ».
    static func actionDescription(from clause: String, deadline: Deadline?) -> String {
        var text = clause
        if let deadline, let range = text.range(of: deadline.text, options: .caseInsensitive) {
            text = String(text[..<range.lowerBound])
        }
        if let polite = politeness.firstMatch(in: text) {
            text = (text as NSString).substring(to: polite.range.location)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!.,;:")))
        return TextTools.capitalizedFirst(text)
    }

    static func summary(_ kind: GhostEventKind, sender: String, title: String, action: String?,
                        output: String?, deadline: Deadline?) -> String {
        let due = deadline.map { " — échéance : \($0.text)" } ?? ""
        switch kind {
        case .task: return "\(sender) demande : \(action ?? title)\(due)"
        case .request: return "\(sender) attend une réponse : \(title)\(due)"
        case .followUp: return "Relance de \(sender) : \(title)\(due)"
        case .deadline: return "Échéance mentionnée par \(sender) : \(title)\(due)"
        case .conversation: return "Échange avec \(sender) : \(title)"
        case .information: return "Information de \(sender) : \(title)"
        case .documentEvent: return title
        }
    }

    static func format(_ deadline: Deadline) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = deadline.precision == .exact || deadline.precision == .partOfDay
            ? "EEEE d MMMM yyyy 'à' HH'h'mm" : "EEEE d MMMM yyyy"
        return formatter.string(from: deadline.date)
    }

    // MARK: - Fichiers

    private func interpretFile(_ change: FileChange, _ obs: NormalizedObservation, detectedAt: Date) -> GhostEvent {
        let meta = change.metadata
        let label = meta.category.label
        let size = ByteCountFormatter.string(fromByteCount: meta.size, countStyle: .file)
        let verb: String
        switch change.kind {
        case .created: verb = "Nouveau fichier"
        case .modified: verb = "Fichier modifié"
        case .deleted: verb = "Fichier supprimé"
        }
        let summary = "\(verb) : \(meta.name) (\(label), \(size))"
        return GhostEvent(
            fingerprint: obs.fingerprint, kind: .documentEvent, tags: [.documentEvent], summary: summary,
            source: obs.source, detectedAt: detectedAt, occurredAt: obs.occurredAt, title: meta.name,
            confidence: 0.99,
            evidence: [Evidence(rule: "file.\(change.kind.rawValue)",
                                explanation: "\(verb) observé dans le dossier autorisé (métadonnées uniquement, contenu non lu)",
                                excerpt: change.relativePath)],
            isMissionCandidate: false, metadata: obs.metadata)
    }
}
