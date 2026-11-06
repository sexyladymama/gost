import Foundation
import XCTest
import GhostPerception
import GhostContext
import GhostBrain
@testable import GhostAutonomy

private struct AutonomyFixture {
    let root: URL, input: URL, output: URL, profile: GhostProfile
    let brain: BrainEngine, engine: ExecutionEngine
    let missionID: String
    static func make(persistent: Bool = true) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-autonomy-\(UUID())").resolvingSymlinksInPath()
        let input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("produit,quantite,prix_unitaire\nStylo,3,2.50\nCahier,2,4.25\n".utf8).write(to: input.appendingPathComponent("ventes_nord.csv"))
        try Data("produit;quantite;prix_unitaire\nClasseur;4;3,10\n".utf8).write(to: input.appendingPathComponent("ventes_sud.csv"))
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(SourceID("folder"), permission: .watchFolder, scope: input.path)
        await trust.grant(SourceID("test-mail"), permission: .readMail, scope: "test")
        let profile = GhostProfile(id: "autonomy-test", baseDirectory: root)
        let context = ContextEngine(profile: profile, trust: trust, persistent: persistent)
        try await context.setScope(.professional, for: SourceID("folder"))
        try await context.setScope(.professional, for: SourceID("test-mail"))
        let brain = BrainEngine(profile: profile, context: context, trust: trust, persistent: persistent)
        let source = EventSource(id: SourceID("folder"), kind: .folder, displayName: "Dossier fictif autorisé")
        let fs = FileManager.default
        var events: [GhostEvent] = []
        for name in ["ventes_nord.csv", "ventes_sud.csv"] {
            let attributes = try fs.attributesOfItem(atPath: input.appendingPathComponent(name).path)
            let change = FileChange(kind: .created, relativePath: name,
                metadata: FileMetadata(name: name, fileExtension: "csv", category: .from(extension: "csv"),
                    size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, modifiedAt: Date(), createdAt: Date()))
            events.append(UnderstandingEngine().interpret(EventNormalizer().normalize(.file(change), from: source), detectedAt: Date()))
        }
        _ = try await brain.process(events)
        let message = EmailMessage(id: "fictitious-request", threadID: "fictitious-thread", from: "Direction <direction@example.test>",
            to: ["user@example.test"], subject: "Récapitulatif des ventes", date: Date(),
            bodyText: "Peux-tu préparer un fichier Excel récapitulatif avec les ventes disponibles ?")
        let mail = EventSource(id: SourceID("test-mail"), kind: .email, displayName: "Demande fictive hors réseau")
        let event = UnderstandingEngine().interpret(EventNormalizer().normalize(.email(message, account: "user@example.test"), from: mail), detectedAt: Date())
        _ = try await brain.process([event])
        let all = try await brain.snapshot()
        let mission = try XCTUnwrap(all.missions.values.first)
        try await brain.confirm(mission.id)
        let ready = try await brain.snapshot().missions[mission.id]
        XCTAssertEqual(ready?.state, .ready, "Le scénario doit démarrer depuis une vraie mission du Brain")
        let engine = ExecutionEngine(profile: profile, brain: brain, persistent: persistent)
        await engine.setGlobalPaused(false)
        return Self(root: root, input: input, output: output, profile: profile, brain: brain, engine: engine, missionID: mission.id)
    }
    func prepared(sensitive: Bool = false) async throws -> String {
        let id = try await engine.prepare(missionID: missionID, declaredSensitive: sensitive)
        try await engine.authorize(id, input: input, output: output, allowReadContents: true, allowCreate: true)
        return id
    }
    func run(_ id: String, using engine: ExecutionEngine? = nil) async throws -> ExecutionContext {
        let engine = engine ?? self.engine
        try await engine.start(id); await engine.waitForIdle(id)
        let value = try await engine.snapshot().executions[id]
        return try XCTUnwrap(value)
    }
}

private actor OperationGate {
    var entered = false, open = false
    var waiter: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; observer?.resume(); observer = nil; if !open { await withCheckedContinuation { waiter = $0 } } }
    func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { open = true; waiter?.resume(); waiter = nil }
}

