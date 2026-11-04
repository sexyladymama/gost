import Foundation
import Observation
import GhostKit

/// Pont entre le moteur de perception et GHOST SHELL.
///
/// - Implémente ``GhostCoreInterface`` : ACTIVE/PAUSED/STOPPED de
///   ``GhostStateManager`` pilotent réellement la collecte.
/// - Expose à SwiftUI (`@Observable`) les événements détectés, les anomalies,
///   l'état des sources et le journal d'accès.
///
/// Les commandes sont exécutées **dans l'ordre** via une file unique, afin
/// qu'une séquence pause → reprise rapide ne soit jamais inversée.
@MainActor
@Observable
public final class PerceptionCenter: GhostCoreInterface {
    public nonisolated let name = "Perception (règles explicites)"

    public private(set) var engineState: EngineState = .stopped
    /// Événements, du plus récent au plus ancien.
    public private(set) var events: [GhostEvent] = []
    /// Anomalies récentes, de la plus récente à la plus ancienne.
    public private(set) var issues: [PerceptionIssue] = []
    public private(set) var sources: [SourceStatus] = []
    public private(set) var accessRecords: [AccessRecord] = []
    /// Identifiants des événements importants non encore consultés.
    public private(set) var unseenImportant: Set<UUID> = []

    @ObservationIgnored public let engine: PerceptionEngine
    @ObservationIgnored private let store: EventStore
    @ObservationIgnored private let accessLog: AccessLog
    @ObservationIgnored private let commands: AsyncStream<@Sendable () async -> Void>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let displayLimit = 500

    public init(engine: PerceptionEngine, store: EventStore, accessLog: AccessLog) {
        self.engine = engine
        self.store = store
        self.accessLog = accessLog
        let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
        self.commands = continuation
        tasks.append(Task {
            for await command in stream { await command() }
        })
        tasks.append(Task { [weak self] in
            for await update in engine.updates {
                self?.apply(update)
            }
        })
        enqueue { [weak self] in
            do {
                let saved = try await store.all()
                await self?.setInitialEvents(saved)
            } catch {
                await self?.reportStorageError(error)
            }
        }
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    // MARK: - GhostCoreInterface

    public func start() { enqueue { await self.engine.start() } }
    public func pause() { enqueue { await self.engine.pause() } }
    public func resume() { enqueue { await self.engine.resume() } }
    public func stop() { enqueue { await self.engine.stop() } }

    // MARK: - Actions utilisateur

    /// Collecte immédiate (sans effet si GHOST est en pause ou arrêté).
    public func refreshNow() { enqueue { await self.engine.runCycle(force: true) } }

    public func setSourceEnabled(_ id: SourceID, _ enabled: Bool) {
        enqueue { await self.engine.setEnabled(id, enabled) }
    }

    /// Révoque l'autorisation d'une source. Les événements déjà détectés sont conservés
    /// sauf si `deleteData` est vrai.
    public func revoke(_ id: SourceID, deleteData: Bool, retainContext: Bool = false) async {
        let failure: (any Error)? = await runInQueue {
            if let issue = await self.engine.revoke(id, retainHistory: retainContext && !deleteData) {
                return PerceptionError.storageFailed(issue.message)
            }
            if deleteData {
                do { try await self.store.delete(source: id) }
                catch { return error }
            }
            return nil
        }
        if let failure { reportStorageError(failure) }
        else if deleteData { events.removeAll { $0.source.id == id } }
        await reloadAccessLog()
    }

    public func register(_ source: PerceptionSource, enabled: Bool = true) async {
        await runInQueue { await self.engine.register(source, enabled: enabled) }
    }

    /// Branchement et relecture sérialisés avec collecte, révocation et effacement.
    public func attachConsumer(_ consumer: PerceptionEventConsumer) async throws {
        await runInQueue { await self.engine.addConsumer(consumer) }
        try await replayEvents(to: consumer)
    }

    public func replayEvents(to consumer: PerceptionEventConsumer) async throws {
        let failure: (any Error)? = await runInQueue {
            do {
                let saved = try await self.store.all()
                // Les événements révoqués ne sont pas réinjectés par la relecture.
                let statuses = await self.engine.statuses()
                let authorized = Set(statuses.filter(\.isAuthorized).map(\.id))
                await consumer.consume(saved.filter { authorized.contains($0.source.id) })
            } catch { return error }
            return nil
        }
        if let failure { throw failure }
    }

    /// Supprime tous les événements et états de sources ; optionnellement le journal d'accès.
    public func deleteCollectedData(includingAccessLog: Bool) async throws {
        let failure: (any Error)? = await runInQueue {
            if includingAccessLog { await self.accessLog.clear() }
            do { try await self.engine.deleteCollectedData() } catch { return error }
            return nil
        }
        if let failure { throw failure }
        events.removeAll()
        unseenImportant.removeAll()
        issues.removeAll()
        await reloadAccessLog()
    }

    public func reloadAccessLog() async {
        accessRecords = await accessLog.all().reversed()
    }

    public func markSeen(_ id: UUID) { unseenImportant.remove(id) }
    public func markAllSeen() { unseenImportant.removeAll() }
    public func dismissIssues() { issues.removeAll() }

    public var importantEvents: [GhostEvent] { events.filter(\.isImportant) }

    // MARK: - Interne

    private func enqueue(_ command: @escaping @Sendable () async -> Void) {
        commands.yield(command)
    }

    /// Exécute une commande dans la file et attend sa fin.
    private func runInQueue<T: Sendable>(_ command: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            enqueue {
                done.resume(returning: await command())
            }
        }
    }

    private func reportStorageError(_ error: any Error) {
        issues.insert(PerceptionIssue(date: Date(), sourceID: SourceID("storage"), kind: .other,
                                     message: error.localizedDescription), at: 0)
    }

    private func setInitialEvents(_ saved: [GhostEvent]) {
        let known = Set(events.map(\.id))
        events = (events + saved.filter { !known.contains($0.id) })
            .sorted { $0.detectedAt > $1.detectedAt }
        events = Array(events.prefix(displayLimit))
    }

    private func apply(_ update: PerceptionUpdate) {
        switch update {
        case .state(let state):
            engineState = state
        case .newEvents(let fresh):
            events = Array((fresh.sorted { $0.detectedAt > $1.detectedAt } + events).prefix(displayLimit))
            unseenImportant.formUnion(fresh.filter(\.isImportant).map(\.id))
        case .issue(let issue):
            issues = Array(([issue] + issues).prefix(50))
        case .sources(let statuses):
            sources = statuses
        case .dataCleared:
            events.removeAll()
            unseenImportant.removeAll()
        }
    }
}
