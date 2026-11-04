import XCTest
@testable import GhostPerception

/// Exigences 1 à 4 : détection et compréhension des e-mails.
final class EmailPerceptionTests: XCTestCase {

    // MARK: 1. Un nouvel e-mail est correctement détecté.

    func testR01_newEmailIsDetected() async throws {
        let clock = TestClock()
        let (engine, trust, store, _) = makeEngine(clock: clock)
        let provider = ScriptedMailProvider([
            .success([email(id: "m1", subject: "Résultats du mois",
                            body: "Peux-tu me préparer un fichier Excel avec les résultats du mois pour demain matin ?")])
        ])
        let source = EmailSource(provider: provider, trust: trust, stateStore: InMemorySourceStateStore(),
                                 startDate: referenceDate.addingTimeInterval(-60))
        await trust.grant(source.descriptor.id, permission: .readMail, scope: "moi@ghost.test")
        await engine.register(source)
        await engine.start()

        let report = await engine.runCycle(force: true)

        XCTAssertEqual(report.newEvents.count, 1)
        let event = try XCTUnwrap(report.newEvents.first)
        XCTAssertEqual(event.title, "Résultats du mois")
        XCTAssertEqual(event.source.id, SourceID("gmail"))
        XCTAssertEqual(event.source.kind, .email)
        XCTAssertEqual(event.detectedAt, clock.now)
        XCTAssertEqual(event.fingerprint, "gmail:m1:1")
        let stored = await store.all()
        XCTAssertEqual(stored.map(\.id), [event.id])
        await engine.stop()
    }

    func testR01_emailsBeforeAuthorizationAreNotCollected() async throws {
        let (_, trust, _, _) = makeEngine()
        let provider = SimulatedMailProvider(clock: { referenceDate })
        let state = InMemorySourceStateStore()
        let source = EmailSource(provider: provider, trust: trust, stateStore: state, startDate: referenceDate)
        // Sans autorisation : refus, et le fournisseur n'est jamais interrogé.
        do {
            _ = try await source.poll()
            XCTFail("La collecte aurait dû être refusée")
        } catch let error as PerceptionError {
            XCTAssertEqual(error, .notAuthorized(source: SourceID("gmail"), resource: provider.displayName))
        }
        XCTAssertEqual(provider.remainingCount, SimulatedMailProvider.scenario().count)
    }

    func testR01_simulatedMailboxDeliversOneEmailPerPoll() async throws {
        let (_, trust, _, _) = makeEngine()
        let provider = SimulatedMailProvider(clock: { referenceDate })
        let source = EmailSource(provider: provider, trust: trust, stateStore: InMemorySourceStateStore(),
                                 startDate: referenceDate)
        await trust.grant(source.descriptor.id, permission: .readMail, scope: "simulation")
        let first = try await source.poll()
        let second = try await source.poll()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(source.descriptor.isSimulated)
        XCTAssertTrue(source.descriptor.displayName.contains("simulation"))
    }

    // MARK: 2. Une demande contenue dans un e-mail est identifiée.

    func testR02_requestInMissionExampleIsIdentified() throws {
        let event = interpret(email(
            subject: "Résultats du mois",
            body: """
            Bonjour,

            Peux-tu me préparer un fichier Excel avec les résultats du mois pour demain matin ?

            Merci beaucoup,
            Marie
            """))

        XCTAssertEqual(event.kind, .task)
        XCTAssertTrue(event.tags.isSuperset(of: [.request, .task, .deadline]))
        XCTAssertEqual(event.expectedAction, "Préparer un fichier Excel avec les résultats du mois")
        XCTAssertEqual(event.expectedOutput, "Fichier Excel")
        XCTAssertEqual(event.requiredInformation, ["Les résultats du mois"])
        XCTAssertTrue(event.isMissionCandidate)
        XCTAssertGreaterThanOrEqual(event.confidence, 0.8)
        XCTAssertEqual(event.people.first, Person(name: "Marie Dupont", email: "marie.dupont@acme.example", role: .sender))
        XCTAssertTrue(event.summary.hasPrefix("Marie Dupont demande : Préparer un fichier Excel"))
        let rules = Set(event.evidence.map(\.rule))
        XCTAssertTrue(rules.isSuperset(of: ["request.marker", "task.action-verb", "task.deliverable",
                                            "deadline.explicit", "mission.candidate"]))
        // Le corps complet n'est jamais stocké dans l'événement.
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Merci beaucoup"))
    }

    func testR02_directQuestionIsARequest() {
        let event = interpret(email(subject: "Point projet",
                                    body: "Est-ce que tu serais disponible jeudi à 14h pour faire un point sur le projet ?"))
        XCTAssertEqual(event.kind, .request)
        XCTAssertTrue(event.tags.contains(.deadline))
        XCTAssertEqual(event.deadline?.date, paris(2026, 11, 5, 14, 0))
        XCTAssertTrue(event.isMissionCandidate)
    }

    func testR02_englishRequestIsATask() {
        let event = interpret(email(from: "John Smith <john@client.example>", subject: "Q3 report",
                                    body: "Hi, could you send me the Q3 sales report by Friday? Thanks, John"))
        XCTAssertEqual(event.kind, .task)
        XCTAssertEqual(event.expectedOutput, "Rapport")
        XCTAssertEqual(event.expectedAction, "Send me the Q3 sales report")
        XCTAssertEqual(event.deadline?.date, paris(2026, 11, 6, 18, 0))
        XCTAssertTrue(event.isMissionCandidate)
    }

