import XCTest
import GhostPerception
import GhostContext
@testable import GhostBrain
@testable import GhostVision

private func frame(_ lines: [String], app: String = "WhatsApp", bundleID: String? = "net.whatsapp.WhatsApp", title: String? = "Marie") -> CapturedFrame {
    CapturedFrame(image: renderScreen(lines), context: ScreenContext(app: app, bundleID: bundleID, windowTitle: title))
}
private let dinner = "On a un dîner le 10 novembre à 21h"
private let request = "Peux-tu me préparer un fichier Excel pour demain matin ?"

private func makeSource(_ frames: [CapturedFrame?], grant: Bool = true) async -> (ScreenSource, FakeFrames, CountingRecognizer) {
    let trust = TrustEngine(accessLog: AccessLog(), clock: { visionNow })
    if grant { await trust.grant(SourceID("screen"), permission: .observeScreen, scope: "écran") }
    let fake = FakeFrames(frames), recognizer = CountingRecognizer(inner: VisionTextRecognizer())
    let source = ScreenSource(frames: fake, recognizer: recognizer, trust: trust,
                              understanding: UnderstandingEngine(deadlines: DeadlineExtractor(calendar: visionCalendar)),
                              appointments: AppointmentExtractor(calendar: visionCalendar), clock: { visionNow })
    return (source, fake, recognizer)
}

final class ScreenSourceTests: XCTestCase {
    func testUsefulBlocksBecomeObservationsAndNothingElse() async throws {
        let (source, _, _) = await makeSource([frame(["Marie", dinner, "", "", "Direction", request, "", "", "Photos de vacances en Italie cet été"])])
        let observations = try await source.poll()
        XCTAssertEqual(observations.count, 2, "le dîner et la demande, pas la phrase sans intérêt")
        let snapshots = observations.compactMap { obs -> ScreenSnapshot? in if case .screen(let s) = obs { return s } else { return nil } }
        let appointment = try XCTUnwrap(snapshots.first { $0.metadata["appt.title"] != nil })
        XCTAssertEqual(appointment.metadata["appt.title"], "Dîner")
        XCTAssertEqual(appointment.metadata["appt.certain"], "1")
        XCTAssertEqual(appointment.app, "WhatsApp")
        XCTAssertTrue(snapshots.contains { $0.text.contains("fichier Excel") })
        XCTAssertFalse(snapshots.contains { $0.text.contains("Italie") }, "le texte inutile n'est pas conservé")
        // La demande devient, via le moteur de compréhension, un candidat mission.
        let engine = UnderstandingEngine(deadlines: DeadlineExtractor(calendar: visionCalendar))
        let requestSnapshot = try XCTUnwrap(snapshots.first { $0.text.contains("fichier Excel") })
        let event = engine.interpret(EventNormalizer().normalize(.screen(requestSnapshot), from: source.descriptor), detectedAt: visionNow)
        XCTAssertTrue(event.isMissionCandidate); XCTAssertEqual(event.expectedOutput, "Fichier Excel")
        XCTAssertTrue(event.summary.contains("Vu dans WhatsApp"), event.summary)
    }

    func testUnchangedScreenAndAlreadySeenContentAreNotReprocessed() async throws {
        let first = frame(["Marie", dinner])
        let (source, fake, recognizer) = await makeSource([first, first, frame(["Marie", dinner, "", "", "Autre chose sans rapport avec rien"])])
        let a = try await source.poll()
        let b = try await source.poll()
        let c = try await source.poll()
        XCTAssertEqual(a.count, 1); XCTAssertTrue(b.isEmpty, "écran identique : pas de nouvelle lecture"); XCTAssertEqual(recognizer.calls, 2)
        XCTAssertTrue(c.isEmpty, "même message resté affiché : traité une seule fois")
        XCTAssertEqual(fake.captureCount, 3)
    }

    func testExcludedAppsAreNeverRead() async throws {
        let (source, _, recognizer) = await makeSource([frame([dinner], app: "1Password", bundleID: "com.1password.1password"),
                                                         frame([dinner], app: "Safari", bundleID: "com.apple.Safari", title: "Navigation privée"),
                                                         frame([dinner], app: "Safari", bundleID: "com.apple.Safari", title: "Boursorama Banque")])
        for _ in 0..<3 { let observations = try await source.poll(); XCTAssertTrue(observations.isEmpty) }
        XCTAssertEqual(recognizer.calls, 0, "ni lecture ni reconnaissance de texte pour une application ou fenêtre exclue")
    }

