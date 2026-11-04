import Foundation
import Observation
import GhostPerception

/// Pont observable vers SwiftUI ; les erreurs restent visibles et peuvent être réessayées.
@MainActor @Observable
public final class ContextCenter {
    public private(set) var graph = ContextSnapshot()
    public private(set) var error: String?
    public private(set) var isBusy = false
    public let engine: ContextEngine
    @ObservationIgnored private var listener: Task<Void, Never>?
    public init(engine: ContextEngine) {
        self.engine = engine
        listener = Task { [weak self] in
            for await update in engine.updates {
                guard let self else { return }
                switch update {
                case .snapshot(let snapshot): self.graph = snapshot; self.error = nil
                case .issue(let error): self.error = error
                }
            }
        }
    }
    deinit { listener?.cancel() }
    public func reload() async {
        do { graph = try await engine.snapshot(); error = await engine.lastError }
        catch { self.error = error.localizedDescription }
    }
    public func perform(_ action: @escaping @Sendable (ContextEngine) async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await action(engine); graph = try await engine.snapshot(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    public func search(_ query: String, domain: MemoryDomain?, scope: ContextScope?) async -> [ContextNode] {
        do { return try await engine.search(query, domain: domain, scope: scope) }
        catch { self.error = error.localizedDescription; return [] }
    }
}
