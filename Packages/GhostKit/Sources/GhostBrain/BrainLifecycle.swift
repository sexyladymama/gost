import Foundation
import GhostPerception
import GhostContext

/// Cycle de vie d'une mission : création, actualisation, annulation, bonne fin.
/// Toute modification laisse une trace dans l'historique ; rien n'est effacé en silence.
enum MissionLifecycle {

    static func trigger(for e: GhostEvent) -> TriggerRef {
        TriggerRef(eventID: e.id, fingerprint: e.fingerprint, kind: e.kind, sourceID: e.source.id.rawValue,
                   sourceName: e.source.displayName, summary: e.summary, threadID: e.metadata["thread"],
                   detectedAt: e.detectedAt, occurredAt: e.occurredAt, senderEmail: DecisionEngine.senderEmail(e),
                   signalText: String(BrainSignals.read(e).text.prefix(600)),
                   excerpt: e.evidence.first { $0.rule.hasPrefix("request.") }?.excerpt)
    }

    // MARK: Création

    /// Titre lisible : l'action extraite, sauf si elle est générique (« Répondre à la demande »).
    static func missionTitle(_ e: GhostEvent) -> String {
        guard let action = e.expectedAction, !action.isEmpty else { return e.title }
        let generic = ["Répondre à la demande", "Répondre à la question", "Donner suite à la relance"]
        return generic.contains(action) ? "\(action.replacingOccurrences(of: " à la demande", with: "").replacingOccurrences(of: " à la question", with: "")) : \(e.title)" : action
    }

    static func create(_ outcome: DecisionOutcome, input: BrainInput, decisionID: UUID) -> Mission? {
        guard let goal = outcome.goal, let analysis = outcome.analysis else { return nil }
        let e = input.event, now = input.now
        let id = BrainID.make("mission|" + outcome.dedupeKey)
        let sender = DecisionEngine.senderEmail(e)
        let senderName = e.people.first { $0.role == .sender }?.displayName ?? ""
        let project = input.lens.projects.first
        let preferences = input.lens.preferences(matching: [senderName, sender ?? "", sender?.split(separator: "@").last.map(String.init) ?? "", project?.title ?? ""])
        let context = PriorityContext(
            senderInteractions: max(0, input.lens.priorInteractions(email: sender) - 1),
            projectConfirmed: project?.status == .confirmed,
            preferenceBoost: min(0.3, 0.15 * Double(preferences.count)),
            preferenceNotes: preferences.map(\.title))
        let claim = e.deadline.map {
            DeadlineClaim(date: $0.date, text: $0.text, sourceID: e.source.id.rawValue, sourceName: e.source.displayName,
                          eventID: e.id, senderEmail: sender, assertedAt: e.occurredAt)
        }
        var mission = Mission(
            id: id, schemaVersion: BrainSchema.version,
            title: String(Self.missionTitle(e).prefix(140)), summary: e.summary, goal: goal,
            originSourceID: e.source.id.rawValue, originSourceName: e.source.displayName,
            triggers: [trigger(for: e)], contextRefs: input.lens.contextRefs,
            people: goal.people, deadline: goal.deadline, deadlineClaims: claim.map { [$0] } ?? [], deadlineConflict: false,
            priority: PriorityAssessment(level: .normal, score: 0, factors: [], notes: [], computedAt: now),
            userPriority: nil, confidence: outcome.confidence,
            plan: MissionPlan(objective: "", strategy: "", steps: [], resources: [], dataSources: [], successConditions: [], risks: [], verifications: [], revision: 0),
            permissions: [], successConditions: [], risks: [], missingInfo: analysis.missing,
            clarificationQuestion: outcome.clarification, beliefs: goal.beliefs, workKind: analysis.workKind,
            resources: analysis.resources.map { ResourceRef(nodeID: $0.nodeID, title: $0.title, path: $0.path, sourceID: $0.sourceID, why: $0.why) },
            priorityContext: context, state: .detected, history: [], decisionIDs: [decisionID], dedupeKey: outcome.dedupeKey,
            namespace: input.lens.namespace, isSimulated: e.source.isSimulated, verdict: .none, notes: [],
            createdAt: now, updatedAt: now)
        mission.history.append(HistoryEntry(date: now, kind: "detected", summary: "Situation détectée dans « \(e.source.displayName) » : \(e.summary)", decisionID: decisionID))
        mission.state = .analyzing
        mission.history.append(HistoryEntry(date: now, kind: "analyzing", summary: "Analyse du contexte, des ressources et des permissions.", decisionID: decisionID))
        if let removed = outcome.removeWatchID, let watch = input.state.watches[removed] {
            mission.history.append(HistoryEntry(date: now, kind: "merged-watch", summary: "Surveillance antérieure fusionnée : \(watch.summary)", decisionID: decisionID))
        }
        refresh(&mission, grants: input.grants, now: now, calendar: input.config.calendar, preferredState: outcome.initialState,
                reason: outcome.reasons.first ?? "Mission créée", decisionID: decisionID)
        return mission
    }