    func testSecretsAndOrdinaryWebTextProduceNothing() async throws {
        let (source, _, _) = await makeSource([frame(["Mot de passe : hunter2 pour le dîner du 10 novembre à 21h"], app: "Notes"),
                                               frame(["Please subscribe to our newsletter for updates"], app: "Safari", title: "Blog")])
        let secret = try await source.poll(); XCTAssertTrue(secret.isEmpty, "bloc sensible ignoré en entier")
        let web = try await source.poll(); XCTAssertTrue(web.isEmpty, "une simple formule de politesse n'est pas une mission")
    }

    func testRequiresUserAuthorizationAndSkipsWhenNothingToCapture() async throws {
        let (denied, fake, _) = await makeSource([frame([dinner])], grant: false)
        do { _ = try await denied.poll(); XCTFail("sans autorisation GHOST") } catch {}
        XCTAssertEqual(fake.captureCount, 0, "aucune capture sans autorisation")
        let (locked, _, _) = await makeSource([nil])
        let none = try await locked.poll(); XCTAssertTrue(none.isEmpty, "écran verrouillé, permission macOS absente ou GHOST au premier plan")
    }
}

final class CalendarAgentTests: XCTestCase {
    private func make(granted: Bool = true, ledger: URL? = nil, access: CalendarAuthorization = .authorized) async -> (CalendarAgent, FakeCalendar) {
        let trust = TrustEngine(accessLog: AccessLog(), clock: { visionNow })
        if granted { await trust.grant(CalendarAgent.sourceID, permission: .writeCalendar, scope: "agenda") }
        let calendar = FakeCalendar(); await calendar.setAccess(access)
        return (CalendarAgent(writer: calendar, trust: trust, ledgerURL: ledger, calendar: visionCalendar, clock: { visionNow }), calendar)
    }

    func testCertainAppointmentIsAddedVerifiedAndTraced() async throws {
        let (agent, calendar) = await make()
        await agent.consume([apptEvent(draft())])
        let store = await calendar.store
        XCTAssertEqual(store.count, 1)
        let event = try XCTUnwrap(store.values.first)
        XCTAssertEqual(event.title, "Dîner"); XCTAssertEqual(event.start, parisAt(2026, 11, 10, 21))
        let notes = await calendar.createdNotes[event.identifier] ?? ""
        XCTAssertTrue(notes.contains("Ajouté par GHOST") && notes.contains("WhatsApp") && notes.contains("dîner"), notes)
        let _a1 = try await agent.entries().first
        let entry = try XCTUnwrap(_a1)
        XCTAssertEqual(entry.status, .added); XCTAssertEqual(entry.eventIdentifier, event.identifier)
    }

    func testNoDuplicateFromLedgerOrFromAnExistingEvent() async throws {
        let (agent, calendar) = await make()
        await agent.consume([apptEvent(draft())]); await agent.consume([apptEvent(draft())])
        let afterReplay = await calendar.store.count
        XCTAssertEqual(afterReplay, 1, "même rendez-vous revu : jamais deux événements")
        let (other, calendar2) = await make()
        _ = await calendar2.seed("Dîner avec Marie", at: parisAt(2026, 11, 10, 21))
        await other.consume([apptEvent(draft())])
        let count2 = await calendar2.store.count
        XCTAssertEqual(count2, 1, "un événement équivalent existait déjà dans l'agenda")
        let _a2 = try await other.entries().first?.status
        XCTAssertEqual(_a2, .alreadyPresent)
    }

