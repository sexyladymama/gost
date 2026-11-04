import Foundation

/// Source e-mail : détecte les nouveaux messages d'un ``MailProvider``.
///
/// - Vérifie l'autorisation `readMail` auprès du ``TrustEngine`` avant chaque collecte.
/// - Ne relève que les messages arrivés après le dernier curseur ; à la
///   première connexion, le curseur est la date d'autorisation (les messages
///   antérieurs ne sont pas parcourus).
/// - Ne répond jamais, n'envoie rien, ne modifie aucun message.
public actor EmailSource: PerceptionSource {
    struct State: Codable {
        var cursor: Date
        var seenIDs: [String]
    }

    public nonisolated let descriptor: EventSource
    public nonisolated let pollInterval: TimeInterval
    private let provider: MailProvider
    private let trust: TrustEngine
    private let stateStore: SourceStateStore
    private let startDate: Date
    private var state: State?
    private var account: String?
    private let maxSeen = 500

    public init(id: SourceID = SourceID("gmail"), provider: MailProvider, trust: TrustEngine,
                stateStore: SourceStateStore, startDate: Date, pollInterval: TimeInterval = 60) {
        self.descriptor = EventSource(id: id, kind: .email,
                                      displayName: provider.isSimulated ? "\(provider.displayName) (simulation)" : provider.displayName,
                                      isSimulated: provider.isSimulated)
        self.pollInterval = pollInterval
        self.provider = provider
        self.trust = trust
        self.stateStore = stateStore
        self.startDate = startDate
    }

    /// Curseur distinct pour la simulation et pour un compte réel.
    private var stateKey: String { "email.\(descriptor.id.rawValue).\(descriptor.isSimulated ? "simulation" : "live")" }

    public func poll() async throws -> [RawObservation] {
        try await trust.require(descriptor.id, .readMail, operation: "mail.fetch", target: provider.displayName)
        var current = loadState()
        if account == nil { account = try await provider.accountAddress() }
        let messages = try await provider.fetchMessages(after: current.cursor)
        let seen = Set(current.seenIDs)
        let fresh = messages.filter { !seen.contains($0.id) }
        current.seenIDs.append(contentsOf: fresh.map(\.id))
        current.seenIDs = Array(current.seenIDs.suffix(maxSeen))
        if let latest = messages.map(\.date).max(), latest > current.cursor { current.cursor = latest }
        state = current
        if let data = try? JSONEncoder().encode(current) { stateStore.save(data, for: stateKey) }
        return fresh.map { RawObservation.email($0, account: account) }
    }

    public func revokeAccess() async throws {
        try await provider.revokeAccess()
    }

    public func resetState() async {
        // Après suppression des données, on repart de maintenant : les
        // anciens messages ne sont pas re-collectés.
        let now = max(Date(), loadState().cursor)
        state = State(cursor: now, seenIDs: [])
        if let data = try? JSONEncoder().encode(state) { stateStore.save(data, for: stateKey) }
    }

    private func loadState() -> State {
        if let state { return state }
        if let data = stateStore.load(stateKey), let saved = try? JSONDecoder().decode(State.self, from: data) {
            return saved
        }
        return State(cursor: startDate, seenIDs: [])
    }
}
