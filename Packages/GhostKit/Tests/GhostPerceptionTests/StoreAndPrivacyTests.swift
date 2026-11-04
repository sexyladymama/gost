import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GhostPerception

/// Exigences 9 et 10 : stockage sans doublons, aucune transmission non autorisée.
final class StoreAndPrivacyTests: XCTestCase {

    private func sampleEvent(fingerprint: String, source: String = "gmail") -> GhostEvent {
        GhostEvent(fingerprint: fingerprint, kind: .information, tags: [], summary: "s",
                   source: EventSource(id: SourceID(source), kind: .email, displayName: source),
                   detectedAt: referenceDate, occurredAt: referenceDate, title: "t",
                   confidence: 0.5, evidence: [], isMissionCandidate: false)
    }

    // MARK: 9. Les événements sont enregistrés sans doublons.

    func testR09_storeRejectsDuplicateFingerprints() async throws {
        let store = FileEventStore.inMemory()
        let first = try await store.insert([sampleEvent(fingerprint: "gmail:1:1")])
        let again = try await store.insert([sampleEvent(fingerprint: "gmail:1:1"), sampleEvent(fingerprint: "gmail:2:1")])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(again.map(\.fingerprint), ["gmail:2:1"])
        let all = await store.all()
        XCTAssertEqual(all.count, 2)
    }

    func testR09_sameEmailDeliveredTwiceIsStoredOnce() async throws {
        let (engine, trust, store, _) = makeEngine()
        let message = email(id: "dup", subject: "Rapport", body: "Peux-tu envoyer le rapport ?")
        // Le fournisseur renvoie deux fois le même message (ex. reprise après erreur).
        let provider = ScriptedMailProvider([.success([message, message]), .success([message])])
        let source = EmailSource(provider: provider, trust: trust, stateStore: InMemorySourceStateStore(),
                                 startDate: referenceDate.addingTimeInterval(-60))
        await trust.grant(source.descriptor.id, permission: .readMail, scope: "moi@ghost.test")
        await engine.register(source)
        await engine.start()
        await engine.runCycle(force: true)
        await engine.runCycle(force: true)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        await engine.stop()
    }

    func testR09_noDuplicatesAcrossRestarts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let inserted = try await FileEventStore(fileURL: url).insert([sampleEvent(fingerprint: "gmail:1:1")])
        XCTAssertEqual(inserted.count, 1)

