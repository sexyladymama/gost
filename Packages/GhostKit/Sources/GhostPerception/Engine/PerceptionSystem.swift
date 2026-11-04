import Foundation

/// Assemblage complet du système de perception pour un profil utilisateur.
///
/// Toutes les données (événements, autorisations, états, journal) sont
/// rangées dans le répertoire du profil. Le seul accès réseau possible passe
/// par ``http``, un ``GuardedHTTPClient`` limité aux hôtes Google nécessaires
/// à la source Gmail.
public struct PerceptionSystem: Sendable {
    public static let gmailSourceID = SourceID("gmail")
    public static let folderSourceID = SourceID("folder")
    public static let brainSourceID = SourceID("brain")

    public let profile: GhostProfile
    public let accessLog: AccessLog
    public let trust: TrustEngine
    public let store: EventStore
    public let sourceState: SourceStateStore
    public let engine: PerceptionEngine
    /// Client réseau filtré : seul chemin vers l'extérieur.
    public let http: HTTPClient

    /// Destinations réseau autorisées. Aucune autre n'est joignable.
    public static let egressRules: [EgressRule] = [
        EgressRule(host: GmailMailProvider.apiHost, allowedPurposes: [gmailSourceID], requiredPermission: .readMail),
        // Échange/renouvellement/révocation de jeton : nécessaire pendant la
        // connexion, avant que l'autorisation ne soit enregistrée.
        EgressRule(host: GoogleOAuthClient.tokenHost, allowedPurposes: [gmailSourceID], requiredPermission: nil),
        // Modèle externe du Brain : uniquement si l'utilisateur a accordé `callExternalModel`.
        EgressRule(host: "api.anthropic.com", allowedPurposes: [brainSourceID], requiredPermission: .callExternalModel)
    ]

    public init(profile: GhostProfile, persistent: Bool = true, baseHTTP: HTTPClient = URLSessionHTTPClient(),
                tick: TimeInterval? = 1, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = profile
        accessLog = AccessLog(fileURL: persistent ? profile.accessLogURL : nil, clock: clock)
        trust = TrustEngine(accessLog: accessLog, storeURL: persistent ? profile.grantsURL : nil, clock: clock)
        store = FileEventStore(fileURL: persistent ? profile.eventsURL : nil)
        sourceState = persistent ? FileSourceStateStore(directory: profile.sourceStateDirectory) : InMemorySourceStateStore()
        engine = PerceptionEngine(trust: trust, store: store, sourceState: sourceState, tick: tick, clock: clock)
        http = GuardedHTTPClient(base: baseHTTP, rules: Self.egressRules, trust: trust)
    }

    @MainActor
    public func makeCenter() -> PerceptionCenter {
        PerceptionCenter(engine: engine, store: store, accessLog: accessLog)
    }
}
