import Foundation
import Observation

@MainActor @Observable
public final class ExecutionCenter {
    public private(set) var archive: ExecutionArchive
    public private(set) var error: String?
    public let engine: ExecutionEngine
    @ObservationIgnored private var listener: Task<Void, Never>?
    public init(engine: ExecutionEngine, profileID: String) {
        self.engine = engine; archive = ExecutionArchive(profileID: profileID)
        listener = Task { [weak self] in
            for await update in engine.updates {
                guard let self else { return }
                switch update {
                case .archive(let archive): self.archive = archive; self.error = nil
                case .issue(let message): self.error = message
                }
            }
        }
    }
    deinit { listener?.cancel() }
    public var executions: [ExecutionContext] { archive.executions.values.sorted { $0.updatedAt > $1.updatedAt } }
    public func reload() async {
        do { archive = try await engine.snapshot(); error = nil } catch { self.error = error.localizedDescription }
    }
    public func perform(_ action: @escaping @Sendable (ExecutionEngine) async throws -> Void) async {
        do { try await action(engine); archive = try await engine.snapshot(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
