import Foundation
import Observation

/// Pont observable vers SwiftUI pour les objectifs confiés à GHOST CORE.
@MainActor @Observable
public final class CoreCenter {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var error: String?
    public let engine: CoreCoordinator
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(engine: CoreCoordinator) {
        self.engine = engine
        listener = Task { [weak self] in
            for await update in engine.updates {
                guard let self else { return }
                switch update {
                case .sessions(let all): self.sessions = all; self.error = nil
                case .issue(let message): self.error = message
                }
            }
        }
    }
    deinit { listener?.cancel() }

    /// Sessions qui attendent l'utilisateur : une question, un accord ou un résultat à relire.
    public var needsAttention: Int { sessions.filter { [.clarification, .approval, .review].contains($0.phase) }.count }

    public func reload() async {
        do { sessions = try await engine.sessions() } catch { self.error = error.localizedDescription }
    }
    public func perform(_ action: @escaping @Sendable (CoreCoordinator) async throws -> Void) async {
        do { try await action(engine); await reload(); error = nil } catch { self.error = error.localizedDescription }
    }
}
