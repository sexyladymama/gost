import Foundation
import Observation

/// Pont observable vers SwiftUI pour la vue « Brouillons ».
@MainActor @Observable
public final class MindCenter {
    public private(set) var state = MindState()
    public private(set) var error: String?
    public private(set) var modelName: String?
    public private(set) var modelAvailability: LanguageModelAvailability = .unavailable("Vérification en cours…")
    public let engine: MindEngine
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(engine: MindEngine) {
        self.engine = engine
        listener = Task { [weak self] in
            for await update in engine.updates {
                guard let self else { return }
                switch update {
                case .state(let s): self.state = s; self.error = nil
                case .issue(let message): self.error = message
                }
            }
        }
    }
    deinit { listener?.cancel() }

    public var drafts: [MailDraft] { state.drafts.values.sorted { $0.createdAt > $1.createdAt } }
    public var searches: [PlaceSearch] { state.searches.values.filter { !$0.hidden }.sorted { $0.searchedAt > $1.searchedAt } }
    public var pending: [MailDraft] { drafts.filter { [.ready, .needsModel, .failed].contains($0.status) } }

    public func reload() async {
        do { state = try await engine.snapshot() } catch { self.error = error.localizedDescription }
        let status = await engine.modelStatus()
        modelName = status.name; modelAvailability = status.availability
    }
    public func perform(_ action: @escaping @Sendable (MindEngine) async throws -> Void) async {
        do { try await action(engine); await reload(); error = nil } catch { self.error = error.localizedDescription }
    }
}