    func testUncertainOrUnauthorizedAppointmentsAreOnlySuggested() async throws {
        let (agent, calendar) = await make()
        await agent.consume([apptEvent(draft("Dîner", certain: false, explicit: true))])
        await agent.consume([apptEvent(draft("Déjeuner", start: parisAt(2026, 11, 12, 12), certain: false, explicit: false))])
        let noneYet = await calendar.store.count
        XCTAssertEqual(noneYet, 0)
        let suggestions = try await agent.entries(); XCTAssertEqual(suggestions.map(\.status), [.suggested, .suggested])
        let lunch = try XCTUnwrap(suggestions.first { $0.title == "Déjeuner" })
        try await agent.accept(lunch.id, start: parisAt(2026, 11, 12, 12, 30))
        let _a3 = await calendar.store.values.first
        let created = try XCTUnwrap(_a3)
        XCTAssertEqual(created.start, parisAt(2026, 11, 12, 12, 30), "l'utilisateur précise l'heure")

        let (notGranted, calendar2) = await make(granted: false)
        await notGranted.consume([apptEvent(draft())])
        let none2 = await calendar2.store.count
        XCTAssertEqual(none2, 0, "ajout automatique non autorisé dans GHOST")
        let _a4 = try await notGranted.entries().first?.reason?.contains("non autorisé") ?? false
        XCTAssertTrue(_a4)
        let (noAccess, calendar3) = await make(access: .denied)
        await noAccess.consume([apptEvent(draft())])
        let none3 = await calendar3.store.count
        XCTAssertEqual(none3, 0, "accès à l'agenda non accordé par macOS")
        do { try await noAccess.accept(try await noAccess.entries()[0].id); XCTFail() } catch {}
    }

    func testPastAndFarFutureAppointmentsAreIgnored() async throws {
        let (agent, calendar) = await make()
        await agent.consume([apptEvent(draft(start: parisAt(2026, 11, 1, 21))), apptEvent(draft("Mariage", start: parisAt(2028, 5, 1, 15)))])
        let count = await calendar.store.count
        XCTAssertEqual(count, 0)
        let _a5 = try await agent.entries().isEmpty
        XCTAssertTrue(_a5)
    }

    func testUndoDeletesOnlyWhatGhostCreated() async throws {
        let (agent, calendar) = await make()
        let mine = await calendar.seed("Dentiste", at: parisAt(2026, 11, 20, 9))
        await agent.consume([apptEvent(draft())])
        let _a6 = try await agent.entries().first { $0.status == .added }
        let entry = try XCTUnwrap(_a6)
        try await agent.undo(entry.id)
        let remaining = await calendar.store
        XCTAssertEqual(remaining.keys.sorted(), [mine], "l'événement de l'utilisateur est intact, celui de GHOST est supprimé")
        let _a7 = try await agent.entries().first { $0.id == entry.id }?.status
        XCTAssertEqual(_a7, .undone)
        do { try await agent.undo(entry.id); XCTFail("déjà annulé") } catch {}
        do { try await agent.undo("n'importe quoi"); XCTFail() } catch {}
        // Un rendez-vous annulé n'est pas rajouté tout seul au prochain passage.
        await agent.consume([apptEvent(draft())])
        let afterReplay = await calendar.store.count
        XCTAssertEqual(afterReplay, 1)
    }

    func testFailedVerificationRemovesTheEventAndCrashAfterCreateNeverDuplicates() async throws {
        let (agent, calendar) = await make()
        await calendar.setCorruptFetch(true)
        await agent.consume([apptEvent(draft())])
        let countAfterFailure = await calendar.store.count
        XCTAssertEqual(countAfterFailure, 0, "ajout non conforme retiré")
        let _a8 = try await agent.entries().first?.status
        XCTAssertEqual(_a8, .failed)

        let (crashy, calendar2) = await make()
        await calendar2.setFailAfterCreate(true)
        await crashy.consume([apptEvent(draft())])                       // événement créé, puis « panne »
        await calendar2.setFailAfterCreate(false)
        await crashy.consume([apptEvent(draft())])                       // nouvelle tentative
        let count = await calendar2.store.count
        XCTAssertEqual(count, 1, "la reprise retrouve l'événement déjà créé au lieu d'en créer un second")
        let _a9 = try await crashy.entries().first?.status
        XCTAssertEqual(_a9, .added)
    }

    func testLedgerPersistsIsNeverOverwrittenWhenCorruptAndCanBeErased() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-cal-\(UUID())/ledger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (agent, _) = await make(ledger: url)
        await agent.consume([apptEvent(draft())])
        let (reopened, calendar) = await make(ledger: url)
        let _a10 = try await reopened.entries().count
        XCTAssertEqual(_a10, 1)
        await reopened.consume([apptEvent(draft())])
        let count = await calendar.store.count
        XCTAssertEqual(count, 0, "le registre relu empêche de rajouter ce rendez-vous")
        try await reopened.deleteMemory()
        let _a11 = try await reopened.entries().isEmpty
        XCTAssertTrue(_a11)
        let garbage = Data("pas du json".utf8); try garbage.write(to: url)
        let (broken, _) = await make(ledger: url)
        do { _ = try await broken.entries(); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }
}