    // MARK: Actualisation

    static func apply(_ outcome: DecisionOutcome, to original: Mission, input: BrainInput, decisionID: UUID) -> Mission {
        var m = original
        let e = input.event, now = input.now
        func log(_ kind: String, _ summary: String, before: String? = nil, after: String? = nil) {
            m.history.append(HistoryEntry(date: now, kind: kind, summary: summary, decisionID: decisionID, before: before, after: after))
        }
        var preferred: MissionState?
        for change in outcome.changes {
            switch change {
            case .reopen:
                let before = m.state.label
                m.state = .proposed
                log("reopened", "Demande rouverte par un nouveau message.", before: before, after: m.state.label)
                m.triggers.append(trigger(for: e))
            case .followUp:
                m.triggers.append(trigger(for: e))
                let n = m.triggers.filter { $0.kind == .followUp }.count
                log("follow-up", "Relance reçue (\(n)) : \(e.summary)")
            case .newDeadline(let claim, let supersede):
                if !m.triggers.contains(where: { $0.eventID == e.id }) { m.triggers.append(trigger(for: e)) }
                let before = m.deadline.map { BrainFormat.date($0, calendar: input.config.calendar) } ?? "aucune"
                if supersede {
                    for i in m.deadlineClaims.indices { m.deadlineClaims[i].superseded = true }
                    m.deadlineClaims.append(claim)
                    m.deadline = claim.date
                    m.deadlineConflict = false
                    m.missingInfo.removeAll { $0.text.hasPrefix("Échéances contradictoires") }
                    log("deadline", "Échéance modifiée : « \(claim.text) » (source : \(claim.sourceName)). L'ancienne assertion est conservée.",
                        before: before, after: BrainFormat.date(claim.date, calendar: input.config.calendar))
                } else {
                    m.deadlineClaims.append(claim)
                    m.deadlineConflict = true
                    m.deadline = nil
                    let active = m.deadlineClaims.filter { !$0.superseded }
                    let list = active.map { "\(BrainFormat.date($0.date, calendar: input.config.calendar)) (\($0.sourceName))" }.joined(separator: " / ")
                    m.missingInfo.removeAll { $0.text.hasPrefix("Échéances contradictoires") }
                    m.missingInfo.append(MissingItem(text: "Échéances contradictoires : \(list)", severity: .clarify))
                    m.clarificationQuestion = "Deux échéances différentes ont été communiquées. Laquelle est la bonne ?"
                    log("deadline-conflict", "Échéances contradictoires conservées : \(list). Aucune échéance définitive n'est retenue.", before: before, after: "indéterminée")
                    preferred = .needsClarification
                }
            case .newInfo(let infos):
                if !m.triggers.contains(where: { $0.eventID == e.id }) { m.triggers.append(trigger(for: e)) }
                m.goal.availableInfo += infos
                log("info", "Informations ajoutées : " + infos.joined(separator: " ; "))
            case .cancel(let phrase):
                if !m.triggers.contains(where: { $0.eventID == e.id }) { m.triggers.append(trigger(for: e)) }
                let before = m.state.label
                m.state = .cancelled
                for i in m.plan.steps.indices where [.pending, .ready, .blocked].contains(m.plan.steps[i].state) { m.plan.steps[i].state = .cancelled }
                log("cancelled", "Mission annulée : le demandeur a retiré sa demande (« \(phrase) »).", before: before, after: m.state.label)
            case .complete(let evidence):
                if !m.triggers.contains(where: { $0.eventID == e.id }) { m.triggers.append(trigger(for: e)) }
                let before = m.state.label
                m.state = .completed
                log("completed", "Mission considérée comme terminée sur preuves : " + evidence.joined(separator: " ; ") + ". (Non exécutée par GHOST.)", before: before, after: m.state.label)
            case .artifact(let ref, let resolves):
                if !m.resources.contains(where: { $0.title == ref.title && $0.path == ref.path }) { m.resources.append(ref) }
                if resolves {
                    m.missingInfo.removeAll { $0.severity == .block && ($0.text.hasPrefix("Données sources introuvables") || $0.text.hasPrefix("Document concerné introuvable")) }
                    log("dependency", "Dépendance résolue : « \(ref.title) » est apparu (\(ref.why)).")
                } else {
                    log("artifact", "Fichier possiblement lié : « \(ref.title) » (\(ref.why)).")
                }
            }
        }
        m.decisionIDs.append(decisionID)
        if m.state.isTerminal && !outcome.changes.contains(where: { if case .reopen = $0 { return true } else { return false } }) {
            m.updatedAt = now
            return m
        }
        refresh(&m, grants: input.grants, now: now, calendar: input.config.calendar, preferredState: preferred,
                reason: outcome.reasons.first ?? "Mission actualisée", decisionID: decisionID)
        return m
    }

