import XCTest
import AppKit
import GhostPerception
import GhostContext
@testable import GhostBrain
@testable import GhostVision
@testable import GhostMind

/// Parcours complet, comme dans l'app : image d'écran → vrai OCR d'Apple → Perception → Contexte → Brain → Mind.
/// Les parties en ligne (Apple Plans, DuckDuckGo) ne tournent qu'avec `GHOST_LIVE=1`.
private final class Frames: FrameSource, @unchecked Sendable {
    private let lock = NSLock(); private var queue: [CapturedFrame?]
    init(_ q: [CapturedFrame?]) { queue = q }
    func capture() async throws -> CapturedFrame? { lock.withLock { queue.isEmpty ? nil : queue.removeFirst() } }
}
private func screenImage(_ lines: [String]) -> CGImage {
    let fontSize: CGFloat = 40, lineHeight = fontSize * 1.9, width = 1800, height = Int(CGFloat(lines.count) * lineHeight + 80)
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
private struct Replies: LanguageModel {
    var name = "Modèle scripté"; var isLocal = true; var isSimulated = true
    var reply: @Sendable (String) -> String
    func availability() async -> LanguageModelAvailability { .available }
    func generate(system: String, prompt: String) async throws -> String { reply(prompt) }
}
private final class NoSend: MailSender, @unchecked Sendable {
    let lock = NSLock(); var sent = 0
    func send(to: String, subject: String, body: String) async throws { lock.withLock { sent += 1 } }
}

final class FullTourTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "fr_FR"); return c }
    private var live: Bool { ProcessInfo.processInfo.environment["GHOST_LIVE"] == "1" }

    private struct Outcome { var events: Int; var missions: Int; var state: MindState; var sent: Int }

    private func tour(_ lines: [String], app: String = "Messages", models: [LanguageModel] = [],
                      places: PlaceSearcher? = nil, web: WebSearcher? = nil, output: OutputWriter? = nil, home: String? = "Rueil-Malmaison") async throws -> Outcome {
        let cal = self.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 21))!
        let profile = GhostProfile(id: "tour", baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ghost-tour-\(UUID())"))
        let system = PerceptionSystem(profile: profile, persistent: false, tick: nil)
        let context = ContextEngine(profile: profile, trust: system.trust, persistent: false)
        var config = BrainConfig(); config.calendar = cal
        let brain = BrainEngine(store: MissionStore(url: nil), context: context, trust: system.trust, gateway: nil, config: config, clock: { now })
        let sender = NoSend()
        let mind = MindEngine(profile: profile, brain: brain, context: context, trust: system.trust, models: models, sender: sender, userName: "Romain",
                              searcher: places, webSearcher: web, output: output, homeArea: { home }, persistent: false, clock: { now })
        await system.engine.addConsumer(context); await system.engine.addConsumer(brain); await system.engine.addConsumer(mind)
        await system.trust.grant(SourceID("screen"), permission: .observeScreen, scope: "écran")
        await system.trust.grant(SourceID("search"), permission: .searchOnline, scope: "recherche")
        try await context.setScope(.professional, for: SourceID("screen"))
        let frame = CapturedFrame(image: screenImage(lines), context: ScreenContext(app: app, bundleID: "com.apple.MobileSMS", windowTitle: "Maxime"))
        let source = ScreenSource(frames: Frames([frame]), recognizer: VisionTextRecognizer(), trust: system.trust, pollInterval: 0.01,
                                  understanding: UnderstandingEngine(deadlines: DeadlineExtractor(calendar: cal)), appointments: AppointmentExtractor(calendar: cal), clock: { now })
        await system.engine.register(source); await system.engine.start()
        let report = await system.engine.runCycle(force: true)
        let missions = try await brain.snapshot().missions.values
        let state = try await mind.snapshot()
        return Outcome(events: report.newEvents.count, missions: missions.count, state: state, sent: sender.lock.withLock { sender.sent })
    }

    func testMailRequestTypedInMessages() async throws {
        let model = Replies { _ in #"{"subject":"RDV au resto Maison Sauvage","body":"Bonjour, on a rendez-vous au resto Maison Sauvage lundi de la semaine prochaine. À lundi ! Romain"}"# }
        let o = try await tour(["Tu peux me faire un mail a envoyer a romain.meunier92@gmail.com pour lui dire qu'on a un", "RDV au resto maison sauvage le lundi de la semaine pro stp"], models: [model])
        let draft = try XCTUnwrap(o.state.drafts.values.first)
        print("TOUR mail: events=\(o.events) missions=\(o.missions) status=\(draft.status) to=\(draft.recipientEmail ?? "nil") subject=\(draft.subject) sent=\(o.sent)")
        XCTAssertEqual(draft.recipientEmail, "romain.meunier92@gmail.com"); XCTAssertEqual(draft.status, .ready); XCTAssertEqual(o.sent, 0)
    }

    func testMailWithoutAnyAIStillGivesACleanDraft() async throws {
        let o = try await tour(["Tu peux me faire un mail a envoyer a romain.meunier92@gmail.com pour lui dire qu'on a un", "RDV au resto maison sauvage le lundi de la semaine pro stp"])
        let draft = try XCTUnwrap(o.state.drafts.values.first)
        print("TOUR mail sans IA: status=\(draft.status) to=\(draft.recipientEmail ?? "nil")\n---\n\(draft.body)\n---")
        XCTAssertEqual(draft.recipientEmail, "romain.meunier92@gmail.com"); XCTAssertEqual(draft.status, .needsModel)
    }

    func testPlacesSearchLiveFromTheFoundersExamples() async throws {
        try XCTSkipUnless(live, "GHOST_LIVE=1 requis")
        for (lines, expectArea) in [(["Trouve un club de boxe vers chez nous genre le 17"], "Rueil-Malmaison"), (["Regarde les bars vers La Défense sympa"], "La Défense")] {
            let o = try await tour(lines, places: MapKitPlaceSearcher())
            let s = try XCTUnwrap(o.state.searches.values.first)
            print("TOUR lieux «\(lines[0])»: status=\(s.status) zone=\(s.area ?? "nil") \(s.results.count) résultats ; 1er: \(s.results.first.map { "\($0.name) — \($0.address) (\(Int($0.distanceMeters ?? 0)) m)" } ?? "—") ; note=\(s.note ?? "")")
            XCTAssertEqual(s.area, expectArea); XCTAssertEqual(s.status, .done)
        }
    }

    func testWebSearchLive() async throws {
        try XCTSkipUnless(live, "GHOST_LIVE=1 requis")
        let o = try await tour(["Cherche le prix d'un abonnement de boxe à Paris"], web: DuckDuckGoSearcher())
        let s = try XCTUnwrap(o.state.searches.values.first)
        print("TOUR web: status=\(s.status) \(s.results.count) résultats ; note=\(s.note ?? "")")
        for r in s.results.prefix(3) { print("   • \(r.name) — \(r.url ?? "")") }
        XCTAssertEqual(s.status, .done); XCTAssertTrue(s.isWeb)
    }

    func testLogoAndDocumentAreCreatedInTheChosenFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-tour-out-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="96" fill="#0b0f14"/><circle cx="256" cy="256" r="150" fill="none" stroke="#8fc7ff" stroke-width="28"/></svg>"##
        let model = Replies { prompt in prompt.localizedCaseInsensitiveContains("logo") ? "```svg\n\(svg)\n```" : "# Lettre de motivation\n\nMadame, Monsieur,\n\nJe vous écris pour vous proposer ma candidature à un stage au sein de votre équipe. Mon parcours et ma motivation me semblent correspondre à vos besoins.\n\nCordialement,\nRomain" }
        let logo = try await tour(["Crée un logo pour la boîte"], models: [model], output: FolderOutputWriter(folder: dir))
        let l = try XCTUnwrap(logo.state.creations.values.first)
        print("TOUR logo: status=\(l.status) fichiers=\(l.paths.map { ($0 as NSString).lastPathComponent })")
        XCTAssertEqual(l.status, .done); XCTAssertEqual(l.paths.count, 2)
        let doc = try await tour(["Rédige une lettre de motivation pour un stage"], models: [model], output: FolderOutputWriter(folder: dir))
        let d = try XCTUnwrap(doc.state.creations.values.first)
        print("TOUR document: status=\(d.status) fichiers=\(d.paths.map { ($0 as NSString).lastPathComponent })")
        XCTAssertEqual(d.status, .done)
        for p in l.paths + d.paths { XCTAssertTrue(FileManager.default.fileExists(atPath: p), p) }
    }

    func testOrdinaryScreensProduceNothing() async throws {
        let o = try await tour(["Quelle belle journée ensoleillée à Paris", "Les articles les plus lus de la semaine"], app: "Safari")
        print("TOUR écran banal: events=\(o.events) missions=\(o.missions)")
        XCTAssertEqual(o.events, 0); XCTAssertEqual(o.missions, 0)
    }
}