    func testR02_followUpIsDetected() {
        let event = interpret(email(from: "Paul Martin <paul@fournisseur.example>", subject: "Relance : contrat fournisseur",
                                    body: "Je me permets de revenir vers toi : as-tu pu relire le contrat ? J'en aurais besoin avant vendredi."))
        XCTAssertEqual(event.kind, .followUp)
        XCTAssertTrue(event.tags.contains(.request))
        XCTAssertEqual(event.deadline?.text, "avant vendredi")
        XCTAssertTrue(event.isMissionCandidate)
    }

    func testR02_requestWhereUserIsOnlyInCopyIsNotAMission() {
        let event = interpret(email(to: ["paul@acme.example"], cc: ["moi@ghost.test"], subject: "Budget",
                                    body: "Paul, peux-tu préparer le budget pour lundi ?"))
        XCTAssertTrue(event.tags.contains(.request))
        XCTAssertFalse(event.isMissionCandidate)
        XCTAssertTrue(event.evidence.contains { $0.rule == "recipient.copy" })
    }

    // MARK: 3. Une échéance est correctement extraite.

    func testR03_deadlineOfMissionExampleIsExtracted() throws {
        let event = interpret(email(subject: "Résultats du mois",
                                    body: "Peux-tu me préparer un fichier Excel avec les résultats du mois pour demain matin ?"))
        let deadline = try XCTUnwrap(event.deadline)
        XCTAssertEqual(deadline.text, "pour demain matin")
        XCTAssertEqual(deadline.date, paris(2026, 11, 5, 9, 0))
        XCTAssertEqual(deadline.precision, .partOfDay)
    }

    // MARK: 4. Un e-mail purement informatif n'est pas classé comme une mission.

    func testR04_newsletterIsInformationNotMission() {
        let event = interpret(email(from: "La Lettre Tech <newsletter@lettre-tech.example>",
                                    subject: "Les nouveautés de la semaine",
                                    body: "Découvrez notre sélection. Profitez de -20 % jusqu'au 30 novembre. Pour vous désabonner, cliquez ici.",
                                    isBulk: true))
        XCTAssertEqual(event.kind, .information)
        XCTAssertFalse(event.isMissionCandidate)
        XCTAssertNil(event.expectedAction)
    }

    func testR04_forYourInformationEmailIsNotAMission() {
        let event = interpret(email(from: "Thomas Leroy <thomas@acme.example>", subject: "Réunion d'équipe déplacée",
                                    body: "Pour info, la réunion d'équipe est déplacée à lundi 10h, même salle."))
        XCTAssertEqual(event.kind, .information)
        XCTAssertTrue(event.tags.contains(.deadline)) // l'horaire reste repéré
        XCTAssertEqual(event.deadline?.date, paris(2026, 11, 9, 10, 0))
        XCTAssertFalse(event.isMissionCandidate)
    }

    func testR04_automatedEmailWithPleaseIsNotAMission() {
        let event = interpret(email(from: "Service <no-reply@service.example>", subject: "Votre facture",
                                    body: "Please find your invoice. Could you check your account settings?"))
        XCTAssertEqual(event.kind, .information)
        XCTAssertFalse(event.isMissionCandidate)
    }

    func testR04_thankYouReplyIsConversation() {
        let event = interpret(email(from: "Sarah <sarah@partner.example>", subject: "Re: Déjeuner",
                                    body: "Merci pour hier, c'était un vrai plaisir !\n\nLe 3 nov. 2026 à 18:02, moi@ghost.test a écrit :\n> On se retrouve à 12h30 ?",
                                    isReply: true))
        XCTAssertEqual(event.kind, .conversation)
        XCTAssertFalse(event.isMissionCandidate)
    }

    func testR04_quotedRequestInReplyIsIgnored() {
        let event = interpret(email(subject: "Re: rapport",
                                    body: "Parfait, merci !\n> Peux-tu m'envoyer le rapport demain ?", isReply: true))
        XCTAssertEqual(event.kind, .conversation)
        XCTAssertFalse(event.isMissionCandidate)
    }

    func testFullSimulatedScenarioIsClassifiedAsExpected() async throws {
        let (engine, trust, _, _) = makeEngine()
        let provider = SimulatedMailProvider(deliveredPerFetch: 10, clock: { referenceDate })
        let source = EmailSource(provider: provider, trust: trust, stateStore: InMemorySourceStateStore(),
                                 startDate: referenceDate.addingTimeInterval(-1))
        await trust.grant(source.descriptor.id, permission: .readMail, scope: "simulation")
        await engine.register(source)
        await engine.start()
        let events = await engine.runCycle(force: true).newEvents
        let bySubject = Dictionary(uniqueKeysWithValues: events.map { ($0.title, $0) })
        XCTAssertEqual(bySubject["Résultats du mois"]?.kind, .task)
        XCTAssertEqual(bySubject["Les nouveautés de la semaine"]?.kind, .information)
        XCTAssertEqual(bySubject["Relance : contrat fournisseur"]?.kind, .followUp)
        XCTAssertEqual(bySubject["Point projet"]?.kind, .request)
        XCTAssertEqual(bySubject["Réunion d'équipe déplacée"]?.kind, .information)
        XCTAssertEqual(bySubject["Re: Déjeuner"]?.kind, .conversation)
        XCTAssertEqual(bySubject["Q3 report"]?.kind, .task)
        XCTAssertEqual(events.filter(\.isMissionCandidate).count, 4)
        XCTAssertTrue(events.allSatisfy { $0.source.isSimulated })
        await engine.stop()
    }
}
