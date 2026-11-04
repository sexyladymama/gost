import XCTest
import GhostKit
@testable import GhostPerception

/// Exigences 7 et 8 : pause réelle et gestion des erreurs.
final class EngineTests: XCTestCase {

    private func authorizedCountingSource(_ id: String, trust: TrustEngine, interval: TimeInterval = 0,
                                          failures: [PerceptionError] = []) async -> CountingSource {
        let source = CountingSource(id: id, interval: interval, failures: failures)
        await trust.grant(source.descriptor.id, permission: .readMail, scope: id)
        return source
    }

    // MARK: 7. La mise en pause arrête réellement la perception.

    func testR07_pausedEngineDoesNotPollAnySource() async {
        let (engine, trust, _, _) = makeEngine()
        let source = await authorizedCountingSource("a", trust: trust)
        await engine.register(source)
        await engine.start()
        await engine.runCycle(force: true)
        let pollsBeforePause = await source.polls
        XCTAssertGreaterThanOrEqual(pollsBeforePause, 1)

        await engine.pause()
        let report = await engine.runCycle(force: true)
        XCTAssertTrue(report.skipped)
        // Même la collecte forcée (« Actualiser ») est sans effet en pause.
        let pollsAfterPause = await source.polls
        XCTAssertEqual(pollsAfterPause, pollsBeforePause)
        await engine.stop()
    }

    func testR07_backgroundLoopStopsWhilePausedAndRestartsOnResume() async {
        let (engine, trust, _, _) = makeEngine(tick: 0.02)
        let source = await authorizedCountingSource("a", trust: trust)
        await engine.register(source)
        await engine.start()
        let started = await eventually { await source.polls >= 3 }
        XCTAssertTrue(started, "la boucle de collecte doit tourner en état ACTIVE")

        await engine.pause() // attend la fin du cycle en cours
        let frozen = await source.polls
        try? await Task.sleep(nanoseconds: 300_000_000) // ≈ 15 ticks
        let stillFrozen = await source.polls
        XCTAssertEqual(stillFrozen, frozen, "aucune collecte ne doit avoir lieu en pause")

        await engine.resume()
        let resumed = await eventually { await source.polls > frozen }
        XCTAssertTrue(resumed)
        await engine.stop()
    }

    func testR07_stoppedEngineDoesNotPoll() async {
        let (engine, trust, _, _) = makeEngine(tick: 0.02)
        let source = await authorizedCountingSource("a", trust: trust)
        await engine.register(source)
        // Jamais démarré.
        let report = await engine.runCycle(force: true)
        XCTAssertTrue(report.skipped)
        await engine.start()
        _ = await eventually { await source.polls >= 1 }
        await engine.stop()
        let afterStop = await source.polls
        try? await Task.sleep(nanoseconds: 200_000_000)
        let later = await source.polls
        XCTAssertEqual(afterStop, later)
    }

    @MainActor
    func testR07_ghostStateManagerPauseReallyPausesPerception() async throws {
        let system = PerceptionSystem(profile: GhostProfile(id: "pause", baseDirectory: try makeTemporaryDirectory()),
                                      persistent: false, baseHTTP: RecordingHTTPClient(), tick: 0.02)
        let center = system.makeCenter()
        let manager = GhostStateManager(core: center)
        let source = await authorizedCountingSource("a", trust: system.trust)
        await center.register(source)

        try manager.start()
        let running = await eventually { await source.polls >= 2 }
        XCTAssertTrue(running)
        let engineRunning = await system.engine.state
        XCTAssertEqual(engineRunning, .running)

        try manager.togglePause()
        XCTAssertEqual(manager.state, .paused)
        let paused = await eventually { await system.engine.state == .paused }
        XCTAssertTrue(paused)
        await system.engine.pause() // idempotent ; garantit qu'aucun cycle n'est en cours
        let frozen = await source.polls
        try? await Task.sleep(nanoseconds: 250_000_000)
        let stillFrozen = await source.polls
        XCTAssertEqual(stillFrozen, frozen)
        let uiState = await eventually { center.engineState == .paused }
        XCTAssertTrue(uiState, "l'interface doit refléter la pause")

        try manager.togglePause()
        let resumed = await eventually { await source.polls > frozen }
        XCTAssertTrue(resumed)

        manager.stop()
        let stopped = await eventually { await system.engine.state == .stopped }
        XCTAssertTrue(stopped)
    }

    func testDisabledSourceIsNotPolled() async {
        let (engine, trust, _, _) = makeEngine()
        let a = await authorizedCountingSource("a", trust: trust)
        let b = await authorizedCountingSource("b", trust: trust)
        await engine.register(a)
        await engine.register(b)
        await engine.setEnabled(SourceID("b"), false)
        await engine.start()
        let report = await engine.runCycle(force: true)
        XCTAssertEqual(report.polled, [SourceID("a")])
        let bPolls = await b.polls
        XCTAssertEqual(bPolls, 0)
        await engine.stop()
    }

    func testRevokedSourceIsRemovedAndExternalAccessRevoked() async {
        let (engine, trust, _, _) = makeEngine()
        let source = await authorizedCountingSource("a", trust: trust)
        await engine.register(source)
        await engine.revoke(SourceID("a"))
        let revoked = await source.revoked
        let authorized = await trust.isAuthorized(SourceID("a"), .readMail)
        let statuses = await engine.statuses()
        XCTAssertTrue(revoked)
        XCTAssertFalse(authorized)
        XCTAssertTrue(statuses.isEmpty)
    }

