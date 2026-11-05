import XCTest
import GhostPerception
import GhostContext
@testable import GhostBrain
@testable import GhostVision
@testable import GhostMind

// MARK: - Aides

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "fr_FR"); return c
}()
private let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}
private struct ScriptedModel: LanguageModel {
    var name = "Modèle scripté"; var isLocal = true; var isSimulated = true
    var state: LanguageModelAvailability = .available
    var reply: @Sendable (String) -> String
    let prompts = Box<[String]>([])
    func availability() async -> LanguageModelAvailability { state }
    func generate(system: String, prompt: String) async throws -> String { prompts.update { $0.append(prompt) }; return reply(prompt) }
}
private final class FakeSender: MailSender, @unchecked Sendable {
    let sent = Box<[(to: String, subject: String, body: String)]>([])
    var failure: Error?
    func send(to: String, subject: String, body: String) async throws {
        if let failure { throw failure }
        sent.update { $0.append((to, subject, body)) }
    }
}
private let goodJSON = #"{"subject":"Décalage de jeudi","body":"Bonjour PAUL, peux-tu décaler notre point de jeudi à vendredi ? Merci d'avance. Bien cordialement, Romain"}"#

private struct Env {
    let trust: TrustEngine, context: ContextEngine, brain: BrainEngine, mind: MindEngine, sender: FakeSender
    let understanding = UnderstandingEngine(deadlines: DeadlineExtractor(calendar: cal))
    let mailSource = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Gmail")

    static func make(models: [LanguageModel], persistentIn dir: URL? = nil, sender: FakeSender = FakeSender()) async throws -> Env {
        let trust = TrustEngine(accessLog: AccessLog(), clock: { now })
        await trust.grant(SourceID("gmail"), permission: .readMail, scope: "test")
        await trust.grant(SourceID("screen"), permission: .observeScreen, scope: "écran")
        let profile = GhostProfile(id: "mind", baseDirectory: dir ?? FileManager.default.temporaryDirectory)
        let context = ContextEngine(profile: profile, trust: trust, persistent: false)
        var config = BrainConfig(); config.calendar = cal
        let brain = BrainEngine(store: MissionStore(url: nil), context: context, trust: trust, gateway: nil, config: config, clock: { now })
        let mind = MindEngine(profile: profile, brain: brain, context: context, trust: trust, models: models, sender: sender, userName: "Romain",
                              persistent: dir != nil, clock: { now })
        return Env(trust: trust, context: context, brain: brain, mind: mind, sender: sender)
    }

    func mail(from: String, subject: String, body: String, id: String = UUID().uuidString) -> GhostEvent {
        let m = EmailMessage(id: id, from: from, to: ["moi@ghost.test"], subject: subject, date: now, bodyText: body)
        return understanding.interpret(EventNormalizer().normalize(.email(m, account: "moi@ghost.test"), from: mailSource), detectedAt: now)
    }
    /// Paul est connu de la mémoire locale (il a déjà écrit à l'utilisateur).
    func knowPaul() async throws {
        try await context.ingest([mail(from: "Paul Martin <paul.martin@acme.example>", subject: "Salut", body: "Merci pour hier.")])
    }
    /// Une demande reçue → mission du Brain.
    func request(_ text: String) async throws -> GhostEvent {
        let e = mail(from: "Direction <direction@acme.example>", subject: "À faire", body: text)
        _ = try await brain.process([e]); return e
    }
    func draft() async throws -> MailDraft {
        let state = try await mind.snapshot()
        return try XCTUnwrap(state.drafts.values.first)
    }
}

// MARK: - Compréhension de la demande

final class IntentClassifierTests: XCTestCase {
    func testWriteMessage() {
        XCTAssertEqual(IntentClassifier.classify("Écris un mail à Paul pour décaler jeudi"), .writeMessage(recipient: "Paul", topic: "décaler jeudi"))
        XCTAssertEqual(IntentClassifier.classify("Envoie un message à Marie Dupont pour lui dire que c'est ok"), .writeMessage(recipient: "Marie Dupont", topic: "c'est ok"))
        if case .writeMessage(let who, _) = IntentClassifier.classify("Rédige un e-mail pour confirmer la réunion") { XCTAssertNil(who) } else { XCTFail() }
    }
    func testFindPlaces() {
        XCTAssertEqual(IntentClassifier.classify("Trouve un club de boxe vers chez nous genre le 17"), .findPlaces(query: "club de boxe", area: "chez nous", when: "le 17"))
        XCTAssertEqual(IntentClassifier.classify("Regarde les bars vers La Défense sympa"), .findPlaces(query: "bars", area: "La Défense", when: nil))
        if case .findPlaces(let q, _, _) = IntentClassifier.classify("Cherche un resto pour samedi soir") { XCTAssertEqual(q, "resto") } else { XCTFail() }
    }
    func testCreate() {
        XCTAssertEqual(IntentClassifier.classify("Crée un logo pour la boîte"), .createLogo(brief: "Crée un logo pour la boîte"))
        XCTAssertEqual(IntentClassifier.classify("Rédige une lettre de motivation pour Safran"), .createDocument(brief: "Rédige une lettre de motivation pour Safran"))
    }
    func testOrdinaryTextIsUnsupported() {
        XCTAssertEqual(IntentClassifier.classify("Il fait beau aujourd'hui"), .unsupported)
        XCTAssertEqual(IntentClassifier.classify("Peux-tu me préparer un fichier Excel pour demain ?"), .unsupported, "l'Excel est géré par le moteur d'exécution")
    }
}

