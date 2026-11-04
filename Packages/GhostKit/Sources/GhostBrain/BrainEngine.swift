import Foundation
import GhostPerception
import GhostContext

public enum BrainUpdate: Sendable { case snapshot(BrainState), issue(String) }

/// Cerveau décisionnel de GHOST. Consomme les événements de PERCEPTION, les
/// enrichit via CONTEXT, décide, crée ou actualise des missions — et **n'exécute rien**.
///
/// Propriétés :
/// - **événementiel** : aucune boucle ; un événement est analysé une seule fois (registre) ;
/// - **idempotent et résistant aux pannes** : mission, décision et registre sont écrits
///   dans la même transaction atomique ; l'identifiant d'une mission est déterministe ;
/// - **pause** : inactif, il ne traite rien ; à la reprise, `catchUp` rejoue sans doublon.
public actor BrainEngine: PerceptionEventConsumer {
    public nonisolated let updates: AsyncStream<BrainUpdate>
    private let continuation: AsyncStream<BrainUpdate>.Continuation
    private let context: ContextEngine
    private let trust: TrustEngine
    private let store: MissionStore
    private let gateway: ModelGateway?
    private let clock: @Sendable () -> Date
    private let config: BrainConfig
    public private(set) var isActive: Bool
    public private(set) var lastError: String?
    public private(set) var deferredCount = 0
    private var lastReevaluation: Date?
    static let reevaluationInterval: TimeInterval = 15 * 60

    public init(profile: GhostProfile, context: ContextEngine, trust: TrustEngine, gateway: ModelGateway? = nil,
                persistent: Bool = true, config: BrainConfig = BrainConfig(), startsActive: Bool = true,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.context = context; self.trust = trust; self.gateway = gateway
        self.config = config; self.clock = clock; self.isActive = startsActive
        store = MissionStore(url: persistent ? profile.directory.appendingPathComponent("missions.json") : nil)
        (updates, continuation) = AsyncStream.makeStream(of: BrainUpdate.self, bufferingPolicy: .bufferingNewest(20))
    }
    deinit { continuation.finish() }

    init(store: MissionStore, context: ContextEngine, trust: TrustEngine, gateway: ModelGateway? = nil,
         config: BrainConfig = BrainConfig(), startsActive: Bool = true, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.context = context; self.trust = trust; self.gateway = gateway
        self.config = config; self.clock = clock; self.isActive = startsActive
        (updates, continuation) = AsyncStream.makeStream(of: BrainUpdate.self, bufferingPolicy: .bufferingNewest(20))
    }

    // MARK: Cycle de vie

    /// Pause / arrêt : plus aucun traitement proactif. Les missions enregistrées restent intactes.
    public func setActive(_ active: Bool) { isActive = active }

    public func consume(_ events: [GhostEvent]) async {
        guard isActive else { deferredCount += events.count; return }
        do { _ = try await process(events) } catch { report(error) }
    }

    /// Reprise : rejoue les événements non encore analysés (registre → aucun doublon).
    public func catchUp(_ events: [GhostEvent]) async {
        guard isActive else { return }
        do { _ = try await process(events); deferredCount = 0 } catch { report(error) }
    }

    public func snapshot() async throws -> BrainState { try await store.snapshot() }

    // MARK: Traitement

    static func ledgerKey(_ e: GhostEvent) -> String { e.source.id.rawValue + "|" + e.fingerprint }

    @discardableResult
    public func process(_ events: [GhostEvent]) async throws -> [DecisionRecord] {
        _ = try await store.snapshot()   // échoue ici si le stockage est illisible
        var records: [DecisionRecord] = []
        let ordered = events.sorted { ($0.occurredAt, $0.id.uuidString) < ($1.occurredAt, $1.id.uuidString) }
        // Rafale : le contexte intègre le lot en une seule transaction (au lieu d'une par événement).
        // Les décisions restent séquentielles et chronologiques côté Brain ; seul le contexte est en avance.
        if ordered.count > 1 {
            let state = try await store.snapshot()
            let pending = ordered.filter { state.ledger[Self.ledgerKey($0)] == nil }
            if pending.count > 1 { do { try await context.ingest(pending) } catch { report(error) } }
        }
        for event in ordered {
            guard isActive else { break }
            do { if let record = try await processOne(event) { records.append(record) } }
            catch { report(error) }
        }
        // Le recalcul lié au temps (priorités, blocages) coûte O(missions) : une fois par quart d'heure,
        // et à la demande. Les missions touchées par un événement sont déjà recalculées par leur mise à jour.
        let now = clock()
        if lastReevaluation == nil || now.timeIntervalSince(lastReevaluation!) >= Self.reevaluationInterval {
            do { try await reevaluate() } catch { report(error) }
        }
        await publish()
        return records
    }

    private func processOne(_ event: GhostEvent) async throws -> DecisionRecord? {
        guard try await store.snapshot().ledger[Self.ledgerKey(event)] == nil else { return nil }
        try await context.ingest([event])                       // contexte enrichi avant toute décision
        let graph = try await context.snapshot()
        let grants = await GrantSnapshot.load(from: trust)
        let state = try await store.snapshot()
        let input = BrainInput(event: event, signals: BrainSignals.read(event), lens: ContextLens(graph: graph, event: event),
                               state: state, grants: grants, now: clock(), config: config)
        var outcome = DecisionEngine.decide(input)
        var engine = "rules", provider: String?, simulated = false
        if let consulted = await consultModel(input, outcome) {
            outcome = consulted.outcome; engine = "rules+model"; provider = consulted.provider; simulated = consulted.simulated
        }
        let record = DecisionRecord(date: input.now, kind: outcome.kind, missionID: outcome.missionID, eventIDs: [event.id],
                                    usedElements: outcome.used, reasons: outcome.reasons, confidence: outcome.confidence,
                                    alternatives: outcome.alternatives, uncertainties: outcome.uncertainties,
                                    engine: engine, modelProvider: provider, modelIsSimulated: simulated)
        let key = Self.ledgerKey(event)
        do {
            try await store.commit { try Self.apply(outcome, input: input, record: record, key: key, to: &$0) }
        } catch {
            guard case BrainError.invalid(let problems) = error else { throw error }
            // Invariant violé : on le journalise sans réessayer indéfiniment.
            var failed = record
            failed.kind = .ignore; failed.reasons = ["Décision abandonnée : \(problems)"]
            try await store.commit {
                $0.ledger[key] = LedgerEntry(eventID: event.id, decisionID: failed.id, kind: .ignore, processedAt: input.now)
                $0.decisions.append(failed)
            }
            throw error
        }
        return record
    }

    static func apply(_ outcome: DecisionOutcome, input: BrainInput, record: DecisionRecord, key: String, to state: inout BrainState) throws {
        var rec = record
        state.ledger[key] = LedgerEntry(eventID: input.event.id, decisionID: record.id, kind: record.kind, processedAt: input.now)
        switch outcome.kind {
        case .createMission, .clarify:
            guard let mission = MissionLifecycle.create(outcome, input: input, decisionID: record.id) else {
                throw BrainError.invalid("Objectif incomplet : mission non créée.")
            }
            if state.missions[mission.id] == nil {
                let problems = MissionLifecycle.validate(mission)
                guard problems.isEmpty else { throw BrainError.invalid(problems.joined(separator: " ")) }
                state.missions[mission.id] = mission
            } else {
                rec.reasons.append("Mission déjà enregistrée : aucun doublon créé.")
            }
            rec.missionID = mission.id
            if let w = outcome.removeWatchID { state.watches[w] = nil }
        case .updateMission, .completeMission:
            guard let id = outcome.missionID, let existing = state.missions[id] else { throw BrainError.unknownMission }
            let updated = MissionLifecycle.apply(outcome, to: existing, input: input, decisionID: record.id)
            let problems = MissionLifecycle.validate(updated)
            guard problems.isEmpty else { throw BrainError.invalid(problems.joined(separator: " ")) }
            state.missions[id] = updated
            rec.missionID = id
        case .monitor:
            if let w = outcome.watch { state.watches[w.id] = w }
        case .ignore, .remember:
            break
        }
        state.decisions.append(rec)
        if state.decisions.count > input.config.maxDecisionsKept { state.decisions.removeFirst(state.decisions.count - input.config.maxDecisionsKept) }
    }

    // MARK: Avis du modèle (cas ambigus seulement)

    private func consultModel(_ input: BrainInput, _ outcome: DecisionOutcome) async -> (outcome: DecisionOutcome, provider: String, simulated: Bool)? {
        guard let gateway, await gateway.isAvailable, ModelAdvisor.isAmbiguous(outcome, input: input) else { return nil }
        do {
            let response = try await gateway.complete(ModelAdvisor.request(input: input, outcome: outcome))
            guard let opinion = ModelAdvisor.parse(response.text) else {
                report(ModelError.providerFailed("avis du modèle ignoré : format invalide"))
                return nil
            }
            return (ModelAdvisor.reconcile(outcome, opinion: opinion, input: input, provider: response.provider, simulated: response.isSimulated),
                    response.provider, response.isSimulated)
        } catch {
            if let e = error as? ModelError, e == .disabled { return nil }
            report(error)   // le Brain continue avec les règles seules
            return nil
        }
    }

    // MARK: Réévaluation

    /// Recalcule priorités, plans et blocages (temps écoulé, nouvelles autorisations).
    public func reevaluate() async throws {
        let grants = await GrantSnapshot.load(from: trust)
        let now = clock()
        lastReevaluation = now
        let state = try await store.snapshot()
        var changed: [String: Mission] = [:]
        for (id, original) in state.missions where original.isOpen {
            var m = original
            let before = Self.signature(m)
            MissionLifecycle.refresh(&m, grants: grants, now: now, calendar: config.calendar, reason: "Réévaluation du contexte", decisionID: nil)
            if Self.signature(m) != before { changed[id] = m }
        }
        guard !changed.isEmpty else { return }
        try await store.commit { for (id, m) in changed { $0.missions[id] = m } }
    }

    static func signature(_ m: Mission) -> String {
        "\(m.state.rawValue)|\(m.priority.level.rawValue)|\(Int(m.priority.score * 20))|" + m.plan.steps.map { $0.state.rawValue }.joined(separator: ",")
            + "|" + m.permissions.map { $0.status.rawValue }.joined(separator: ",")
    }

    // MARK: Actions de l'utilisateur (corrections = données d'apprentissage contrôlées)

    private func edit(_ id: String, feedback: FeedbackKind, before: String?, after: String?,
                      _ body: @escaping (inout Mission, inout BrainState, GrantSnapshot, Date) throws -> Void) async throws {
        let grants = await GrantSnapshot.load(from: trust)
        let now = clock()
        try await store.commit { state in
            guard var m = state.missions[id] else { throw BrainError.unknownMission }
            try body(&m, &state, grants, now)
            let problems = MissionLifecycle.validate(m)
            guard problems.isEmpty else { throw BrainError.invalid(problems.joined(separator: " ")) }
            m.updatedAt = now
            state.missions[id] = m
            state.feedback.append(BrainFeedback(id: UUID(), date: now, missionID: id, kind: feedback, before: before, after: after))
        }
        await publish()
    }

    public func confirm(_ id: String) async throws {
        try await edit(id, feedback: .confirm, before: nil, after: nil) { m, _, grants, now in
            guard m.isOpen else { throw BrainError.invalid("Mission terminée.") }
            m.verdict = .confirmed
            m.history.append(HistoryEntry(date: now, kind: "confirmed", summary: "L'utilisateur confirme que la mission est pertinente.", byUser: true))
            MissionLifecycle.refresh(&m, grants: grants, now: now, calendar: self.config.calendar, reason: "Confirmée par l'utilisateur", decisionID: nil)
        }
    }

    public func reject(_ id: String, reason: String = "") async throws {
        try await edit(id, feedback: .reject, before: nil, after: reason.isEmpty ? nil : reason) { m, state, _, now in
            m.verdict = .rejected
            MissionLifecycle.transition(&m, to: .cancelled, now: now, reason: "signalée comme incorrecte par l'utilisateur", decisionID: nil, byUser: true)
            for i in m.plan.steps.indices where [.pending, .ready, .blocked].contains(m.plan.steps[i].state) { m.plan.steps[i].state = .cancelled }
            m.history.append(HistoryEntry(date: now, kind: "rejected", summary: "Mission signalée comme incorrecte" + (reason.isEmpty ? "." : " : \(reason)"), byUser: true))
            state.suppressedKeys.insert(m.dedupeKey)   // règle visible : cette demande n'est pas recréée
        }
    }

    public func cancel(_ id: String) async throws {
        try await edit(id, feedback: .cancel, before: nil, after: nil) { m, _, _, now in
            guard m.isOpen else { return }
            MissionLifecycle.transition(&m, to: .cancelled, now: now, reason: "annulée par l'utilisateur", decisionID: nil, byUser: true)
            for i in m.plan.steps.indices where [.pending, .ready, .blocked].contains(m.plan.steps[i].state) { m.plan.steps[i].state = .cancelled }
        }
    }

    public func correctGoal(_ id: String, to text: String) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 500 else { throw BrainError.invalid("L'objectif doit contenir entre 1 et 500 caractères.") }
        let previous = try await store.snapshot().missions[id]?.goal.expectedResult
        try await edit(id, feedback: .correctGoal, before: previous, after: clean) { m, _, grants, now in
            guard m.isOpen else { throw BrainError.invalid("Mission terminée.") }
            let before = m.goal.expectedResult
            m.goal.expectedResult = clean
            m.title = String(clean.prefix(140))
            m.missingInfo.removeAll { $0.text.hasPrefix("Livrable attendu non précisé") }
            m.history.append(HistoryEntry(date: now, kind: "goal", summary: "Objectif corrigé par l'utilisateur.", before: before, after: clean, byUser: true))
            MissionLifecycle.refresh(&m, grants: grants, now: now, calendar: self.config.calendar, reason: "Objectif corrigé", decisionID: nil)
        }
    }

    public func setPriority(_ id: String, to level: MissionPriority?) async throws {
        try await edit(id, feedback: .changePriority, before: nil, after: level?.rawValue) { m, _, grants, now in
            guard m.isOpen else { throw BrainError.invalid("Mission terminée.") }
            let before = m.effectivePriority.label
            m.userPriority = level
            m.history.append(HistoryEntry(date: now, kind: "priority", summary: level.map { "Priorité fixée par l'utilisateur : \($0.label)." } ?? "Priorité automatique rétablie.",
                                          before: before, after: m.effectivePriority.label, byUser: true))
            MissionLifecycle.refresh(&m, grants: grants, now: now, calendar: self.config.calendar, reason: "Priorité modifiée", decisionID: nil)
        }
    }

    /// Ajoute une précision ; si la mission attendait une clarification d'objectif, elle est levée.
    public func addNote(_ id: String, text: String) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 2_000 else { throw BrainError.invalid("La précision doit contenir entre 1 et 2 000 caractères.") }
        try await edit(id, feedback: .addNote, before: nil, after: clean) { m, _, grants, now in
            guard m.isOpen else { throw BrainError.invalid("Mission terminée.") }
            m.notes.append(clean)
            m.history.append(HistoryEntry(date: now, kind: "note", summary: "Précision de l'utilisateur : \(clean)", byUser: true))
            if m.missingInfo.contains(where: { $0.severity == .clarify && !$0.text.hasPrefix("Échéances contradictoires") }) {
                m.missingInfo.removeAll { $0.severity == .clarify && !$0.text.hasPrefix("Échéances contradictoires") }
                if m.goal.deliverable == nil { m.goal.expectedResult = clean; m.title = String(clean.prefix(140)) }
                m.clarificationQuestion = nil
            }
            MissionLifecycle.refresh(&m, grants: grants, now: now, calendar: self.config.calendar, reason: "Précision apportée", decisionID: nil)
        }
    }

    /// L'utilisateur tranche une contradiction d'échéance : les autres assertions sont conservées, marquées remplacées.
    public func resolveDeadline(_ id: String, to date: Date) async throws {
        try await edit(id, feedback: .addNote, before: nil, after: "échéance tranchée") { m, _, grants, now in
            guard m.isOpen else { throw BrainError.invalid("Mission terminée.") }
            for i in m.deadlineClaims.indices { m.deadlineClaims[i].superseded = true }
            m.deadlineClaims.append(DeadlineClaim(date: date, text: "choisie par l'utilisateur", sourceID: "user", sourceName: "Utilisateur",
                                                   eventID: m.triggers[0].eventID, senderEmail: nil, assertedAt: now))
            m.deadline = date; m.deadlineConflict = false
            m.missingInfo.removeAll { $0.text.hasPrefix("Échéances contradictoires") }
            m.clarificationQuestion = nil
            m.history.append(HistoryEntry(date: now, kind: "deadline", summary: "Échéance tranchée par l'utilisateur : \(BrainFormat.date(date, calendar: self.config.calendar)).", byUser: true))
            MissionLifecycle.refresh(&m, grants: grants, now: now, calendar: self.config.calendar, reason: "Échéance tranchée", decisionID: nil)
        }
    }

    // MARK: Données, révocation, reprise

    public func deleteMemory() async throws {
        try await store.reset()
        deferredCount = 0; lastError = nil
        await publish()
    }

    public func sourceWasRevoked(_ source: SourceID, retainHistory: Bool) async throws {
        try await store.commit { state in
            if retainHistory { state.retainedSources.insert(source.rawValue); return }
            state.retainedSources.remove(source.rawValue)
            Self.purge(source: source.rawValue, from: &state)
        }
        await publish()
    }

    /// Après une panne : plus de mission issue d'une source sans autorisation (sauf conservation choisie).
    public func reconcilePermissions() async throws {
        let grants = await GrantSnapshot.load(from: trust)
        let state = try await store.snapshot()
        let sources = Set(state.missions.values.flatMap { $0.triggers.map(\.sourceID) })
            .union(state.watches.values.map(\.sourceID))
        let revoked = sources.filter { grants.grants[$0] == nil && !state.retainedSources.contains($0) }
        guard !revoked.isEmpty else { return }
        try await store.commit { state in for s in revoked { Self.purge(source: s, from: &state) } }
        await publish()
    }

    static func purge(source: String, from state: inout BrainState) {
        for (id, var m) in state.missions {
            guard m.triggers.contains(where: { $0.sourceID == source }) else { continue }
            m.triggers.removeAll { $0.sourceID == source }
            m.deadlineClaims.removeAll { $0.sourceID == source }
            if m.triggers.isEmpty { state.missions[id] = nil } else { state.missions[id] = m }
        }
        state.watches = state.watches.filter { $0.value.sourceID != source }
        state.ledger = state.ledger.filter { !$0.key.hasPrefix(source + "|") }
    }

    public func report(_ error: any Error) {
        lastError = error.localizedDescription
        continuation.yield(.issue(error.localizedDescription))
    }

    private func publish() async {
        if let state = try? await store.snapshot() { continuation.yield(.snapshot(state)) }
    }
}
