import Foundation
import Observation

/// Pont observable vers SwiftUI pour la vue Agenda.
@MainActor @Observable
public final class CalendarCenter {
    public private(set) var entries: [CalendarEntry] = []
    public private(set) var error: String?
    public private(set) var authorization: CalendarAuthorization = .notDetermined
    public let agent: CalendarAgent
    private let writer: CalendarWriter
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(agent: CalendarAgent, writer: CalendarWriter) {
        self.agent = agent; self.writer = writer
        listener = Task { [weak self] in
            for await update in agent.updates {
                guard let self else { return }
                switch update {
                case .entries(let all): self.entries = all; self.error = nil
                case .issue(let message): self.error = message
                }
            }
        }
    }
    deinit { listener?.cancel() }

    public func reload() async {
        authorization = await writer.authorization()
        do { entries = try await agent.entries() } catch { self.error = error.localizedDescription }
    }
    public func requestAccess() async {
        _ = await writer.requestAccess()
        await reload()
    }
    public func perform(_ action: @escaping @Sendable (CalendarAgent) async throws -> Void) async {
        do { try await action(agent); entries = try await agent.entries(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
