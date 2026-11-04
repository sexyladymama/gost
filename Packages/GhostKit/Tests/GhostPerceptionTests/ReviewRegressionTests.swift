import XCTest
@testable import GhostPerception

private final class FailingCheckpointStore: SourceStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var failNextSave = true
    private let base = InMemorySourceStateStore()
    func load(_ key: String) throws -> Data? { try base.load(key) }
    func save(_ data: Data, for key: String) throws {
        let shouldFail = lock.withLock {
            let result = failNextSave
            failNextSave = false
            return result
        }
        if shouldFail { throw PerceptionError.storageFailed("panne de test du curseur") }
        try base.save(data, for: key)
    }
    func remove(_ key: String) throws { try base.remove(key) }
    func removeAll() throws { try base.removeAll() }
}

/// Régressions de stockage et reprise après panne (Mission 002.1).
final class ReviewRegressionTests: XCTestCase {
    func testFailedSaveCanBeRetriedWithoutLosingEvent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("blocked")
        try Data("obstruction".utf8).write(to: parent)
        let url = parent.appendingPathComponent("events.json")
        let store = FileEventStore(fileURL: url)
        let event = interpret(email(id: "disk-failure", subject: "Rapport", body: "Peux-tu préparer le rapport ?"))
        do {
            _ = try await store.insert([event])
            XCTFail("La première sauvegarde doit échouer")
        } catch {}