/// Critère de la Mission 006 avec les vrais composants : écran → Perception → Contexte → Brain, et agenda.
final class ScreenEndToEndTests: XCTestCase {
    func testWhatIsOnScreenBecomesMissionAndCalendarEventWithoutConnectingAnything() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-vision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = GhostProfile(id: "vision", baseDirectory: base)
        let system = PerceptionSystem(profile: profile, persistent: false, tick: nil)
        let understanding = UnderstandingEngine(deadlines: DeadlineExtractor(calendar: visionCalendar))
        let context = ContextEngine(profile: profile, trust: system.trust, persistent: false)
        var config = BrainConfig(); config.calendar = visionCalendar
        let brain = BrainEngine(store: MissionStore(url: nil), context: context, trust: system.trust, gateway: nil, config: config, clock: { visionNow })
        let calendar = FakeCalendar()
        let agent = CalendarAgent(writer: calendar, trust: system.trust, ledgerURL: nil, calendar: visionCalendar, clock: { visionNow })
        await system.engine.addConsumer(context); await system.engine.addConsumer(brain); await system.engine.addConsumer(agent)

        // L'utilisateur a accepté une fois (consentement) : écran et ajout à l'agenda. Rien d'autre n'est connecté.
        await system.trust.grant(SourceID("screen"), permission: .observeScreen, scope: "écran")
        await system.trust.grant(CalendarAgent.sourceID, permission: .writeCalendar, scope: "agenda")
        let fake = FakeFrames([frame(["Marie", dinner, "", "", "Direction", request])])
        let source = ScreenSource(frames: fake, recognizer: VisionTextRecognizer(), trust: system.trust, pollInterval: 0.01,
                                  understanding: understanding, appointments: AppointmentExtractor(calendar: visionCalendar), clock: { visionNow })
        await system.engine.register(source)
        await system.engine.start()

        let report = await system.engine.runCycle(force: true)
        XCTAssertEqual(report.newEvents.count, 2)

        // Le dîner est dans l'agenda.
        let events = await calendar.store.values
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "Dîner"); XCTAssertEqual(events.first?.start, parisAt(2026, 11, 10, 21))
        // La demande vue à l'écran est devenue une mission, sans qu'aucune boîte mail ne soit connectée.
        let state = try await brain.snapshot()
        let mission = try XCTUnwrap(state.missions.values.first)
        XCTAssertEqual(mission.goal.deliverable, "Fichier Excel")
        XCTAssertEqual(mission.originSourceName, "Écran")
        XCTAssertTrue(mission.triggers.first?.summary.contains("Vu dans WhatsApp") ?? false)
        XCTAssertFalse(BrainTrust.executionAllowed(mission))
        // Seuls des blocs utiles sont conservés : pas de texte d'écran en masse, jamais d'image.
        let stored = try await system.store.all()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.source.kind == .screen })
        XCTAssertFalse(stored.map { $0.summary + $0.title + ($0.metadata["appt.excerpt"] ?? "") }.joined().contains("Photos"))

        // Pause : plus aucune capture.
        await system.engine.pause()
        let before = fake.captureCount
        _ = await system.engine.runCycle(force: true)
        XCTAssertEqual(fake.captureCount, before, "en pause, GHOST ne regarde pas l'écran")
        // Le journal d'accès ne contient aucune requête réseau.
        let log = await system.accessLog.all()
        XCTAssertFalse(log.contains { $0.operation == "network.request" })
    }
}