final class AutonomyTests: XCTestCase {
    func testA_B_F_N_O_realSpreadsheetWorkflowAndBrainReport() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.prepared(), result = try await f.run(id)
        XCTAssertEqual(result.state, .completed, result.error ?? "")
        XCTAssertEqual(result.verification?.status, .passed)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalCents }, 2_840)
        XCTAssertEqual(result.operations.map(\.tool), [.listAuthorizedFiles, .readAuthorizedFile, .createSpreadsheet, .saveArtifact, .verifyArtifact, .notifyUser])
        XCTAssertTrue(result.operations.allSatisfy { $0.status == "completed" })
        let artifact = try XCTUnwrap(result.artifact)
        let bytes = try Data(contentsOf: f.output.appendingPathComponent(artifact.fileName))
        XCTAssertEqual(SpreadsheetEngine.verify(bytes, expected: result.records).status, .passed)
        XCTAssertNotNil(result.notification)
        let mission = try await f.brain.snapshot().missions[f.missionID]
        XCTAssertTrue(mission?.history.contains { $0.kind == "local-artifact:" + id } == true)
        XCTAssertNotEqual(mission?.state, .completed, "La remise externe du plan initial n'a pas été exécutée")
        // Export optionnel de la preuve fictive, uniquement pour le contrôle indépendant de cet essai.
        if let path = ProcessInfo.processInfo.environment["GHOST_AUTONOMY_TEST_EXPORT"] {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try bytes.write(to: destination.appendingPathComponent("ventes-verifiees.xlsx"))
        }
    }
    func testC_E_M_permissionsAndExternalActionsAreDenied() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.engine.prepare(missionID: f.missionID)
        do { try await f.engine.start(id); XCTFail() } catch {}
        let denied = await f.engine.trust.decision(executionID: id, namespace: "other", risk: .low)
        XCTAssertEqual(denied, .denied)
        try await f.engine.authorize(id, input: f.input, output: f.output, allowReadContents: true, allowCreate: true)
        let namespace = try await f.engine.snapshot().executions[id]?.mission.namespace
        let ns = try XCTUnwrap(namespace)
        let external = await f.engine.trust.decision(executionID: id, namespace: ns, risk: .external)
        XCTAssertEqual(external, .denied)
        await f.engine.trust.revoke(id)
        let result = try await f.run(id)
        XCTAssertEqual(result.state, .waitingForApproval)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    }
    func testD_sensitiveDataRequiresExplicitApproval() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.prepared(sensitive: true)
        let stopped = try await f.run(id)
        XCTAssertEqual(stopped.state, .waitingForApproval)
        XCTAssertEqual(stopped.approvalKind, "sensitive")
        try await f.engine.approve(id)
        let done = try await f.run(id)
        XCTAssertEqual(done.state, .completed, done.error ?? "")
    }
    func testG_H_invalidSpreadsheetAndInvalidSourcesNeverComplete() async throws {
        let bad = SpreadsheetEngine.verify(Data("not-xlsx".utf8), expected: [SalesRecord(product: "x", quantity: 1, unitCents: 100, source: "x.csv", sourceRow: 2)])
        XCTAssertEqual(bad.status, .failed)
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("produit,quantite,prix_unitaire\nX,abc,10\n".utf8).write(to: f.input.appendingPathComponent("ventes_nord.csv"))
        let id = try await f.prepared(), result = try await f.run(id)
        XCTAssertEqual(result.state, .failed)
        XCTAssertNil(result.notification)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    }
    func testI_J_P_recoveryAfterSaveDoesNotRewriteArtifact() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = OperationGate()
        await f.engine.setAfterTool { tool in if tool == .saveArtifact { await gate.hold() } }
        let id = try await f.prepared()
        try await f.engine.start(id); await gate.wait()
        try await f.engine.pause(id); await gate.release()
        let files = try FileManager.default.contentsOfDirectory(at: f.output, includingPropertiesForKeys: [.contentModificationDateKey])
        XCTAssertEqual(files.count, 1)
        let before = try files[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let recovered = ExecutionEngine(profile: f.profile, brain: f.brain)
        try await recovered.recover(); await recovered.setGlobalPaused(false)
        try await recovered.authorize(id, input: f.input, output: f.output, allowReadContents: true, allowCreate: true)
        let done = try await f.run(id, using: recovered)
        XCTAssertEqual(done.state, .completed, done.error ?? "")
        XCTAssertEqual(done.artifact?.recovered, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.output.path).count, 1)
        XCTAssertEqual(try files[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        XCTAssertFalse(done.history.isEmpty)
    }
    func testK_pauseThenResume() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = OperationGate()
        await f.engine.setAfterTool { tool in if tool == .readAuthorizedFile { await gate.hold() } }
        let id = try await f.prepared()
        try await f.engine.start(id); await gate.wait()
        try await f.engine.pause(id); await gate.release()
        let paused = try await f.engine.snapshot().executions[id]
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
        await f.engine.setAfterTool(nil)
        try await f.engine.authorize(id, input: f.input, output: f.output, allowReadContents: true, allowCreate: true)
        let done = try await f.run(id)
        XCTAssertEqual(done.state, .completed, done.error ?? "")
    }
    func testL_cancelStopsFollowingOperations() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = OperationGate()
        await f.engine.setAfterTool { tool in if tool == .readAuthorizedFile { await gate.hold() } }
        let id = try await f.prepared()
        try await f.engine.start(id); await gate.wait()
        try await f.engine.cancel(id); await gate.release()
        let stopped = try await f.engine.snapshot().executions[id]
        XCTAssertEqual(stopped?.state, .cancelled)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    }
    func testCollisionRequiresNewVersionApprovalWithoutOverwrite() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.prepared()
        let value = try await f.engine.snapshot().executions[id]
        let context = try XCTUnwrap(value)
        let original = Data("existing-user-file".utf8)
        let url = f.output.appendingPathComponent(context.outputName)
        try original.write(to: url)
        let waiting = try await f.run(id)
        XCTAssertEqual(waiting.state, .waitingForApproval)
        try await f.engine.approve(id)
        let done = try await f.run(id)
        XCTAssertEqual(done.state, .completed, done.error ?? "")
        XCTAssertEqual(done.outputVersion, 2)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testSymlinksTraversalAndDirectorySwapAreBlocked() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let trust = ExecutionTrust()
        try await trust.authorize(executionID: "job", namespace: "professional:real", input: f.input, output: f.output, allowContentRead: true, allowCreate: true)
        let outside = f.root.appendingPathComponent("secret.csv"); try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.input.appendingPathComponent("link.csv"), withDestinationURL: outside)
        do { _ = try await trust.perform("job", namespace: "professional:real") { try SecureFiles.read("link.csv", grant: $0) }; XCTFail() } catch {}
        do { _ = try await trust.perform("job", namespace: "professional:real") { try SecureFiles.read("../secret.csv", grant: $0) }; XCTFail() } catch {}
        try FileManager.default.moveItem(at: f.input, to: f.root.appendingPathComponent("old-input"))
        try FileManager.default.createDirectory(at: f.input, withIntermediateDirectories: false)
        do { _ = try await trust.perform("job", namespace: "professional:real") { try SecureFiles.list($0) }; XCTFail() } catch {}
    }
    func testSourceRevocationPurgesExecutionAndPreventsResume() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.prepared()
        try await f.engine.sourceWasRevoked(SourceID("test-mail"), retainHistory: false)
        let archive = try await f.engine.snapshot()
        XCTAssertNil(archive.executions[id])
        do { try await f.engine.start(id); XCTFail() } catch {}
    }
    func testStateMachineAndUnknownTools() {
        XCTAssertFalse(ExecutionState.pending.canMove(to: .completed))
        XCTAssertFalse(ExecutionState.failed.canMove(to: .completed))
        XCTAssertFalse(ExecutionState.cancelled.canMove(to: .running))
        XCTAssertTrue(ExecutionState.verifying.canMove(to: .completed))
        XCTAssertNil(ToolID(rawValue: "RunShell"))
        XCTAssertEqual(ToolCatalog.tools.count, 7)
    }
    func testCreateDocumentToolAndStrictArguments() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.prepared()
        let value = try await f.engine.snapshot().executions[id]
        let context = try XCTUnwrap(value)
        let tools = ToolEngine(trust: f.engine.trust)
        let doc = try await tools.execute(.createDocument, context: context, text: "Rapport fictif")
        XCTAssertEqual(doc.data, Data("Rapport fictif".utf8))
        do { _ = try await tools.execute(.listAuthorizedFiles, context: context, text: "extra"); XCTFail() } catch {}
    }

    // MARK: - Compléments d'audit (Mission 005)

    func testToolCatalogDeclaresRealSchemasPermissionsAndRisk() {
        XCTAssertEqual(Set(ToolCatalog.tools.map(\.id)), Set(ToolID.allCases), "un seul enregistrement par outil")
        XCTAssertEqual(Set(ToolCatalog.tools.map(\.description)).count, ToolCatalog.tools.count, "descriptions distinctes")
        for tool in ToolCatalog.tools {
            XCTAssertFalse(tool.description.isEmpty); XCTAssertFalse(tool.inputSchema.isEmpty); XCTAssertFalse(tool.outputSchema.isEmpty)
            XCTAssertEqual(tool.capability, .local, "aucun outil n'a besoin d'un exécuteur cloud")
            XCTAssertNotEqual(tool.risk, .external, "aucun outil à conséquence externe n'est enregistré")
        }
        XCTAssertEqual(ToolCatalog.definition(.saveArtifact).permissions, ["create_output"], "seule la sauvegarde crée un fichier")
        XCTAssertTrue(ToolCatalog.definition(.readAuthorizedFile).permissions.contains("read_content"))
        XCTAssertTrue(ToolCatalog.definition(.createSpreadsheet).permissions.isEmpty, "construire en mémoire n'exige aucun accès")
        for forbidden in ["RunShell", "SendEmail", "DeleteFile", "ShareDocument", "Purchase", "ReplaceFile"] {
            XCTAssertNil(ToolID(rawValue: forbidden), "\(forbidden) ne doit pas exister")
        }
    }

    func testCloudBackendIsPreparedButUnavailable() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        do { _ = try await f.engine.prepare(missionID: f.missionID, capability: .cloud); XCTFail("le cloud n'existe pas encore") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cloud"), error.localizedDescription) }
        XCTAssertTrue(LocalExecutionBackend().isAvailable)
        XCTAssertTrue(ToolID.allCases.allSatisfy(LocalExecutionBackend().supports))
        XCTAssertFalse(CloudExecutionBackend().isAvailable)
        XCTAssertFalse(ToolID.allCases.contains { CloudExecutionBackend().supports($0) })
        let archive = try await f.engine.snapshot()
        XCTAssertTrue(archive.executions.isEmpty, "aucune exécution cloud n'est créée, même partiellement")
        let id = try await f.engine.prepare(missionID: f.missionID)
        let context = try await f.engine.snapshot().executions[id]
        XCTAssertEqual(context?.capability, .local)
    }

    func testPauseDenialAndCancelAreReportedToBrainWithoutChangingItsState() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = OperationGate()
        await f.engine.setAfterTool { tool in if tool == .readAuthorizedFile { await gate.hold() } }
        let id = try await f.prepared()
        try await f.engine.start(id); await gate.wait()
        try await f.engine.pause(id); await gate.release()
        var mission = try await f.brain.snapshot().missions[f.missionID]
        XCTAssertTrue(mission?.history.contains { $0.kind == "execution-paused:" + id } ?? false)
        let summary = mission?.history.last { $0.kind == "execution-paused:" + id }?.summary ?? ""
        XCTAssertTrue(summary.contains("étape(s) restante(s)"), "le Brain reçoit les étapes restantes : \(summary)")
        XCTAssertTrue(summary.contains("ListAuthorizedFiles"), "…et les actions déjà effectuées : \(summary)")
        XCTAssertEqual(mission?.state, .ready, "seul le Brain décide de l'état d'une mission")

        // Permission révoquée : l'opération est refusée et le Brain en est informé.
        await f.engine.setAfterTool(nil)
        try await f.engine.authorize(id, input: f.input, output: f.output, allowReadContents: true, allowCreate: true)
        await f.engine.trust.revoke(id)
        try await f.engine.start(id); await f.engine.waitForIdle(id)
        mission = try await f.brain.snapshot().missions[f.missionID]
        XCTAssertTrue(mission?.history.contains { $0.kind == "execution-denied:" + id } ?? false)
        try await f.engine.cancel(id)
        mission = try await f.brain.snapshot().missions[f.missionID]
        XCTAssertTrue(mission?.history.contains { $0.kind == "execution-cancelled:" + id } ?? false)
        XCTAssertNotEqual(mission?.state, .completed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty, "rien n'a été écrit")
        // Le Brain refuse un événement mal formé et ne l'écrit pas.
        do { try await f.brain.recordExecutionEvent(missionID: f.missionID, executionID: id, kind: "completed", summary: "faux succès"); XCTFail() } catch {}
    }

    func testRedirectedParentSymlinkedFolderAndSandboxFriendlyCanonicalPath() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let fm = FileManager.default
        let parent = f.root.appendingPathComponent("parent")
        try fm.createDirectory(at: parent.appendingPathComponent("in"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appendingPathComponent("out"), withIntermediateDirectories: true)
        try Data("produit,quantite,prix_unitaire\nA,1,1.00\n".utf8).write(to: parent.appendingPathComponent("in/a.csv"))
        let trust = ExecutionTrust()
        try await trust.authorize(executionID: "job", namespace: "professional:real",
                                  input: parent.appendingPathComponent("in"), output: parent.appendingPathComponent("out"),
                                  allowContentRead: true, allowCreate: true)
        let names = try await trust.perform("job", namespace: "professional:real") { try SecureFiles.list($0) }
        XCTAssertEqual(names, ["a.csv"], "l'ouverture directe fonctionne sans parcourir les dossiers parents")
        // Un parent remplacé par un lien vers le MÊME dossier est refusé (le chemin réel ne correspond plus).
        try fm.moveItem(at: parent, to: f.root.appendingPathComponent("parent_old"))
        try fm.createSymbolicLink(at: parent, withDestinationURL: f.root.appendingPathComponent("parent_old"))
        do { _ = try await trust.perform("job", namespace: "professional:real") { try SecureFiles.list($0) }; XCTFail("parent redirigé") }
        catch { XCTAssertTrue(error.localizedDescription.contains("redirigé") || error.localizedDescription.contains("lien"), error.localizedDescription) }
        // Le dossier autorisé lui-même remplacé par un lien : refusé (O_NOFOLLOW).
        let solo = f.root.appendingPathComponent("solo"); try fm.createDirectory(at: solo.appendingPathComponent("in"), withIntermediateDirectories: true)
        try fm.createDirectory(at: solo.appendingPathComponent("out"), withIntermediateDirectories: true)
        try await trust.authorize(executionID: "job2", namespace: "professional:real", input: solo.appendingPathComponent("in"),
                                  output: solo.appendingPathComponent("out"), allowContentRead: true, allowCreate: true)
        try fm.removeItem(at: solo.appendingPathComponent("in"))
        try fm.createSymbolicLink(at: solo.appendingPathComponent("in"), withDestinationURL: f.input)
        do { _ = try await trust.perform("job2", namespace: "professional:real") { try SecureFiles.list($0) }; XCTFail("dossier remplacé par un lien") } catch {}
        // La canonicalisation passe par le descripteur (pas realpath) : /var/… devient /private/var/….
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghost-canon-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true); defer { try? fm.removeItem(at: tmp) }
        // (Foundation retire « /private » dans resolvingSymlinksInPath ; la référence est realpath, utilisable ici hors bac à sable.)
        let reference = realpath(tmp.path, nil).map { String(cString: $0) }
        XCTAssertEqual(try SecureFiles.canonical(tmp).path, reference)
        do { _ = try SecureFiles.canonical(URL(fileURLWithPath: "/nonexistent-\(UUID())")); XCTFail() } catch {}
    }
}