final class MaskingAndParsingTests: XCTestCase {
    func testMaskIsReversible() {
        let (masked, mask) = ReversibleMask.mask("Écris à Paul Martin (paul.martin@acme.example) de la part de Romain", names: ["Paul Martin", "Romain"], emails: ["paul.martin@acme.example"])
        XCTAssertFalse(masked.contains("Paul")); XCTAssertFalse(masked.contains("@")); XCTAssertFalse(masked.contains("Romain"))
        XCTAssertEqual(mask.restore(masked), "Écris à Paul Martin (paul.martin@acme.example) de la part de Romain")
    }
    func testDraftParsingIsStrict() {
        XCTAssertNotNil(EmailDrafter.parse(goodJSON))
        XCTAssertNotNil(EmailDrafter.parse("Voici : " + goodJSON + " fin"))
        XCTAssertNil(EmailDrafter.parse("pas du json"))
        XCTAssertNil(EmailDrafter.parse(#"{"subject":"","body":"Un corps assez long pour passer"}"#))
        XCTAssertNil(EmailDrafter.parse(#"{"subject":"Objet","body":"court"}"#))
        XCTAssertNil(EmailDrafter.parse(#"{"subject":"Objet","body":"Bonjour {{nom}}, texte assez long"}"#))
        XCTAssertNil(EmailDrafter.parse(#"{"subject":"Objet"}"#))
    }
    func testAppleScriptEscapingAndAddressValidation() async {
        XCTAssertEqual(AppleMailSender.escaped("a\"b\\c\nd"), "a\\\"b\\\\c\" & return & \"d")
        do { try await AppleMailSender().send(to: "pas une adresse", subject: "x", body: "y"); XCTFail() } catch {}
        XCTAssertTrue(MailDraft.isValidAddress("paul.martin@acme.example")); XCTAssertFalse(MailDraft.isValidAddress("paul@")); XCTAssertFalse(MailDraft.isValidAddress(nil))
    }
}

// MARK: - Brouillons et envoi

final class MindEngineTests: XCTestCase {
    func testRequestBecomesReadyDraftAndNothingIsSent() async throws {
        let model = ScriptedModel(reply: { _ in goodJSON })
        let env = try await Env.make(models: [model])
        try await env.knowPaul()
        let event = try await env.request("Écris un mail à Paul pour décaler jeudi")
        await env.mind.consume([event])
        let d = try await env.draft()
        XCTAssertEqual(d.status, .ready); XCTAssertEqual(d.recipientEmail, "paul.martin@acme.example"); XCTAssertEqual(d.recipientName, "Paul Martin")
        XCTAssertEqual(d.subject, "Décalage de jeudi"); XCTAssertTrue(d.canSend)
        XCTAssertTrue(d.generatedBy.contains("SIMULÉ"), "un modèle simulé est toujours signalé")
        XCTAssertEqual(env.sender.sent.get().count, 0, "GHOST rédige seul, mais n'envoie jamais seul")
        await env.mind.consume([event])
        let again = try await env.mind.snapshot()
        XCTAssertEqual(again.drafts.count, 1, "jamais deux brouillons pour la même mission")
    }

    func testUnknownRecipientIsAskedNotGuessed() async throws {
        let env = try await Env.make(models: [ScriptedModel(reply: { _ in goodJSON })])
        let event = try await env.request("Écris un mail à Paul pour décaler jeudi")   // Paul n'est pas connu
        await env.mind.consume([event])
        let d = try await env.draft()
        XCTAssertNil(d.recipientEmail); XCTAssertFalse(d.canSend)
        XCTAssertTrue(d.note?.contains("Destinataire à préciser") ?? false, d.note ?? "")
        try await env.mind.edit(d.id, to: "paul@acme.example", subject: d.subject, body: d.body)
        let fixed = try await env.draft(); XCTAssertTrue(fixed.canSend)
    }

    func testNoModelGivesAnHonestSimplifiedDraftThenRedoWhenAvailable() async throws {
        let off = ScriptedModel(state: .unavailable("Apple Intelligence n'est pas activé : Réglages Système ▸ Apple Intelligence et Siri."), reply: { _ in goodJSON })
        let env = try await Env.make(models: [off]); try await env.knowPaul()
        await env.mind.consume([try await env.request("Écris un mail à Paul pour décaler jeudi")])
        var d = try await env.draft()
        XCTAssertEqual(d.status, .needsModel); XCTAssertFalse(d.canSend, "un brouillon simplifié n'est pas envoyable tel quel")
        XCTAssertTrue(d.generatedBy.contains("sans IA")); XCTAssertTrue(d.note?.contains("Apple Intelligence") ?? false)
        let status = await env.mind.modelStatus(); XCTAssertEqual(status.availability, off.state)
        // Le modèle devient disponible : « Refaire ».
        let on = try await Env.make(models: [ScriptedModel(reply: { _ in goodJSON })]); try await on.knowPaul()
        await on.mind.consume([try await on.request("Écris un mail à Paul pour décaler jeudi")])
        d = try await on.draft(); XCTAssertEqual(d.status, .ready)
        try await on.mind.redo(d.id)
        let redone = try await on.draft(); XCTAssertEqual(redone.version, 2); XCTAssertEqual(redone.status, .ready)
    }

    func testExternalModelOnlySeesMaskedNamesAndAnswerIsRestored() async throws {
        let external = ScriptedModel(name: "Externe", isLocal: false, isSimulated: true, reply: { prompt in
            XCTAssertFalse(prompt.contains("Paul")); XCTAssertFalse(prompt.contains("Romain")); XCTAssertFalse(prompt.contains("@"))
            // Le modèle n'a que des jetons : il les reprend tels quels dans sa réponse.
            func token(_ key: String) -> String { prompt.range(of: "\"\(key)\":\"(PERSONNE_\\d+)\"", options: .regularExpression).map { String(prompt[$0]).components(separatedBy: "\"")[3] } ?? "?" }
            return "{\"subject\":\"Point\",\"body\":\"Bonjour \(token("prenom_destinataire")), peux-tu décaler jeudi ? Bien cordialement, \(token("expediteur"))\"}"
        })
        let env = try await Env.make(models: [external]); try await env.knowPaul()
        await env.mind.consume([try await env.request("Écris un mail à Paul pour décaler jeudi")])
        let d = try await env.draft()
        XCTAssertEqual(d.status, .ready)
        XCTAssertTrue(d.body.contains("Bonjour Paul,") && d.body.contains("Bien cordialement, Romain"), "les jetons sont remplacés localement : \(d.body)")
        XCTAssertFalse(d.body.contains("PERSONNE_"))
        XCTAssertEqual(external.prompts.get().count, 1)
    }

    func testLocalModelIsPreferredAndInvalidAnswersFallBack() async throws {
        let local = ScriptedModel(name: "Local", reply: { _ in "n'importe quoi" })
        let external = ScriptedModel(name: "Externe", isLocal: false, reply: { _ in #"{"subject":"Objet ok","body":"Un texte suffisamment long pour être valide."}"# })
        let env = try await Env.make(models: [local, external]); try await env.knowPaul()
        await env.mind.consume([try await env.request("Écris un mail à Paul pour décaler jeudi")])
        let d = try await env.draft()
        XCTAssertTrue(d.generatedBy.contains("Externe"), "réponse locale inexploitable : repli sur le suivant")
        XCTAssertEqual(local.prompts.get().count, 1)
        let allBad = try await Env.make(models: [ScriptedModel(reply: { _ in "rien de valide" })])
        await allBad.mind.consume([try await allBad.request("Écris un mail à Paul pour décaler jeudi")])
        let simple = try await allBad.draft(); XCTAssertEqual(simple.status, .needsModel); XCTAssertTrue(simple.note?.contains("inexploitable") ?? false)
    }

    func testSendNeedsExplicitClickAndHappensOnce() async throws {
        let env = try await Env.make(models: [ScriptedModel(reply: { _ in goodJSON })]); try await env.knowPaul()
        await env.mind.consume([try await env.request("Écris un mail à Paul pour décaler jeudi")])
        let d = try await env.draft()
        do { try await env.mind.send(d.id, confirmedByUser: false); XCTFail("sans confirmation") } catch {}
        XCTAssertEqual(env.sender.sent.get().count, 0)
        try await env.mind.send(d.id, confirmedByUser: true)
        XCTAssertEqual(env.sender.sent.get().count, 1)
        XCTAssertEqual(env.sender.sent.get().first?.to, "paul.martin@acme.example")
        let _a1 = try await env.draft().status
        XCTAssertEqual(_a1, .sent)
        do { try await env.mind.send(d.id, confirmedByUser: true); XCTFail("déjà envoyé") } catch {}
        XCTAssertEqual(env.sender.sent.get().count, 1, "jamais deux envois")
        do { try await env.mind.cancel(d.id); XCTFail() } catch {}
        let log = await env.trust.accessLog.all()
        XCTAssertTrue(log.contains { $0.operation == "mail.send" && $0.target == "acme.example" }, "journal : le domaine seulement, pas l'adresse")
        XCTAssertFalse(log.contains { $0.target.contains("paul.martin") })
    }

    func testFailedSendIsReportedAndNotRetriedAutomatically() async throws {
        let sender = FakeSender(); sender.failure = MindError.sendFailed("Mail refuse")
        let env = try await Env.make(models: [ScriptedModel(reply: { _ in goodJSON })], sender: sender); try await env.knowPaul()
        await env.mind.consume([try await env.request("Écris un mail à Paul pour décaler jeudi")])
        let d = try await env.draft()
        do { try await env.mind.send(d.id, confirmedByUser: true); XCTFail() } catch {}
        let failed = try await env.draft()
        XCTAssertEqual(failed.status, .failed); XCTAssertFalse(failed.canSend)
        XCTAssertEqual(sender.sent.get().count, 0)
        try await env.mind.redo(d.id)
        let _a2 = try await env.draft().status
        XCTAssertEqual(_a2, .ready, "l'utilisateur peut refaire puis renvoyer")
    }

    func testInterruptedSendIsNeverReplayed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-mind-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await Env.make(models: [ScriptedModel(reply: { _ in goodJSON })], persistentIn: dir); try await first.knowPaul()
        await first.mind.consume([try await first.request("Écris un mail à Paul pour décaler jeudi")])
        let d = try await first.draft()
        // Simule une panne en plein envoi : le fichier porte l'état « sending ».
        let file = dir.appendingPathComponent("profiles/mind/mind.json")
        let json = try String(contentsOf: file).replacingOccurrences(of: "\"status\":\"ready\"", with: "\"status\":\"sending\"")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let sender = FakeSender()
        let second = try await Env.make(models: [], persistentIn: dir, sender: sender)
        await second.mind.recoverInterrupted()
        let after = try await second.draft()
        XCTAssertEqual(after.id, d.id); XCTAssertEqual(after.status, .failed)
        XCTAssertTrue(after.note?.contains("ne renvoie jamais seul") ?? false)
        do { try await second.mind.send(d.id, confirmedByUser: true); XCTFail("non envoyable tant que non refait") } catch {}
        XCTAssertEqual(sender.sent.get().count, 0)
        // Un fichier illisible n'est jamais écrasé.
        try "pas du json".write(to: file, atomically: true, encoding: .utf8)
        let third = try await Env.make(models: [], persistentIn: dir)
        do { _ = try await third.mind.snapshot(); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: file), "pas du json")
    }

    func testAutonomyCanBeSwitchedOffAndOtherRequestsAreLeftToTheirTools() async throws {
        let env = try await Env.make(models: [ScriptedModel(reply: { _ in goodJSON })]); try await env.knowPaul()
        let event = try await env.request("Écris un mail à Paul pour décaler jeudi")
        await env.mind.setAutonomous(false)
        await env.mind.consume([event])
        let _a3 = try await env.mind.snapshot().drafts.isEmpty
        XCTAssertTrue(_a3)
        await env.mind.setAutonomous(true)
        let other = try await env.request("Peux-tu me préparer un fichier Excel avec les chiffres pour demain ?")
        await env.mind.consume([other])
        let _a4 = try await env.mind.snapshot().drafts.isEmpty
        XCTAssertTrue(_a4, "l'Excel n'est pas un mail")
        try await env.mind.deleteMemory()
    }
}

// MARK: - Recherche de lieux

private struct FakeSearcher: PlaceSearcher {
    var results: [PlaceResult]
    var failure: Error?
    let calls = Box<[(query: String, area: String)]>([])
    func search(query: String, area: String) async throws -> [PlaceResult] {
        calls.update { $0.append((query, area)) }
        if let failure { throw failure }
        return results
    }
}
private let boxingClub = PlaceResult(id: "1", name: "Boxing Club Courbevoie", address: "12 rue de Paris, Courbevoie", phone: "+33 1 00 00 00 00",
                                     url: nil, latitude: 48.9, longitude: 2.25, distanceMeters: 900)

final class PlaceSearchTests: XCTestCase {
    private func make(searcher: FakeSearcher, authorized: Bool = true, home: String? = "Courbevoie") async throws -> (MindEngine, Env, FakeSearcher) {
        let env = try await Env.make(models: [])
        if authorized { await env.trust.grant(SourceID("search"), permission: .searchOnline, scope: "Apple Plans") }
        let mind = MindEngine(profile: GhostProfile(id: "places", baseDirectory: FileManager.default.temporaryDirectory), brain: env.brain, context: env.context,
                              trust: env.trust, models: [], sender: env.sender, userName: "Romain", searcher: searcher, homeArea: { home },
                              persistent: false, clock: { now })
        return (mind, env, searcher)
    }
    private func run(_ text: String, searcher: FakeSearcher, authorized: Bool = true, home: String? = "Courbevoie") async throws -> (PlaceSearch, FakeSearcher) {
        let (mind, env, s) = try await make(searcher: searcher, authorized: authorized, home: home)
        await mind.consume([try await env.request(text)])
        let state = try await mind.snapshot()
        return (try XCTUnwrap(state.searches.values.first), s)
    }

    func testNamedAreaIsSearchedAndResultsAreKept() async throws {
        let (search, s) = try await run("Regarde les bars vers La Défense sympa", searcher: FakeSearcher(results: [boxingClub]))
        XCTAssertEqual(search.status, .done); XCTAssertEqual(search.results.count, 1)
        XCTAssertEqual(s.calls.get().first?.query, "bars"); XCTAssertEqual(s.calls.get().first?.area, "La Défense")
    }
    func testHomeAreaUsesTheAddressTheUserGaveAndKeepsTheDate() async throws {
        let (search, s) = try await run("Trouve un club de boxe vers chez nous genre le 17", searcher: FakeSearcher(results: [boxingClub]))
        XCTAssertEqual(s.calls.get().first?.area, "Courbevoie"); XCTAssertEqual(s.calls.get().first?.query, "club de boxe")
        XCTAssertEqual(search.when, "le 17"); XCTAssertEqual(search.area, "Courbevoie")
    }
    func testHomeWithoutAnAddressAsksInsteadOfGuessing() async throws {
        let (search, s) = try await run("Trouve un club de boxe vers chez nous", searcher: FakeSearcher(results: [boxingClub]), home: nil)
        XCTAssertEqual(search.status, .needsArea); XCTAssertTrue(search.note?.contains("Sources") ?? false)
        XCTAssertTrue(s.calls.get().isEmpty, "aucune requête sans zone")
    }
    func testNothingLeavesTheMacWithoutAuthorization() async throws {
        let (search, s) = try await run("Regarde les bars vers La Défense sympa", searcher: FakeSearcher(results: [boxingClub]), authorized: false)
        XCTAssertEqual(search.status, .notAuthorized); XCTAssertTrue(s.calls.get().isEmpty)
    }
    func testFailureAndEmptyResultsAreReportedHonestly() async throws {
        let (failed, _) = try await run("Regarde les bars vers La Défense sympa", searcher: FakeSearcher(results: [], failure: MindError.invalid("Zone introuvable.")))
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.note, "Zone introuvable.")
        let (empty, _) = try await run("Regarde les bars vers La Défense sympa", searcher: FakeSearcher(results: []))
        XCTAssertEqual(empty.status, .noResults)
    }
    func testSearchIsNotRepeatedAndCanBeRerunOrHidden() async throws {
        let (mind, env, s) = try await make(searcher: FakeSearcher(results: [boxingClub]))
        let event = try await env.request("Regarde les bars vers La Défense sympa")
        await mind.consume([event]); await mind.consume([event])
        XCTAssertEqual(s.calls.get().count, 1, "une demande = une recherche")
        let before = try await mind.snapshot()
        let id = try XCTUnwrap(before.searches.keys.first)
        try await mind.rerunSearch(id); XCTAssertEqual(s.calls.get().count, 2)
        try await mind.hideSearch(id)
        let after = try await mind.snapshot()
        XCTAssertTrue(after.searches[id]?.hidden ?? false)
        let log = await env.trust.accessLog.all()
        XCTAssertTrue(log.contains { $0.operation == "places.search" && $0.target.contains("bars") })
    }
}

// MARK: - Création (logos, documents)

private let goodSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="96" fill="#0b0f14"/><circle cx="256" cy="256" r="150" fill="none" stroke="#8fc7ff" stroke-width="28"/><path d="M180 300 L256 170 L332 300 Z" fill="#8fc7ff"/></svg>
"""
private let goodDocument = "# Lettre de motivation\n\nMadame, Monsieur,\n\nJe vous écris pour vous faire part de mon intérêt pour le poste proposé au sein de votre équipe. Mon parcours m'a préparé à relever ce type de défi.\n\n- Rigueur\n- Curiosité\n\nBien cordialement,\nRomain"

final class SVGGuardTests: XCTestCase {
    func testValidSVGIsAcceptedAndRenderedToARealImage() throws {
        XCTAssertNil(SVGGuard.problem(goodSVG))
        XCTAssertEqual(SVGGuard.extract("Voici le logo :\n```svg\n" + goodSVG + "\n```"), goodSVG.trimmingCharacters(in: .whitespacesAndNewlines))
        let rendered = SVGGuard.render(goodSVG)
        let png = try XCTUnwrap(rendered.png, rendered.problem ?? "")
        XCTAssertGreaterThan(png.count, 1_000)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "signature PNG")
    }
    func testDangerousOrBrokenSVGIsRejected() {
        XCTAssertNotNil(SVGGuard.problem(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><script>alert(1)</script></svg>"#))
        XCTAssertNotNil(SVGGuard.problem(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" onload="x()"></svg>"#))
        XCTAssertNotNil(SVGGuard.problem(#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><image xlink:href="https://evil.example/a.png"/></svg>"#))
        XCTAssertNotNil(SVGGuard.problem(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><a href="https://evil.example"><rect width="5" height="5"/></a></svg>"#))
        XCTAssertNotNil(SVGGuard.problem(#"<!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>"#))
        XCTAssertNotNil(SVGGuard.problem("<svg viewBox=\"0 0 10 10\"><rect></svg>"), "mal formé")
        XCTAssertNotNil(SVGGuard.problem(#"<svg xmlns="http://www.w3.org/2000/svg"><rect width="5" height="5"/></svg>"#), "sans dimensions")
        XCTAssertNotNil(SVGGuard.problem("<svg viewBox=\"0 0 1 1\">" + String(repeating: "<g/>", count: 700) + "</svg>"), "trop complexe")
        XCTAssertNil(SVGGuard.extract("aucun dessin ici"))
    }
    func testBlankLogoIsRejectedAfterRendering() {
        let blank = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" fill="none"/></svg>"#
        XCTAssertNil(SVGGuard.problem(blank))
        XCTAssertNil(SVGGuard.render(blank).png, "un logo vide n'est jamais enregistré")
        let flat = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" fill="#ff0000"/></svg>"##
        XCTAssertNil(SVGGuard.render(flat).png, "un aplat uni n'est pas un logo")
    }
}

final class FolderOutputWriterTests: XCTestCase {
    func testNeverOverwritesAndStaysInsideTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-out-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FolderOutputWriter(folder: dir)
        let a = try writer.write(Data("un".utf8), preferredName: "Logo.svg")
        let b = try writer.write(Data("deux".utf8), preferredName: "Logo.svg")
        XCTAssertEqual(a.lastPathComponent, "Logo.svg"); XCTAssertEqual(b.lastPathComponent, "Logo (2).svg")
        XCTAssertEqual(try String(contentsOf: a), "un", "le premier fichier est intact")
        let sneaky = try writer.write(Data("x".utf8), preferredName: "../../etc/passwd")
        XCTAssertEqual(sneaky.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(writer.folderName, dir.lastPathComponent)
        XCTAssertThrowsError(try FolderOutputWriter().write(Data("x".utf8), preferredName: "a.txt"), "aucun dossier choisi")
    }
}

final class CreationTests: XCTestCase {
    private func make(models: [LanguageModel], withFolder: Bool = true) async throws -> (MindEngine, Env, URL) {
        let env = try await Env.make(models: [])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-create-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = FolderOutputWriter(folder: withFolder ? dir : nil)
        let mind = MindEngine(profile: GhostProfile(id: "create", baseDirectory: FileManager.default.temporaryDirectory), brain: env.brain, context: env.context,
                              trust: env.trust, models: models, sender: env.sender, userName: "Romain", output: writer, persistent: false, clock: { now })
        return (mind, env, dir)
    }
    private func creation(_ mind: MindEngine) async throws -> Creation {
        let state = try await mind.snapshot()
        return try XCTUnwrap(state.creations.values.first)
    }

    func testLogoIsDrawnValidatedRenderedAndSavedWithoutOverwriting() async throws {
        let model = ScriptedModel(reply: { _ in "Voici votre logo :\n" + goodSVG })
        let (mind, env, dir) = try await make(models: [model]); defer { try? FileManager.default.removeItem(at: dir) }
        let event = try await env.request("Crée un logo pour la boîte")
        await mind.consume([event])
        let c = try await creation(mind)
        XCTAssertEqual(c.status, .done); XCTAssertEqual(c.kind, .logo); XCTAssertEqual(c.paths.count, 2)
        XCTAssertTrue(c.paths.allSatisfy { FileManager.default.fileExists(atPath: $0) && $0.hasPrefix(dir.path) })
        XCTAssertTrue(c.paths.contains { $0.hasSuffix(".svg") } && c.paths.contains { $0.hasSuffix(".png") })
        XCTAssertTrue(c.generatedBy?.contains("SIMULÉ") ?? false)
        await mind.consume([event])
        let again = try await mind.snapshot(); XCTAssertEqual(again.creations.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2, "une demande = un seul jeu de fichiers")
        try await mind.redoCreation(c.id)
        let redone = try await creation(mind)
        XCTAssertEqual(redone.version, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 4, "la nouvelle version ne remplace pas l'ancienne")
        for p in c.paths { XCTAssertTrue(FileManager.default.fileExists(atPath: p)) }
    }

    func testDocumentIsWrittenAsReadableRTF() async throws {
        let (mind, env, dir) = try await make(models: [ScriptedModel(reply: { _ in goodDocument })]); defer { try? FileManager.default.removeItem(at: dir) }
        await mind.consume([try await env.request("Rédige une lettre de motivation pour Safran")])
        let c = try await creation(mind)
        XCTAssertEqual(c.status, .done); XCTAssertEqual(c.title, "Lettre de motivation")
        let path = try XCTUnwrap(c.paths.first); XCTAssertTrue(path.hasSuffix("Lettre de motivation.rtf"))
        let text = try NSAttributedString(url: URL(fileURLWithPath: path), options: [:], documentAttributes: nil).string
        XCTAssertTrue(text.contains("Lettre de motivation") && text.contains("Madame, Monsieur") && text.contains("• Rigueur"), text)
        XCTAssertFalse(text.contains("# "), "le Markdown est mis en forme, pas affiché tel quel")
    }

    func testNothingIsInventedWithoutAModelOrWithoutAFolder() async throws {
        let off = ScriptedModel(state: .unavailable("Apple Intelligence n'est pas activé : Réglages Système ▸ Apple Intelligence et Siri."), reply: { _ in goodSVG })
        let (noModel, env, dir) = try await make(models: [off]); defer { try? FileManager.default.removeItem(at: dir) }
        await noModel.consume([try await env.request("Crée un logo pour la boîte")])
        let c = try await creation(noModel)
        XCTAssertEqual(c.status, .needsModel); XCTAssertTrue(c.paths.isEmpty); XCTAssertTrue(c.note?.contains("Apple Intelligence") ?? false)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

        let model = ScriptedModel(reply: { _ in goodSVG })
        let (noFolder, env2, dir2) = try await make(models: [model], withFolder: false); defer { try? FileManager.default.removeItem(at: dir2) }
        await noFolder.consume([try await env2.request("Crée un logo pour la boîte")])
        let d = try await creation(noFolder)
        XCTAssertEqual(d.status, .needsFolder); XCTAssertTrue(model.prompts.get().isEmpty, "pas de génération inutile sans dossier")
    }

    func testUnsafeOrBlankModelOutputIsNeverSaved() async throws {
        let evil = ScriptedModel(reply: { _ in #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><script>alert(1)</script></svg>"# })
        let (mind, env, dir) = try await make(models: [evil]); defer { try? FileManager.default.removeItem(at: dir) }
        await mind.consume([try await env.request("Crée un logo pour la boîte")])
        let c = try await creation(mind)
        XCTAssertNotEqual(c.status, .done); XCTAssertTrue(c.paths.isEmpty); XCTAssertTrue(c.note?.contains("interdit") ?? false, c.note ?? "")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testExternalModelNeverSeesTheUserName() async throws {
        let external = ScriptedModel(name: "Externe", isLocal: false, reply: { prompt in
            XCTAssertFalse(prompt.contains("Romain")); return goodDocument })
        let (mind, env, dir) = try await make(models: [external]); defer { try? FileManager.default.removeItem(at: dir) }
        await mind.consume([try await env.request("Rédige une lettre de motivation de la part de Romain pour Safran")])
        let c = try await creation(mind); XCTAssertEqual(c.status, .done)
        XCTAssertEqual(external.prompts.get().count, 1)
    }
}

// MARK: - Recherche web

private struct FakeWebSearcher: WebSearcher {
    var results: [PlaceResult]
    var failure: Error?
    let calls = Box<[String]>([])
    func search(query: String) async throws -> [PlaceResult] {
        calls.update { $0.append(query) }
        if let failure { throw failure }
        return results
    }
}

final class WebSearchTests: XCTestCase {
    private let page = PlaceResult(id: "https://exemple.fr/tarifs", name: "Tarifs boxe", address: "Abonnements de 40 à 60 €", url: "https://exemple.fr/tarifs", latitude: 0, longitude: 0)

    func testClassifierFindsWebQueriesButNotPlacesOrAmbiguousPhrases() {
        XCTAssertEqual(IntentClassifier.classify("Cherche le prix d'un abonnement de boxe à Paris"), .searchWeb(query: "le prix d'un abonnement de boxe à Paris"))
        XCTAssertEqual(IntentClassifier.classify("Trouve-moi des infos sur la loi Pinel"), .searchWeb(query: "la loi Pinel"))
        if case .findPlaces = IntentClassifier.classify("Trouve un club de boxe vers chez nous") {} else { XCTFail("un lieu reste un lieu") }
        XCTAssertEqual(IntentClassifier.classify("Regarde cette présentation avant demain"), .unsupported)
        XCTAssertEqual(IntentClassifier.classify("Cherche"), .unsupported)
    }

    private func run(_ text: String, searcher: FakeWebSearcher, authorized: Bool = true) async throws -> (PlaceSearch, FakeWebSearcher) {
        let env = try await Env.make(models: [])
        if authorized { await env.trust.grant(SourceID("search"), permission: .searchOnline, scope: "web") }
        let mind = MindEngine(profile: GhostProfile(id: "web", baseDirectory: FileManager.default.temporaryDirectory), brain: env.brain, context: env.context,
                              trust: env.trust, models: [], sender: env.sender, userName: "Romain", webSearcher: searcher, persistent: false, clock: { now })
        await mind.consume([try await env.request(text)])
        let state = try await mind.snapshot()
        return (try XCTUnwrap(state.searches.values.first), searcher)
    }

    func testWebSearchKeepsResultsAndSendsOnlyTheQuestion() async throws {
        let (search, s) = try await run("Cherche le prix d'un abonnement de boxe à Paris", searcher: FakeWebSearcher(results: [page]))
        XCTAssertEqual(search.status, .done); XCTAssertTrue(search.isWeb); XCTAssertEqual(search.results.first?.url, "https://exemple.fr/tarifs")
        XCTAssertEqual(s.calls.get(), ["le prix d'un abonnement de boxe à Paris"])
    }
    func testNothingLeavesTheMacWithoutAuthorizationAndFailuresAreHonest() async throws {
        let (denied, s) = try await run("Cherche le prix d'un abonnement de boxe à Paris", searcher: FakeWebSearcher(results: [page]), authorized: false)
        XCTAssertEqual(denied.status, .notAuthorized); XCTAssertTrue(s.calls.get().isEmpty)
        let (failed, _) = try await run("Cherche le prix d'un abonnement de boxe à Paris", searcher: FakeWebSearcher(results: [], failure: MindError.invalid("Service indisponible.")))
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.note, "Service indisponible.")
    }

    // Page réelle de DuckDuckGo enregistrée le 5 novembre 2026 (10 résultats, aucune publicité).
    func testParsesARealDuckDuckGoPage() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/duckduckgo-results.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let results = try DuckDuckGoSearcher.parse(html: html, limit: 6)
        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(results[0].name, "Prix d'un cours de boxe à Paris : tarifs 2026 détaillés")
        XCTAssertEqual(results[0].url, "https://sbcparis.fr/guides/tarifs-boxe/prix-cours-boxe-paris/")
        XCTAssertTrue(results[0].address.contains("abonnements SBC de 144 à 220 €/mois"), "balises <b> retirées, entités décodées")
        XCTAssertFalse(results.contains { $0.name.contains("<") || $0.address.contains("&#x27;") })
    }
    func testRedirectLinksAdsAndUnknownPages() throws {
        XCTAssertEqual(DuckDuckGoSearcher.resolve("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexemple.fr%2Fa&rut=x")?.absoluteString, "https://exemple.fr/a")
        XCTAssertNil(DuckDuckGoSearcher.resolve("https://duckduckgo.com/y.js?ad=1"))
        XCTAssertNil(DuckDuckGoSearcher.resolve("javascript:alert(1)"))
        XCTAssertThrowsError(try DuckDuckGoSearcher.parse(html: "<html>captcha</html>", limit: 5))
        XCTAssertEqual(try DuckDuckGoSearcher.parse(html: "<div class=\"no-results\">Aucun résultat</div>", limit: 5), [])
    }
    func testSearcherSendsOnlyTheQueryAndRejectsHTTPErrors() async throws {
        let seen = Box<URLRequest?>(nil)
        let ok = DuckDuckGoSearcher { request in
            seen.update { $0 = request }
            return (Data("<div class=\"no-results\"></div>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await ok.search(query: "boxe paris")
        let body = String(data: try XCTUnwrap(seen.get()?.httpBody), encoding: .utf8) ?? ""
        XCTAssertEqual(body, "q=boxe%20paris&kl=fr-fr")
        let bad = DuckDuckGoSearcher { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!) }
        do { _ = try await bad.search(query: "x y"); XCTFail("429 doit échouer") } catch { XCTAssertTrue(error.localizedDescription.contains("429")) }
    }
}
