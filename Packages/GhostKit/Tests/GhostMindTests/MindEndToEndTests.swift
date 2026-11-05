import XCTest
import AppKit
import GhostPerception
import GhostContext
@testable import GhostBrain
@testable import GhostVision
@testable import GhostMind

private final class Frames: FrameSource, @unchecked Sendable {
    private let lock = NSLock(); private var queue: [CapturedFrame?]
    init(_ q: [CapturedFrame?]) { queue = q }
    func capture() async throws -> CapturedFrame? { lock.withLock { queue.isEmpty ? nil : queue.removeFirst() } }
}
private func screen(_ lines: [String]) -> CGImage {
    let fontSize: CGFloat = 40, lineHeight = fontSize * 1.9, width = 1600, height = Int(CGFloat(lines.count) * lineHeight + 80)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (i, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 40, y: CGFloat(height) - 40 - lineHeight * CGFloat(i + 1) + fontSize * 0.2),
                                withAttributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}
private final class Sender: MailSender, @unchecked Sendable {
    let count = NSLock(); var sent = 0
    func send(to: String, subject: String, body: String) async throws { count.withLock { sent += 1 } }
}
private struct FixedModel: LanguageModel {
    var name = "Modèle scripté"; var isLocal = true; var isSimulated = true
    func availability() async -> LanguageModelAvailability { .available }
    func generate(system: String, prompt: String) async throws -> String {
        #"{"subject":"Décalage de jeudi","body":"Bonjour Paul, peux-tu décaler notre point de jeudi ? Merci. Bien cordialement, Romain"}"#
    }
}

final class MindEndToEndTests: XCTestCase {
    func testRequestSeenOnScreenBecomesAReadyMailDraftThatOnlyAClickSends() async throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Paris")!; cal.locale = Locale(identifier: "fr_FR")
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-mind-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = GhostProfile(id: "e2e", baseDirectory: base)
        let system = PerceptionSystem(profile: profile, persistent: false, tick: nil)
        let context = ContextEngine(profile: profile, trust: system.trust, persistent: false)
        var config = BrainConfig(); config.calendar = cal
        let brain = BrainEngine(store: MissionStore(url: nil), context: context, trust: system.trust, gateway: nil, config: config, clock: { now })
        let sender = Sender()
        let mind = MindEngine(profile: profile, brain: brain, context: context, trust: system.trust, models: [FixedModel()], sender: sender,
                              userName: "Romain", persistent: false, clock: { now })
        await system.engine.addConsumer(context); await system.engine.addConsumer(brain); await system.engine.addConsumer(mind)
        await system.trust.grant(SourceID("screen"), permission: .observeScreen, scope: "écran")
        await system.trust.grant(SourceID("gmail"), permission: .readMail, scope: "test")
        try await context.setScope(.professional, for: SourceID("screen")); try await context.setScope(.professional, for: SourceID("gmail"))

        // Paul est déjà connu : il a écrit à l'utilisateur.
        let paulMail = EmailMessage(id: "paul-1", from: "Paul Martin <paul.martin@acme.example>", to: ["moi@ghost.test"], subject: "Salut", date: now, bodyText: "Merci pour hier.")
        let mailSource = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Gmail")
        let understanding = UnderstandingEngine(deadlines: DeadlineExtractor(calendar: cal))
        try await context.ingest([understanding.interpret(EventNormalizer().normalize(.email(paulMail, account: "moi@ghost.test"), from: mailSource), detectedAt: now)])

        // À l'écran : une conversation où l'on demande d'écrire à Paul.
        let frame = CapturedFrame(image: screen(["Direction", "Écris un mail à Paul pour décaler jeudi"]),
                                  context: ScreenContext(app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", windowTitle: "Direction"))
        let source = ScreenSource(frames: Frames([frame]), recognizer: VisionTextRecognizer(), trust: system.trust, pollInterval: 0.01,
                                  understanding: understanding, appointments: AppointmentExtractor(calendar: cal), clock: { now })
        await system.engine.register(source); await system.engine.start()
        let report = await system.engine.runCycle(force: true)
        XCTAssertEqual(report.newEvents.count, 1, "le bloc utile lu à l'écran")

        let missions = try await brain.snapshot().missions.values
        XCTAssertEqual(missions.count, 1)
        let state = try await mind.snapshot()
        let draft = try XCTUnwrap(state.drafts.values.first, "un brouillon doit exister")
        XCTAssertEqual(draft.status, .ready)
        XCTAssertEqual(draft.recipientEmail, "paul.martin@acme.example", "destinataire retrouvé dans la mémoire locale, sans rien connecter")
        XCTAssertEqual(draft.subject, "Décalage de jeudi")
        XCTAssertEqual(sender.count.withLock { sender.sent }, 0, "rien n'est parti tout seul")

        try await mind.send(draft.id, confirmedByUser: true)   // le clic sur « Envoyer »
        XCTAssertEqual(sender.count.withLock { sender.sent }, 1)
        let log = await system.accessLog.all()
        XCTAssertFalse(log.contains { $0.operation == "network.request" })
    }

    /// Message réellement tapé par le fondateur dans Messages (5 novembre 2026).
    func testPolitePhrasedRequestWithAnAddressInMessages() async throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Paris")!; cal.locale = Locale(identifier: "fr_FR")
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 21))!
        let profile = GhostProfile(id: "e2e2", baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ghost-mind-e2e-\(UUID())"))
        let system = PerceptionSystem(profile: profile, persistent: false, tick: nil)
        let context = ContextEngine(profile: profile, trust: system.trust, persistent: false)
        var config = BrainConfig(); config.calendar = cal
        let brain = BrainEngine(store: MissionStore(url: nil), context: context, trust: system.trust, gateway: nil, config: config, clock: { now })
        let mind = MindEngine(profile: profile, brain: brain, context: context, trust: system.trust, models: [FixedModel()], sender: Sender(),
                              userName: "Romain", persistent: false, clock: { now })
        await system.engine.addConsumer(context); await system.engine.addConsumer(brain); await system.engine.addConsumer(mind)
        await system.trust.grant(SourceID("screen"), permission: .observeScreen, scope: "écran")
        try await context.setScope(.professional, for: SourceID("screen"))
        let frame = CapturedFrame(image: screen(["Tu peux me faire un mail a envoyer a romain.meunier92@gmail.com pour lui dire qu'on a un", "RDV au resto maison sauvage le lundi de la semaine pro stp"]),
                                  context: ScreenContext(app: "Messages", bundleID: "com.apple.MobileSMS", windowTitle: "Maxime"))
        let source = ScreenSource(frames: Frames([frame]), recognizer: VisionTextRecognizer(), trust: system.trust, pollInterval: 0.01,
                                  understanding: UnderstandingEngine(deadlines: DeadlineExtractor(calendar: cal)), appointments: AppointmentExtractor(calendar: cal), clock: { now })
        await system.engine.register(source); await system.engine.start()
        let report = await system.engine.runCycle(force: true)
        let missions = try await brain.snapshot().missions.values
        let state = try await mind.snapshot()
        print("DIAG events=\(report.newEvents.count) missions=\(missions.count) drafts=\(state.drafts.count)")
        XCTAssertEqual(report.newEvents.count, 1); XCTAssertEqual(missions.count, 1); XCTAssertEqual(state.drafts.count, 1)
    }
}