private actor CalendarReadGate {
    private var entered = false, open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; if !open { await withCheckedContinuation { waiter = $0 } } }
    func release() { open = true; waiter?.resume(); waiter = nil }
    func wait() async throws {
        for _ in 0..<200 { if entered { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CalendarError.storage("Le traitement de test n'a pas démarré.")
    }
}
final class CalendarSafetyAuditTests: XCTestCase {
    private func setup(ledger: URL? = nil) async -> (CalendarAgent, FakeCalendar, TrustEngine) {
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(CalendarAgent.sourceID, permission: .writeCalendar, scope: "agenda fictif")
        let writer = FakeCalendar()
        return (CalendarAgent(writer: writer, trust: trust, ledgerURL: ledger, calendar: visionCalendar, clock: { visionNow }), writer, trust)
    }
    func testRevocationWhileReadingAgendaPreventsCreation() async throws {
        let (agent, writer, trust) = await setup(), gate = CalendarReadGate()
        await writer.setEventsHook { await gate.hold() }
        let task = Task { await agent.consume([apptEvent(draft())]) }; try await gate.wait()
        await trust.revoke(CalendarAgent.sourceID); await gate.release(); await task.value
        let count = await writer.store.count
        XCTAssertEqual(count, 0)
    }
    func testPauseWhileReadingAgendaPreventsCreation() async throws {
        let (agent, writer, _) = await setup(), gate = CalendarReadGate()
        await writer.setEventsHook { await gate.hold() }
        let task = Task { await agent.consume([apptEvent(draft())]) }; try await gate.wait()
        await agent.setActive(false); await gate.release(); await task.value
        let count = await writer.store.count
        XCTAssertEqual(count, 0)
    }
    func testConcurrentAcceptCreatesOneEvent() async throws {
        let (agent, writer, _) = await setup(), gate = CalendarReadGate()
        await agent.consume([apptEvent(draft(certain: false))])
        let entries = try await agent.entries(), id = try XCTUnwrap(entries.first?.id)
        await writer.setEventsHook { await gate.hold() }
        let first = Task { try await agent.accept(id) }; try await gate.wait()
        try await agent.accept(id)
        await gate.release(); try await first.value
        let count = await writer.store.count
        XCTAssertEqual(count, 1)
    }
    func testPendingRecoveryCannotClaimAnUnmarkedUserEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), url = root.appendingPathComponent("calendar.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let (agent, writer, trust) = await setup(ledger: url)
        await agent.consume([apptEvent(draft(certain: false))])
        let entries = try await agent.entries(); var entry = try XCTUnwrap(entries.first)
        entry.status = .pending
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(CalendarLedger(entries: [entry.id: entry])).write(to: url)
        let userID = await writer.seed(entry.title, at: entry.start)
        let reopened = CalendarAgent(writer: writer, trust: trust, ledgerURL: url, clock: { visionNow })
        await reopened.recoverPending()
        let after = try await reopened.entries()
        XCTAssertEqual(after.first?.status, .suggested); XCTAssertNil(after.first?.eventIdentifier)
        do { try await reopened.undo(entry.id); XCTFail() } catch {}
        let stillThere = try await writer.fetch(userID)
        XCTAssertNotNil(stillThere)
    }
    func testUndoRefusesAnEventWhoseProvenanceWasRemoved() async throws {
        let (agent, writer, _) = await setup()
        await agent.consume([apptEvent(draft())])
        let entries = try await agent.entries(), entry = try XCTUnwrap(entries.first), id = try XCTUnwrap(entry.eventIdentifier)
        await writer.removeMarker(id)
        do { try await agent.undo(entry.id); XCTFail() } catch {}
        let preserved = try await writer.fetch(id)
        XCTAssertNotNil(preserved)
    }
}

extension CalendarSafetyAuditTests {
    func testLegacySuggestionGetsProvenanceBeforeItsFirstCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), url = root.appendingPathComponent("calendar.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let (agent, writer, trust) = await setup(ledger: url)
        await agent.consume([apptEvent(draft(certain: false))])
        let entries = try await agent.entries(); var entry = try XCTUnwrap(entries.first)
        entry.ownershipToken = nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(CalendarLedger(entries: [entry.id: entry])).write(to: url)
        let reopened = CalendarAgent(writer: writer, trust: trust, ledgerURL: url, clock: { visionNow })
        try await reopened.accept(entry.id)
        let added = try await reopened.entries()
        XCTAssertEqual(added.first?.status, .added); XCTAssertNotNil(added.first?.ownershipToken)
        try await reopened.undo(entry.id)
        let count = await writer.store.count
        XCTAssertEqual(count, 0)
    }
}