    // MARK: Recalcul

    /// Reconstruit plan, priorité, permissions et état à partir des faits de la mission.
    static func refresh(_ m: inout Mission, grants: GrantSnapshot, now: Date, calendar: Calendar,
                        preferredState: MissionState? = nil, reason: String, decisionID: UUID?) {
        guard !m.state.isTerminal else { return }
        let activeDeadlines = m.deadlineClaims.filter { !$0.superseded }.map(\.date)
        let effectiveDeadline = m.deadline ?? activeDeadlines.min()   // prudence : la plus proche
        m.plan = PlanningEngine.build(missionID: m.id, goal: m.goal, kind: m.workKind, resources: m.resources,
                                      missing: m.missingInfo, strategy: m.plan.strategy.isEmpty ? strategyName(m) : m.plan.strategy,
                                      deadline: m.deadline, deadlineConflict: m.deadlineConflict, grants: grants,
                                      originSourceID: m.originSourceID, previous: m.plan.revision == 0 ? nil : m.plan, calendar: calendar)
        var seen = Set<String>()
        m.permissions = m.plan.steps.flatMap(\.needs).filter { seen.insert("\($0.capability.rawValue)|\($0.resource)|\($0.sourceID ?? "")").inserted }
        m.successConditions = m.plan.successConditions
        m.risks = m.plan.risks

        let before = m.priority.level
        let hadPriority = !m.priority.factors.isEmpty
        let text = ([m.title, m.summary] + m.triggers.map(\.summary) + m.triggers.map(\.signalText)).joined(separator: " ")
        m.priority = PriorityEngine.assess(
            deadline: effectiveDeadline, conflict: m.deadlineConflict, text: text, kind: m.workKind,
            deliverable: m.goal.deliverable, context: m.priorityContext,
            followUps: m.triggers.filter { $0.kind == .followUp }.count,
            missingCount: m.missingInfo.filter { $0.severity != .minor }.count,
            totalInfo: m.goal.availableInfo.count + m.missingInfo.filter { $0.severity != .minor }.count, now: now)
        if hadPriority, m.priority.level != before {
            m.history.append(HistoryEntry(date: now, kind: "priority", summary: "Priorité recalculée : \(before.label) → \(m.priority.level.label).",
                                          decisionID: decisionID, before: before.label, after: m.priority.level.label))
        }
        m.beliefs = refreshedBeliefs(m, calendar: calendar)

        // État : jamais READY sans confirmation de l'utilisateur ni lorsqu'un blocage subsiste.
        let missingPermission = m.plan.steps.contains { $0.state == .blocked && $0.needs.contains { $0.status == .missing } }
        var desired: MissionState
        if m.deadlineConflict || m.missingInfo.contains(where: { $0.severity == .clarify }) { desired = .needsClarification }
        else if m.missingInfo.contains(where: { $0.severity == .block }) || missingPermission { desired = .blocked }
        else if m.verdict == .confirmed { desired = .ready }
        else { desired = .proposed }
        if let preferredState, preferredState == .needsClarification, desired == .proposed { desired = preferredState }
        if m.state == .inProgress { desired = .inProgress }
        transition(&m, to: desired, now: now, reason: reason, decisionID: decisionID)
        m.updatedAt = now
    }

