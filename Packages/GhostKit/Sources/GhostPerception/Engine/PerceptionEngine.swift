import Foundation

/// Moteur de perception : orchestre la collecte des sources autorisées.
///
/// Pipeline d'un cycle, pour chaque source active et due :
/// `TrustEngine` (autorisation) → `PerceptionSource.poll()` → `EventNormalizer`
/// → `UnderstandingEngine` → `EventStore` (dédoublonnage) → diffusion.
///
/// **Pause réelle** : en état `paused` ou `stopped`, la boucle de collecte est
/// annulée et ``runCycle(force:)`` n'interroge aucune source. ``pause()`` et
/// ``stop()`` attendent la fin d'un éventuel cycle en cours : à leur retour,
/// plus aucune collecte n'est active.
public actor PerceptionEngine {
    private struct Registration {
        var source: PerceptionSource
        var isEnabled: Bool
        var lastPoll: Date?
        var lastSuccess: Date?
        var lastError: String?
        var failures: Int = 0
        var detected: Int = 0
    }

    public private(set) var state: EngineState = .stopped
    public nonisolated let updates: AsyncStream<PerceptionUpdate>
    private let continuation: AsyncStream<PerceptionUpdate>.Continuation

    private let trust: TrustEngine
    private let store: EventStore
    private let normalizer: EventNormalizer
    private let understanding: UnderstandingEngine
    private let clock: @Sendable () -> Date
    private let tickNanoseconds: UInt64?
    private var registrations: [SourceID: Registration] = [:]
    private var order: [SourceID] = []
    private var consumers: [PerceptionEventConsumer] = []
    private var loopTask: Task<Void, Never>?
    private var isCycling = false
    private var cycleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter tick: période de la boucle de collecte automatique ;
    ///   `nil` pour un mode manuel (cycles déclenchés par ``runCycle(force:)``).
    public init(trust: TrustEngine, store: EventStore,
                normalizer: EventNormalizer = EventNormalizer(),
                understanding: UnderstandingEngine = UnderstandingEngine(),
                tick: TimeInterval? = 1,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.trust = trust
        self.store = store
        self.normalizer = normalizer
        self.understanding = understanding
        self.tickNanoseconds = tick.map { UInt64(max(0.01, $0) * 1_000_000_000) }
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: PerceptionUpdate.self, bufferingPolicy: .bufferingNewest(500))
    }

    deinit {
        loopTask?.cancel()
        continuation.finish()
    }

    // MARK: - Sources

    public func register(_ source: PerceptionSource, enabled: Bool = true) async {
        let id = source.descriptor.id
        if registrations[id] == nil { order.append(id) }
        registrations[id] = Registration(source: source, isEnabled: enabled)
        await publishStatuses()
    }

    public func unregister(_ id: SourceID) async {
        registrations[id] = nil
        order.removeAll { $0 == id }
        await publishStatuses()
    }

    /// Active ou désactive une source. Une source désactivée n'est plus interrogée.
    public func setEnabled(_ id: SourceID, _ enabled: Bool) async {
        registrations[id]?.isEnabled = enabled
        if enabled { registrations[id]?.lastPoll = nil }
        await publishStatuses()
    }

    /// Révoque une source : jeton externe révoqué (si applicable),
    /// autorisation retirée, source retirée du moteur.
    public func revoke(_ id: SourceID) async {
        if let source = registrations[id]?.source {
            do { try await source.revokeAccess() } catch {
                emit(PerceptionIssue(date: clock(), sourceID: id, kind: .connection,
                                       message: "Révocation distante incomplète : \(error.localizedDescription). L'accès local a été retiré."))
            }
        }
        await trust.revoke(id)
        await unregister(id)
    }

    public func addConsumer(_ consumer: PerceptionEventConsumer) {
        consumers.append(consumer)
    }

    public func statuses() async -> [SourceStatus] {
        var result: [SourceStatus] = []
        for id in order {
            guard let registration = registrations[id] else { continue }
            let descriptor = registration.source.descriptor
            let permission: Permission = descriptor.kind == .email ? .readMail : .watchFolder
            result.append(SourceStatus(descriptor: descriptor, isEnabled: registration.isEnabled,
                                       isAuthorized: await trust.isAuthorized(id, permission),
                                       lastPoll: registration.lastPoll, lastSuccess: registration.lastSuccess,
                                       lastError: registration.lastError,
                                       consecutiveFailures: registration.failures,
                                       detectedCount: registration.detected))
        }
        return result
    }

    // MARK: - Cycle de vie

    public func start() async { await transition(to: .running) }
    public func resume() async { await transition(to: .running) }
    public func pause() async { await transition(to: .paused) }
    public func stop() async { await transition(to: .stopped) }

    private func transition(to newState: EngineState) async {
        guard state != newState else {
            if newState != .running { await waitForCurrentCycle() }
            return
        }
        state = newState
        loopTask?.cancel()
        loopTask = nil
        if newState != .running {
            // Attendre la fin du cycle en cours : il s'interrompt avant la
            // source suivante puisque l'état n'est plus `running`.
            await waitForCurrentCycle()
        } else if let tick = tickNanoseconds {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    _ = await self?.runCycle()
                    try? await Task.sleep(nanoseconds: tick)
                }
            }
        }
        continuation.yield(.state(newState))
    }

    // MARK: - Collecte

    /// Exécute un cycle de collecte.
    ///
    /// - Parameter force: interroge toutes les sources actives sans attendre
    ///   leur intervalle (bouton « Actualiser »). N'a **aucun effet** si le
    ///   moteur est en pause ou arrêté.
    @discardableResult
    public func runCycle(force: Bool = false) async -> CycleReport {
        var report = CycleReport()
        // Un seul cycle à la fois : une demande manuelle attend le cycle en cours.
        await waitForCurrentCycle()
        guard state == .running else {
            report.skipped = true
            return report
        }
        isCycling = true
        defer {
            isCycling = false
            let waiters = cycleWaiters
            cycleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        for id in order {
            // La pause peut survenir pendant un cycle : on vérifie avant chaque source.
            guard state == .running, !Task.isCancelled else { break }
            guard var registration = registrations[id], registration.isEnabled else { continue }
            let now = clock()
            if !force, let last = registration.lastPoll {
                let backoff = pow(2.0, Double(min(registration.failures, 5)))
                if now.timeIntervalSince(last) < registration.source.pollInterval * backoff { continue }
            }
            registration.lastPoll = now
            registrations[id] = registration
            report.polled.append(id)

            do {
                let raw = try await registration.source.poll()
                let fresh = try await process(raw, from: registration.source.descriptor)
                report.newEvents += fresh
                registrations[id]?.lastSuccess = clock()
                registrations[id]?.lastError = nil
                registrations[id]?.failures = 0
                registrations[id]?.detected += fresh.count
            } catch {
                let issue = Self.issue(for: error, source: id, date: clock())
                registrations[id]?.lastError = issue.message
                registrations[id]?.failures += 1
                report.issues.append(issue)
                emit(issue)
            }
        }

        if !report.newEvents.isEmpty {
            continuation.yield(.newEvents(report.newEvents))
            for consumer in consumers { await consumer.consume(report.newEvents) }
        }
        if !report.polled.isEmpty { await publishStatuses() }
        return report
    }

    private func process(_ raw: [RawObservation], from source: EventSource) async throws -> [GhostEvent] {
        var events: [GhostEvent] = []
        for observation in raw {
            let normalized = normalizer.normalize(observation, from: source)
            guard !(await store.contains(fingerprint: normalized.fingerprint)) else { continue }
            events.append(understanding.interpret(normalized, detectedAt: clock()))
        }
        return try await store.insert(events)
    }

    // MARK: - Données

    /// Supprime toutes les données collectées (événements et états des sources).
    public func deleteCollectedData() async throws {
        try await store.deleteAll()
        for registration in registrations.values { await registration.source.resetState() }
        for id in order { registrations[id]?.detected = 0 }
        continuation.yield(.dataCleared)
        await publishStatuses()
    }

    // MARK: - Utilitaires

    private func waitForCurrentCycle() async {
        while isCycling {
            await withCheckedContinuation { cycleWaiters.append($0) }
        }
    }

    private func emit(_ issue: PerceptionIssue) {
        continuation.yield(.issue(issue))
    }

    private func publishStatuses() async {
        continuation.yield(.sources(await statuses()))
    }

    static func issue(for error: Error, source: SourceID, date: Date) -> PerceptionIssue {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let kind: PerceptionIssue.Kind
        switch error as? PerceptionError {
        case .notAuthorized?, .egressDenied?: kind = .access
        case .authorizationRequired?, .authenticationFailed?: kind = .authorization
        case .connectionFailed?, .rateLimited?, .invalidResponse?: kind = .connection
        case .misconfigured?, nil: kind = .other
        }
        return PerceptionIssue(date: date, sourceID: source, kind: kind, message: message)
    }
}