        // Répare uniquement le dossier temporaire du test, puis réessaie.
        try FileManager.default.removeItem(at: parent)
        let inserted = try await store.insert([event])
        XCTAssertEqual(inserted.count, 1, "L'événement non sauvegardé doit pouvoir être réessayé")
        let reopened = try await FileEventStore(fileURL: url).all()
        XCTAssertEqual(reopened.count, 1, "L'événement doit survivre au redémarrage après réparation")
    }

    func testCorruptExistingStoreIsNotSilentlyOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let original = Data("donnees-existantes-non-decodables".utf8)
        try original.write(to: url)
        let store = FileEventStore(fileURL: url)
        let event = interpret(email(id: "corrupt-store", subject: "Rapport", body: "Peux-tu préparer le rapport ?"))
        do {
            _ = try await store.insert([event])
            XCTFail("Une erreur de lecture doit empêcher l'écrasement silencieux")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original, "Le fichier existant doit être préservé")
    }

    func testCorruptStoreReadReportsErrorAndCanRecoverAfterRepair() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        try Data("invalid-json".utf8).write(to: url)
        let store = FileEventStore(fileURL: url)
        await XCTAssertThrowsAsync(try await store.all())
        try Data("[]".utf8).write(to: url, options: .atomic)
        let recovered = try await store.all()
        XCTAssertTrue(recovered.isEmpty)
    }

    func testFailedDeletionPreservesMemoryAndDataOnDisk() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("events")
        let backup = directory.appendingPathComponent("backup")
        let url = parent.appendingPathComponent("events.json")
        let store = FileEventStore(fileURL: url)
        let event = interpret(email(id: "delete", subject: "Rapport", body: "Peux-tu préparer le rapport ?"))
        _ = try await store.insert([event])
        try FileManager.default.moveItem(at: parent, to: backup)
        try Data("obstruction".utf8).write(to: parent)
        await XCTAssertThrowsAsync(try await store.delete(source: event.source.id))
        let remaining = try await store.all()
        XCTAssertEqual(remaining, [event])
        let disk = try await FileEventStore(fileURL: backup.appendingPathComponent("events.json")).all()
        XCTAssertEqual(disk, [event])
    }

    func testEmailBatchIsRetriedAfterFailedEventSave() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("obstruction".utf8).write(to: blocked)
        let store = FileEventStore(fileURL: blocked.appendingPathComponent("events.json"))
        let trust = TrustEngine(accessLog: AccessLog())
        let engine = PerceptionEngine(trust: trust, store: store, tick: nil)
        let message = email(id: "retry", subject: "Rapport", body: "Peux-tu préparer le rapport ?")
        let provider = ScriptedMailProvider([.success([message])])
        let stateStore = InMemorySourceStateStore()
        let source = EmailSource(provider: provider, trust: trust, stateStore: stateStore,
                                 startDate: referenceDate.addingTimeInterval(-60))
        await trust.grant(source.descriptor.id, permission: .readMail, scope: "simulation")
        await engine.register(source)
        await engine.start()
        let failed = await engine.runCycle(force: true)
        XCTAssertEqual(failed.issues.count, 1)
        XCTAssertNil(try stateStore.load("email.gmail.simulation"))

        try FileManager.default.removeItem(at: blocked)
        let retried = await engine.runCycle(force: true)
        XCTAssertTrue(retried.issues.isEmpty)
        XCTAssertEqual(retried.newEvents.count, 1)
        XCTAssertEqual(provider.fetches, 1, "La réponse déjà collectée doit être rejouée")
        let saved = try await FileEventStore(fileURL: blocked.appendingPathComponent("events.json")).all()
        XCTAssertEqual(saved.count, 1)
        XCTAssertNotNil(try stateStore.load("email.gmail.simulation"))
        await engine.stop()
    }

    func testEmailCursorDoesNotAdvanceAcrossRestartBeforeAcknowledgement() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let states = FileSourceStateStore(directory: directory)
        let trust = TrustEngine(accessLog: AccessLog())
        let message = email(id: "restart", subject: "Rapport", body: "Peux-tu préparer le rapport ?")
        let provider = ScriptedMailProvider([.success([message]), .success([message])])
        await trust.grant(SourceID("gmail"), permission: .readMail, scope: "simulation")
        let source = EmailSource(provider: provider, trust: trust, stateStore: states,
                                 startDate: referenceDate.addingTimeInterval(-60))
        let collected = try await source.collect()
        XCTAssertEqual(collected.count, 1)
        XCTAssertNil(try states.load("email.gmail.simulation"))
        let restarted = EmailSource(provider: provider, trust: trust, stateStore: states,
                                    startDate: referenceDate.addingTimeInterval(-60))
        let replayed = try await restarted.collect()
        XCTAssertEqual(replayed.count, 1)
        try await restarted.acknowledge()
        XCTAssertNotNil(try states.load("email.gmail.simulation"))
    }

    func testCheckpointFailureAfterEventSaveRetriesWithoutDuplicateOrLostNotification() async throws {
        let store = FileEventStore.inMemory()
        let trust = TrustEngine(accessLog: AccessLog())
        let states = FailingCheckpointStore()
        let engine = PerceptionEngine(trust: trust, store: store, tick: nil)
        let message = email(id: "checkpoint", subject: "Rapport", body: "Peux-tu préparer le rapport ?")
        let provider = ScriptedMailProvider([.success([message])])
        let source = EmailSource(provider: provider, trust: trust, stateStore: states,
                                 startDate: referenceDate.addingTimeInterval(-60))
        await trust.grant(source.descriptor.id, permission: .readMail, scope: "simulation")
        await engine.register(source)
        await engine.start()
        let first = await engine.runCycle(force: true)
        XCTAssertEqual(first.issues.count, 1)
        XCTAssertEqual(first.newEvents.count, 1, "L'événement sauvegardé reste publié malgré l'échec du curseur")
        XCTAssertNil(try states.load("email.gmail.simulation"))
        let retry = await engine.runCycle(force: true)
        XCTAssertTrue(retry.issues.isEmpty)
        XCTAssertTrue(retry.newEvents.isEmpty)
        XCTAssertEqual(provider.fetches, 1)
        let saved = try await store.all()
        XCTAssertEqual(saved.count, 1)
        let status = await engine.statuses().first
        XCTAssertEqual(status?.detectedCount, 1)
        XCTAssertNotNil(try states.load("email.gmail.simulation"))
        await engine.stop()
    }

    func testCorruptEmailCursorIsPreservedUntilExplicitReset() async throws {
        let states = InMemorySourceStateStore()
        let key = "email.gmail.simulation"
        let invalid = Data("invalid-json".utf8)
        try states.save(invalid, for: key)
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(SourceID("gmail"), permission: .readMail, scope: "simulation")
        let provider = ScriptedMailProvider([])
        let source = EmailSource(provider: provider, trust: trust, stateStore: states,
                                 startDate: referenceDate.addingTimeInterval(-60))
        await XCTAssertThrowsAsync(try await source.collect())
        XCTAssertEqual(try states.load(key), invalid)
        XCTAssertEqual(provider.fetches, 0)
        try await source.resetState() // action explicite d'effacement de l'utilisateur
        let collected = try await source.poll()
        XCTAssertTrue(collected.isEmpty)
        XCTAssertEqual(provider.fetches, 1)
        XCTAssertNotEqual(try states.load(key), invalid)
    }

    func testFolderChangeSurvivesFailedEventSaveAndRestart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked")
        let states = FileSourceStateStore(directory: directory.appendingPathComponent("states"))
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(SourceID("folder"), permission: .watchFolder, scope: folder.path)
        let store = FileEventStore(fileURL: blocked.appendingPathComponent("events.json"))
        let engine = PerceptionEngine(trust: trust, store: store, tick: nil)
        await engine.register(FolderSource(root: folder, trust: trust, stateStore: states))
        await engine.start()
        let baseline = await engine.runCycle(force: true) // établit la référence, aucun événement
        XCTAssertTrue(baseline.issues.isEmpty)
        try Data("obstruction".utf8).write(to: blocked)
        try Data("test".utf8).write(to: folder.appendingPathComponent("rapport.txt"))
        let failed = await engine.runCycle(force: true)
        XCTAssertEqual(failed.issues.count, 1)
        try FileManager.default.removeItem(at: blocked)
        // Une nouvelle instance recharge la référence antérieure à l'échec.
        await engine.register(FolderSource(root: folder, trust: trust, stateStore: states))
        let recovered = await engine.runCycle(force: true)
        XCTAssertTrue(recovered.issues.isEmpty)
        XCTAssertEqual(recovered.newEvents.count, 1)
        let saved = try await FileEventStore(fileURL: blocked.appendingPathComponent("events.json")).all()
        XCTAssertEqual(saved.count, 1)
        let again = await engine.runCycle(force: true)
        XCTAssertTrue(again.newEvents.isEmpty)
        await engine.stop()
    }

    @MainActor
    func testStartupStorageErrorReachesInterfaceWithoutOverwritingData() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = GhostProfile(id: "corrupt", baseDirectory: directory)
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        let original = Data("invalid-json".utf8)
        try original.write(to: profile.eventsURL)
        let system = PerceptionSystem(profile: profile, baseHTTP: RecordingHTTPClient(), tick: nil)
        let center = system.makeCenter()
        let surfaced = await eventually { !center.issues.isEmpty }
        XCTAssertTrue(surfaced)
        XCTAssertTrue(center.issues.first?.message.contains("conservé") ?? false)
        XCTAssertEqual(try Data(contentsOf: profile.eventsURL), original)
    }

    func testDeletionAlsoClearsCheckpointsOfRevokedSources() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = GhostProfile(id: "revoked-deletion", baseDirectory: directory)
        let system = PerceptionSystem(profile: profile, baseHTTP: RecordingHTTPClient(), tick: nil)
        let source = EmailSource(provider: SimulatedMailProvider(), trust: system.trust,
                                 stateStore: system.sourceState, startDate: Date().addingTimeInterval(-1))
        await system.trust.grant(source.descriptor.id, permission: .readMail, scope: "simulation")
        await system.engine.register(source)
        await system.engine.start()
        let collected = await system.engine.runCycle(force: true)
        XCTAssertFalse(collected.newEvents.isEmpty)
        await system.engine.revoke(source.descriptor.id)
        XCTAssertNotNil(try system.sourceState.load("email.gmail.simulation"))
        try await system.engine.deleteCollectedData()
        XCTAssertNil(try system.sourceState.load("email.gmail.simulation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.sourceStateDirectory.path))
        let reloaded = try await FileEventStore(fileURL: profile.eventsURL).all()
        XCTAssertTrue(reloaded.isEmpty)
        let authorized = await system.trust.isAuthorized(source.descriptor.id, .readMail)
        XCTAssertFalse(authorized)
        await system.engine.stop()
    }
}