    static func strategyName(_ m: Mission) -> String {
        switch m.workKind {
        case .produce: return m.resources.isEmpty ? "rassembler les données d'abord" : "produire à partir du contexte"
        case .review: return "relire puis soumettre les remarques"
        case .send: return "localiser, faire confirmer, envoyer"
        case .reply: return "répondre directement"
        }
    }

    static func transition(_ m: inout Mission, to next: MissionState, now: Date, reason: String, decisionID: UUID?, byUser: Bool = false) {
        guard m.state != next, m.state.canMove(to: next) else { return }
        let from = m.state
        m.state = next
        m.history.append(HistoryEntry(date: now, kind: "state", summary: "\(from.label) → \(next.label) : \(reason)",
                                      decisionID: decisionID, before: from.label, after: next.label, byUser: byUser))
    }

    static func refreshedBeliefs(_ m: Mission, calendar: Calendar) -> [Belief] {
        var beliefs = m.beliefs.filter { !["Échéance", "Ressources"].contains($0.subject) }
        if m.deadlineConflict {
            beliefs.append(Belief(subject: "Échéance", statement: "Plusieurs échéances divergentes : aucune n'est retenue.", level: .unknown, confidence: 0,
                                  provenance: m.deadlineClaims.filter { !$0.superseded }.map(\.sourceName)))
        } else if let d = m.deadline, let claim = m.deadlineClaims.last(where: { !$0.superseded }) {
            beliefs.append(Belief(subject: "Échéance", statement: "« \(claim.text) » → \(BrainFormat.date(d, calendar: calendar))", level: .deduced,
                                  confidence: 0.75, provenance: [claim.sourceName]))
        } else {
            beliefs.append(Belief(subject: "Échéance", statement: "Aucune échéance communiquée.", level: .unknown, confidence: 0, provenance: []))
        }
        beliefs.append(Belief(subject: "Ressources",
                              statement: m.resources.isEmpty ? "Aucun document pertinent dans le contexte." : "\(m.resources.count) document(s) pertinent(s).",
                              level: m.resources.isEmpty ? .unknown : .deduced, confidence: m.resources.isEmpty ? 0 : 0.6,
                              provenance: m.resources.map(\.title)))
        return beliefs
    }

    // MARK: Validation stricte

    /// Invariants vérifiés avant toute écriture.
    static func validate(_ m: Mission) -> [String] {
        var problems: [String] = []
        if m.id.isEmpty { problems.append("Identifiant vide.") }
        if m.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Titre vide.") }
        if m.triggers.isEmpty { problems.append("Aucun événement déclencheur.") }
        if !(0...1).contains(m.confidence) { problems.append("Confiance hors de [0, 1].") }
        if m.deadlineConflict && m.deadline != nil { problems.append("Échéance définitive malgré une contradiction.") }
        if m.state == .ready && (m.missingInfo.contains { $0.severity != .minor } || m.deadlineConflict) { problems.append("READY avec des blocages.") }
        if m.state == .ready && m.verdict != .confirmed { problems.append("READY sans confirmation de l'utilisateur.") }
        if !m.state.isTerminal { problems += PlanningEngine.validate(m.plan) }
        if m.history.isEmpty { problems.append("Historique vide.") }
        return problems
    }
}
