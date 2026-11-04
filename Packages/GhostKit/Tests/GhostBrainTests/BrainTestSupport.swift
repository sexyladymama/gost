import Foundation
import XCTest
@testable import GhostBrain
@testable import GhostContext
@testable import GhostPerception

let brainCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Paris")!
    c.locale = Locale(identifier: "fr_FR")
    return c
}()

func parisDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    brainCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Mercredi 4 novembre 2026, 10 h (Paris).
let brainNow = parisDate(2026, 11, 4, 10, 0)

final class BrainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date = brainNow) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ s: TimeInterval) { lock.withLock { current = current.addingTimeInterval(s) } }
    var fn: @Sendable () -> Date { { self.now } }
}

let mailSrc = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Gmail", isSimulated: false)
let folderSrc = EventSource(id: SourceID("folder"), kind: .folder, displayName: "Dossier : Projets", isSimulated: false)

/// Environnement complet : Perception (vrai moteur de compréhension) → Context → Brain.
struct BrainEnv {
    let trust: TrustEngine
    let context: ContextEngine
    let brain: BrainEngine
    let store: MissionStore
    let clock: BrainClock
    let understanding = UnderstandingEngine(deadlines: DeadlineExtractor(calendar: brainCalendar))

    static func make(grants: [(SourceID, Permission)] = [(SourceID("gmail"), .readMail), (SourceID("folder"), .watchFolder)],
                     scope: ContextScope = .professional, gateway: ModelGateway? = nil,
                     store: MissionStore? = nil, clock: BrainClock = BrainClock()) async throws -> BrainEnv {
        let trust = TrustEngine(accessLog: AccessLog(), clock: clock.fn)
        for (id, p) in grants { await trust.grant(id, permission: p, scope: "test") }
        let profile = GhostProfile(id: "brain-test", baseDirectory: FileManager.default.temporaryDirectory)
        let context = ContextEngine(profile: profile, trust: trust, persistent: false)
        try await context.setScope(scope, for: SourceID("gmail"))
        try await context.setScope(scope, for: SourceID("folder"))
        var config = BrainConfig(); config.calendar = brainCalendar
        let s = store ?? MissionStore(url: nil)
        let brain = BrainEngine(store: s, context: context, trust: trust, gateway: gateway, config: config, clock: clock.fn)
        return BrainEnv(trust: trust, context: context, brain: brain, store: s, clock: clock)
    }

    func mail(from: String = "Marie Dupont <marie.dupont@acme.example>", subject: String, body: String,
              thread: String? = nil, date: Date? = nil, id: String = UUID().uuidString, bulk: Bool = false,
              reply: Bool = false, source: EventSource = mailSrc, to: [String] = ["moi@ghost.test"], cc: [String] = []) -> GhostEvent {
        let message = EmailMessage(id: id, threadID: thread, from: from, to: to, cc: cc, subject: subject,
                                   date: date ?? clock.now, bodyText: body, isBulk: bulk, isReply: reply)
        let normalized = EventNormalizer().normalize(.email(message, account: "moi@ghost.test"), from: source)
        return understanding.interpret(normalized, detectedAt: clock.now)
    }

    func file(_ name: String, path: String? = nil, source: EventSource = folderSrc, change: String = "created",
              date: Date? = nil) -> GhostEvent {
        GhostEvent(fingerprint: "file-" + UUID().uuidString, kind: .documentEvent, tags: [.documentEvent],
                   summary: "Nouveau fichier : \(name)", source: source, detectedAt: clock.now, occurredAt: date ?? clock.now,
                   title: name, confidence: 0.99, evidence: [Evidence(rule: "file.created", explanation: "test")],
                   isMissionCandidate: false, metadata: ["path": path ?? name, "change": change])
    }

    func missions() async throws -> [Mission] { Array(try await brain.snapshot().missions.values) }
    func state() async throws -> BrainState { try await brain.snapshot() }
}

let requestExcel = "Bonjour,\n\nPeux-tu me préparer un fichier Excel avec les résultats commerciaux du mois pour demain matin ?\n\nMerci,\nMarie"
