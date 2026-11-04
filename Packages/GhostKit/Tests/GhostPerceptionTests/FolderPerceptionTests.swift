import XCTest
@testable import GhostPerception

/// Exigences 5 et 6 : dossier autorisé.
final class FolderPerceptionTests: XCTestCase {
    private var root: URL!
    private var authorized: URL!
    private var forbidden: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory()
        authorized = root.appendingPathComponent("Autorisé", isDirectory: true)
        forbidden = root.appendingPathComponent("Interdit", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: forbidden, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: forbidden.appendingPathComponent("secret.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(root: URL, trust: TrustEngine, fileSystem: FileSystemReader = LocalFileSystem()) -> FolderSource {
        FolderSource(root: root, trust: trust, stateStore: InMemorySourceStateStore(), fileSystem: fileSystem)
    }

    // MARK: 5. Un nouveau fichier dans le dossier autorisé est détecté.

    func testR05_newFileInAuthorizedFolderIsDetected() async throws {
        let (engine, trust, _, _) = makeEngine()
        let source = makeSource(root: authorized, trust: trust)
        await trust.grant(source.descriptor.id, permission: .watchFolder, scope: authorized.path)
        await engine.register(source)
        await engine.start()

        try Data("déjà là".utf8).write(to: authorized.appendingPathComponent("existant.txt"))
        let baseline = await engine.runCycle(force: true)
        XCTAssertTrue(baseline.newEvents.isEmpty, "Le premier parcours établit une référence")

        try Data(repeating: 1, count: 2_048).write(to: authorized.appendingPathComponent("Résultats novembre.xlsx"))
        let report = await engine.runCycle(force: true)

        let event = try XCTUnwrap(report.newEvents.first)
        XCTAssertEqual(report.newEvents.count, 1)
        XCTAssertEqual(event.kind, .documentEvent)
        XCTAssertEqual(event.title, "Résultats novembre.xlsx")
        XCTAssertEqual(event.metadata["category"], FileCategory.spreadsheet.rawValue)
        XCTAssertEqual(event.metadata["extension"], "xlsx")
        XCTAssertEqual(event.metadata["size"], "2048")
        XCTAssertEqual(event.metadata["change"], "created")
        XCTAssertFalse(event.isMissionCandidate)
        XCTAssertTrue(event.summary.hasPrefix("Nouveau fichier : Résultats novembre.xlsx (Tableur"))
        await engine.stop()
    }

    func testR05_modificationAndDeletionAreDetected() async throws {
        let (_, trust, _, _) = makeEngine()
        let source = makeSource(root: authorized, trust: trust)
        await trust.grant(source.descriptor.id, permission: .watchFolder, scope: authorized.path)
        let file = authorized.appendingPathComponent("notes.md")
        try Data("v1".utf8).write(to: file)
        _ = try await source.poll()

        try Data("version 2, plus longue".utf8).write(to: file)
        let modified = try await source.poll()
        guard case .file(let change)? = modified.first else { return XCTFail("modification non détectée") }
        XCTAssertEqual(change.kind, .modified)
        XCTAssertEqual(change.metadata.category, .text)

        try FileManager.default.removeItem(at: file)
        let deleted = try await source.poll()
        guard case .file(let removal)? = deleted.first else { return XCTFail("suppression non détectée") }
        XCTAssertEqual(removal.kind, .deleted)

        let nothing = try await source.poll()
        XCTAssertTrue(nothing.isEmpty)
    }

    func testR05_subfoldersAreScannedAndHiddenOrTemporaryFilesIgnored() async throws {
        let (_, trust, _, _) = makeEngine()
        let source = makeSource(root: authorized, trust: trust)
        await trust.grant(source.descriptor.id, permission: .watchFolder, scope: authorized.path)
        _ = try await source.poll()
        let sub = authorized.appendingPathComponent("Clients/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("devis.pdf"))
        try Data("x".utf8).write(to: authorized.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: authorized.appendingPathComponent("~$devis.docx"))
        try Data("x".utf8).write(to: authorized.appendingPathComponent("download.crdownload"))

        let changes = try await source.poll().compactMap { obs -> FileChange? in
            if case .file(let change) = obs { return change }
            return nil
        }
        XCTAssertEqual(changes.map(\.relativePath), ["Clients/2026/devis.pdf"])
        XCTAssertEqual(changes.first?.metadata.category, .pdf)
    }

    // MARK: 6. Un dossier non autorisé n'est jamais inspecté.

    func testR06_unauthorizedFolderIsNeverInspected() async throws {
        let (_, trust, _, log) = makeEngine()
        let spy = SpyFileSystem()
        // Autorisation accordée pour « Autorisé », source pointée sur « Interdit ».
        await trust.grant(SourceID("folder"), permission: .watchFolder, scope: authorized.path)
        let source = makeSource(root: forbidden, trust: trust, fileSystem: spy)

        do {
            _ = try await source.poll()
            XCTFail("L'accès aurait dû être refusé")
        } catch let error as PerceptionError {
            guard case .notAuthorized = error else { return XCTFail("erreur inattendue \(error)") }
        }
        XCTAssertTrue(spy.visitedPaths.isEmpty, "Aucun chemin ne doit avoir été consulté : \(spy.visitedPaths)")
        let denied = await log.all().filter { $0.outcome == .denied }
        XCTAssertEqual(denied.count, 1)
        XCTAssertEqual(denied.first?.operation, "folder.scan")
    }

    func testR06_folderWithoutAnyGrantIsNeverInspected() async throws {
        let (_, trust, _, _) = makeEngine()
        let spy = SpyFileSystem()
        let source = makeSource(root: authorized, trust: trust, fileSystem: spy)
        await XCTAssertThrowsAsync(try await source.poll())
        XCTAssertTrue(spy.visitedPaths.isEmpty)
    }

    func testR06_symbolicLinkToUnauthorizedFolderIsNotFollowed() async throws {
        let (_, trust, _, _) = makeEngine()
        let spy = SpyFileSystem()
        try FileManager.default.createSymbolicLink(at: authorized.appendingPathComponent("raccourci"),
                                                   withDestinationURL: forbidden)
        let source = makeSource(root: authorized, trust: trust, fileSystem: spy)
        await trust.grant(source.descriptor.id, permission: .watchFolder, scope: authorized.path)
        _ = try await source.poll()
        try Data("x".utf8).write(to: forbidden.appendingPathComponent("autre.txt"))
        let changes = try await source.poll()

        XCTAssertTrue(changes.isEmpty)
        let forbiddenPath = forbidden.resolvingSymlinksInPath().path
        XCTAssertFalse(spy.visitedPaths.contains { $0.hasPrefix(forbiddenPath) && $0 != forbiddenPath },
                       "Le contenu du dossier interdit a été consulté : \(spy.visitedPaths)")
        XCTAssertFalse(spy.visitedPaths.contains { $0.contains("secret.txt") || $0.contains("autre.txt") })
    }

    func testR06_siblingFolderWithSharedPrefixIsNotAuthorized() async throws {
        // « /Autorisé » ne doit pas autoriser « /Autorisé-bis ».
        let (_, trust, _, _) = makeEngine()
        let sibling = root.appendingPathComponent("Autorisé-bis", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        await trust.grant(SourceID("folder"), permission: .watchFolder, scope: authorized.path)
        let allowedInside = await trust.isInsideAuthorizedFolder(authorized.appendingPathComponent("a/b"), for: SourceID("folder"))
        let allowedSibling = await trust.isInsideAuthorizedFolder(sibling, for: SourceID("folder"))
        let allowedParent = await trust.isInsideAuthorizedFolder(root, for: SourceID("folder"))
        XCTAssertTrue(allowedInside)
        XCTAssertFalse(allowedSibling)
        XCTAssertFalse(allowedParent)
    }

    func testR06_revokedFolderIsNoLongerInspected() async throws {
        let (_, trust, _, _) = makeEngine()
        let spy = SpyFileSystem()
        let source = makeSource(root: authorized, trust: trust, fileSystem: spy)
        await trust.grant(source.descriptor.id, permission: .watchFolder, scope: authorized.path)
        _ = try await source.poll()
        let visitsBefore = spy.visitedPaths.count
        await trust.revoke(source.descriptor.id)
        await XCTAssertThrowsAsync(try await source.poll())
        XCTAssertEqual(spy.visitedPaths.count, visitsBefore)
    }

    func testFolderSourceNeverWritesToTheFolder() async throws {
        let (_, trust, _, _) = makeEngine()
        let file = authorized.appendingPathComponent("contrat.docx")
        try Data("original".utf8).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let source = makeSource(root: authorized, trust: trust)
        await trust.grant(source.descriptor.id, permission: .watchFolder, scope: authorized.path)
        for _ in 0..<3 { _ = try await source.poll() }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: authorized.path), ["contrat.docx"])
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T,
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Une erreur était attendue", file: file, line: line)
    } catch {}
}