    // MARK: 8. Une erreur de connexion est correctement gérée.

    func testR08_connectionErrorIsReportedWithoutStoppingPerception() async {
        let clock = TestClock()
        let (engine, trust, _, _) = makeEngine(clock: clock)
        let failing = await authorizedCountingSource("failing", trust: trust, interval: 10,
                                                     failures: [.connectionFailed("réseau injoignable")])
        let healthy = await authorizedCountingSource("healthy", trust: trust)
        await engine.register(failing)
        await engine.register(healthy)
        await engine.start()

        let report = await engine.runCycle()
        XCTAssertEqual(report.polled, [SourceID("failing"), SourceID("healthy")], "les autres sources continuent")
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(report.issues.first?.kind, .connection)
        XCTAssertTrue(report.issues.first?.message.contains("réseau injoignable") ?? false)
        let state = await engine.state
        XCTAssertEqual(state, .running)

        var status = await engine.statuses().first { $0.id == SourceID("failing") }
        XCTAssertEqual(status?.health, .error)
        XCTAssertEqual(status?.consecutiveFailures, 1)

        // Attente exponentielle : pas de nouvel essai avant 2 × l'intervalle.
        clock.advance(15)
        let tooEarly = await engine.runCycle()
        XCTAssertFalse(tooEarly.polled.contains(SourceID("failing")))
        clock.advance(10)
        let retry = await engine.runCycle()
        XCTAssertTrue(retry.polled.contains(SourceID("failing")))
        status = await engine.statuses().first { $0.id == SourceID("failing") }
        XCTAssertEqual(status?.health, .ok, "l'erreur est effacée après un succès")
        await engine.stop()
    }

    func testR08_issuesArePublishedToTheInterface() async {
        let (engine, trust, _, _) = makeEngine()
        let failing = await authorizedCountingSource("failing", trust: trust, failures: [.authenticationFailed("jeton refusé")])
        await engine.register(failing)
        await engine.start()
        var iterator = engine.updates.makeAsyncIterator()
        await engine.runCycle(force: true)
        var received: PerceptionIssue?
        while let update = await iterator.next() {
            if case .issue(let issue) = update { received = issue; break }
        }
        XCTAssertEqual(received?.kind, .authorization)
        await engine.stop()
    }

    func testR08_gmailServerErrorsAreMappedToConnectionErrors() async throws {
        let log = AccessLog()
        let trust = TrustEngine(accessLog: log)
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        for (status, expected) in [(500, PerceptionError.connectionFailed("API Gmail (HTTP 500)")),
                                   (429, PerceptionError.rateLimited)] {
            let recorder = RecordingHTTPClient { _ in HTTPResponse(status: status, body: Data()) }
            let provider = try await makeGmailProvider(http: recorder, trust: trust)
            do {
                _ = try await provider.fetchMessages(after: referenceDate)
                XCTFail("erreur attendue")
            } catch let error as PerceptionError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testR08_networkFailureIsAConnectionError() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        let recorder = RecordingHTTPClient { _ in throw PerceptionError.connectionFailed("The Internet connection appears to be offline.") }
        let provider = try await makeGmailProvider(http: recorder, trust: trust)
        do {
            _ = try await provider.fetchMessages(after: referenceDate)
            XCTFail("erreur attendue")
        } catch let error as PerceptionError {
            guard case .connectionFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testR08_missingOAuthTokenRequiresReconnection() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        let guarded = GuardedHTTPClient(base: RecordingHTTPClient(), rules: PerceptionSystem.egressRules, trust: trust)
        let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com", http: guarded,
                                       purpose: PerceptionSystem.gmailSourceID)
        let provider = GmailMailProvider(http: guarded, tokens: OAuthTokenProvider(client: client, store: InMemorySecretStore()),
                                         purpose: PerceptionSystem.gmailSourceID)
        do {
            _ = try await provider.fetchMessages(after: referenceDate)
            XCTFail("erreur attendue")
        } catch let error as PerceptionError {
            XCTAssertEqual(error, .authorizationRequired(source: PerceptionSystem.gmailSourceID))
        }
    }
}

/// Fournisseur Gmail relié à un client HTTP enregistreur, avec un jeton valide.
func makeGmailProvider(http: HTTPClient, trust: TrustEngine, clock: TestClock = TestClock()) async throws -> GmailMailProvider {
    let guarded = GuardedHTTPClient(base: http, rules: PerceptionSystem.egressRules, trust: trust)
    let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com", http: guarded,
                                   purpose: PerceptionSystem.gmailSourceID, clock: clock.function)
    let tokens = OAuthTokenProvider(client: client, store: InMemorySecretStore(), clock: clock.function)
    try await tokens.save(OAuthToken(accessToken: "access-1", refreshToken: "refresh-1",
                                     expiresAt: clock.now.addingTimeInterval(3_600), scope: GoogleOAuthClient.gmailReadOnlyScope))
    return GmailMailProvider(http: guarded, tokens: tokens, purpose: PerceptionSystem.gmailSourceID)
}