extension AutonomyTests {
    func testConcurrentPreparationCreatesOneStableExecution() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<24 { group.addTask { try await f.engine.prepare(missionID: f.missionID) } }
            var ids: [String] = []; for try await id in group { ids.append(id) }; return ids
        }
        XCTAssertEqual(Set(ids).count, 1)
        let archive = try await f.engine.snapshot()
        XCTAssertEqual(archive.executions.count, 1)
    }
    func testRepreparationCannotSilentlyDropSensitiveFlag() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.engine.prepare(missionID: f.missionID)
        let second = try await f.engine.prepare(missionID: f.missionID, declaredSensitive: true)
        XCTAssertEqual(first, second)
        try await f.engine.authorize(first, input: f.input, output: f.output, allowReadContents: true, allowCreate: true)
        let result = try await f.run(first)
        XCTAssertEqual(result.state, .waitingForApproval); XCTAssertEqual(result.approvalKind, "sensitive")
    }
    func testFailedExecutionCanBeCancelledAndReplacedAfterCorrection() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("produit,quantite,prix_unitaire\nX,abc,1\n".utf8).write(to: f.input.appendingPathComponent("ventes_nord.csv"))
        let id = try await f.prepared(), failed = try await f.run(id)
        XCTAssertEqual(failed.state, .failed)
        try await f.engine.cancel(id)
        let next = try await f.engine.prepare(missionID: f.missionID)
        XCTAssertNotEqual(next, id)
    }
    func testTamperingOnDiskCannotProduceSuccessNotification() async throws {
        let f = try await AutonomyFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.prepared(), gate = OperationGate()
        await f.engine.setAfterTool { tool in if tool == .saveArtifact { await gate.hold() } }
        try await f.engine.start(id); await gate.wait()
        let files = try FileManager.default.contentsOfDirectory(at: f.output, includingPropertiesForKeys: nil)
        try Data("not an Excel file".utf8).write(to: XCTUnwrap(files.first))
        await gate.release(); await f.engine.waitForIdle(id)
        let result = try await f.engine.snapshot().executions[id]
        XCTAssertEqual(result?.state, .failed); XCTAssertEqual(result?.verification?.status, .failed); XCTAssertNil(result?.notification)
    }
}