        let reopened = FileEventStore(fileURL: url) // nouvelle instance = redémarrage
        let again = try await reopened.insert([sampleEvent(fingerprint: "gmail:1:1")])
        XCTAssertTrue(again.isEmpty)
        let all = await reopened.all()
        XCTAssertEqual(all.count, 1)
    }

    func testR09_eventIdentifiersAreUniqueAndSchemaIsStable() throws {
        let a = sampleEvent(fingerprint: "a")
        let b = sampleEvent(fingerprint: "b")
        XCTAssertNotEqual(a.id, b.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try JSONSerialization.jsonObject(with: encoder.encode(a)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), [
            "id", "fingerprint", "schemaVersion", "kind", "tags", "summary", "source", "detectedAt", "occurredAt",
            "title", "people", "requiredInformation", "confidence", "evidence", "isMissionCandidate", "metadata"])
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        let decoded = try JSONDecoder().decode(GhostEvent.self, from: encoder.encode(a))
        XCTAssertEqual(decoded, a)
    }

    // MARK: 10. Les données ne sont pas transmises à un service non autorisé.

    func testR10_requestToUnauthorizedHostIsBlockedBeforeSending() async throws {
        let log = AccessLog()
        let trust = TrustEngine(accessLog: log)
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        let network = RecordingHTTPClient()
        let guarded = GuardedHTTPClient(base: network, rules: PerceptionSystem.egressRules, trust: trust)

        for url in ["https://analytics.example.com/collect", "https://gmail.googleapis.com.evil.example/x",
                    "http://gmail.googleapis.com/gmail/v1/users/me/messages"] {
            let request = HTTPRequest(method: "POST", url: URL(string: url)!, body: Data("données".utf8),
                                      purpose: PerceptionSystem.gmailSourceID)
            do {
                _ = try await guarded.send(request)
                XCTFail("\(url) aurait dû être bloqué")
            } catch let error as PerceptionError {
                guard case .egressDenied = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(network.recorded.isEmpty, "aucune requête ne doit atteindre le réseau")
        let denied = await log.all().filter { $0.operation == "network.request" && $0.outcome == .denied }
        XCTAssertEqual(denied.count, 3)
    }

    func testR10_allowedHostIsBlockedForUnauthorizedSourceOrPurpose() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        let network = RecordingHTTPClient()
        let guarded = GuardedHTTPClient(base: network, rules: PerceptionSystem.egressRules, trust: trust)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        // Pas d'autorisation readMail.
        await XCTAssertThrowsAsync(try await guarded.send(HTTPRequest(url: url, purpose: PerceptionSystem.gmailSourceID)))
        // La source dossier n'a aucune destination réseau.
        await trust.grant(PerceptionSystem.folderSourceID, permission: .watchFolder, scope: "/tmp")
        await XCTAssertThrowsAsync(try await guarded.send(HTTPRequest(url: url, purpose: PerceptionSystem.folderSourceID)))
        XCTAssertTrue(network.recorded.isEmpty)
    }

    func testR10_gmailProviderOnlyContactsGoogleAPIs() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        let network = RecordingHTTPClient(responder: GmailFixtures.responder)
        let provider = try await makeGmailProvider(http: network, trust: trust)
        _ = try await provider.accountAddress()
        _ = try await provider.fetchMessages(after: referenceDate.addingTimeInterval(-3_600))
        XCTAssertFalse(network.recorded.isEmpty)
        XCTAssertEqual(Set(network.recorded.compactMap(\.url.host)), [GmailMailProvider.apiHost])
        XCTAssertTrue(network.recorded.allSatisfy { $0.method == "GET" }, "aucune écriture vers Gmail")
    }

    func testR10_simulationAndFolderPerceptionMakeNoNetworkRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = RecordingHTTPClient()
        let system = PerceptionSystem(profile: GhostProfile(id: "net", baseDirectory: directory), persistent: false,
                                      baseHTTP: network)
        let folder = directory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await system.trust.grant(PerceptionSystem.folderSourceID, permission: .watchFolder, scope: folder.path)
        await system.trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "simulation")
        await system.engine.register(FolderSource(root: folder, trust: system.trust, stateStore: system.sourceState))
        await system.engine.register(EmailSource(provider: SimulatedMailProvider(deliveredPerFetch: 10), trust: system.trust,
                                                 stateStore: system.sourceState, startDate: Date().addingTimeInterval(-1)))
        await system.engine.start()
        await system.engine.runCycle(force: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.pdf"))
        let report = await system.engine.runCycle(force: true)
        let all = await system.store.all()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(all.count, SimulatedMailProvider.scenario().count + 1)
        XCTAssertTrue(network.recorded.isEmpty)
        await system.engine.stop()
    }

    // MARK: Suppression et séparation des données

    func testDeleteCollectedDataRemovesEventsAndSourceState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = PerceptionSystem(profile: GhostProfile(id: "del", baseDirectory: directory), baseHTTP: RecordingHTTPClient())
        await system.trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "simulation")
        await system.engine.register(EmailSource(provider: SimulatedMailProvider(deliveredPerFetch: 2), trust: system.trust,
                                                 stateStore: system.sourceState, startDate: Date().addingTimeInterval(-1)))
        await system.engine.start()
        await system.engine.runCycle(force: true)
        let before = await system.store.all()
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.profile.eventsURL.path))

        try await system.engine.deleteCollectedData()
        let after = await system.store.all()
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.profile.eventsURL.path))
        let reloaded = await FileEventStore(fileURL: system.profile.eventsURL).all()
        XCTAssertTrue(reloaded.isEmpty)
        await system.engine.stop()
    }

    func testProfilesDoNotShareData() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alice = GhostProfile(id: "alice", baseDirectory: directory)
        let bob = GhostProfile(id: "bob", baseDirectory: directory)
        XCTAssertNotEqual(alice.directory, bob.directory)
        _ = try await FileEventStore(fileURL: alice.eventsURL).insert([sampleEvent(fingerprint: "a")])
        let bobEvents = await FileEventStore(fileURL: bob.eventsURL).all()
        XCTAssertTrue(bobEvents.isEmpty)
        XCTAssertEqual(GhostProfile(id: "../evil", baseDirectory: directory).directory.lastPathComponent, "___evil")
    }

    func testAccessLogRecordsAccessesWithoutContentAndPersists() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.jsonl")
        let log = AccessLog(fileURL: url)
        let trust = TrustEngine(accessLog: log)
        await trust.grant(SourceID("gmail"), permission: .readMail, scope: "moi@ghost.test")
        let source = EmailSource(provider: SimulatedMailProvider(), trust: trust, stateStore: InMemorySourceStateStore(),
                                 startDate: Date())
        _ = try await source.poll()
        let records = await AccessLog(fileURL: url).all()
        XCTAssertEqual(records.map(\.operation), ["trust.grant", "mail.fetch"])
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("fichier Excel"), "le journal ne contient aucun contenu")
    }
}

/// Le client réseau réel refuse les redirections (contournement du filtre).
final class RedirectPolicyTests: XCTestCase {
    func testRedirectsAreRefused() {
        let blocker = RedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://gmail.googleapis.com/")!)
        let response = HTTPURLResponse(url: URL(string: "https://gmail.googleapis.com/")!, statusCode: 302,
                                       httpVersion: nil, headerFields: ["Location": "https://evil.example/"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://placeholder.example")!)
        blocker.urlSession(session, task: task, willPerformHTTPRedirection: response,
                           newRequest: URLRequest(url: URL(string: "https://evil.example/")!)) { followed = $0 }
        XCTAssertNil(followed)
        task.cancel()
    }
}
