import Foundation
import Observation
import GhostPerception

/// Pont observable vers SwiftUI. Les erreurs restent visibles ; aucune action
/// n'est exécutée : seules les décisions et les corrections de l'utilisateur transitent ici.
@MainActor @Observable
public final class BrainCenter {
    public private(set) var state = BrainState()
    public private(set) var error: String?
    public let engine: BrainEngine
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(engine: BrainEngine) {
        self.engine = engine
        listener = Task { [weak self] in
            for await update in engine.updates {
                guard let self else { return }
                switch update {
                case .snapshot(let s): self.state = s; self.error = nil
                case .issue(let message): self.error = message
                }
            }
        }
    }
    deinit { listener?.cancel() }

    /// Missions triées : ouvertes d'abord, par priorité décroissante puis échéance.
    public var missions: [Mission] {
        state.missions.values.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            if a.effectivePriority != b.effectivePriority { return a.effectivePriority > b.effectivePriority }
            switch (a.deadline, b.deadline) {
            case let (x?, y?): if x != y { return x < y }
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return a.createdAt > b.createdAt
        }
    }
    public var watches: [Watch] { state.watches.values.sorted { $0.createdAt > $1.createdAt } }
    public func decisions(for missionID: String) -> [DecisionRecord] { state.decisions.filter { $0.missionID == missionID }.reversed() }

    public func reload() async {
        do { state = try await engine.snapshot(); error = await engine.lastError }
        catch { self.error = error.localizedDescription }
    }

    public func perform(_ action: @escaping @Sendable (BrainEngine) async throws -> Void) async {
        do { try await action(engine); state = try await engine.snapshot(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
