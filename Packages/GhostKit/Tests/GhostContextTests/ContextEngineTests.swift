import XCTest
@testable import GhostContext
import GhostPerception

/// Exigences de la Mission 003 — GHOST CONTEXT (préfixes `testC01_` à `testC12_`).
final class ContextEngineTests: XCTestCase {

    // C01 — Un événement produit des entités liées, avec preuves.
    func testC01_eventBuildsLinkedEntitiesWithProvenance() async throws {
        let (engine, _) = try await makeContext()
        let event = makeMailEvent(title: "[Projet : Atlas] Budget", deadline: ctxReference.addingTimeInterval(86_400))
        try await engine.ingest([event])
        let graph = try await engine.snapshot()

        XCTAssertEqual(graph.nodes(of: .event).count, 1)
        XCTAssertEqual(graph.nodes(of: .person).count, 1)
        XCTAssertEqual(graph.nodes(of: .conversation).count, 1)
        XCTAssertEqual(graph.nodes(of: .project).map(\.title), ["Atlas"])
        XCTAssertEqual(graph.nodes(of: .taskCandidate).count, 1)
        XCTAssertEqual(graph.nodes(of: .deadline).count, 1)
        XCTAssertFalse(graph.relations(of: .taskHasDeadline).isEmpty)
        XCTAssertFalse(graph.relations(of: .eventRelatesToProject).isEmpty)
        for node in graph.nodes.values { XCTAssertFalse(node.provenance.isEmpty, "\(node.kind) sans preuve") }
        for edge in graph.relations.values { XCTAssertFalse(edge.provenance.isEmpty) }
    }

    // C02 — Un projet inféré reste une hypothèse ; un fait observé est confirmé.
    func testC02_inferenceIsNeverPromotedToFact() async throws {
        let (engine, _) = try await makeContext()
        for index in 0..<5 {
            try await engine.ingest([makeMailEvent(fingerprint: "f\(index)", title: "[Projet: Atlas] Point \(index)")])
        }
        let graph = try await engine.snapshot()
        XCTAssertEqual(graph.nodes(of: .project).first?.status, .hypothesis)
        XCTAssertEqual(graph.nodes(of: .event).first?.status, .confirmed)
        XCTAssertTrue(graph.relations(of: .eventRelatesToProject).allSatisfy { $0.status == .hypothesis })
    }

    // C03 — Un même événement rejoué ne crée aucun doublon.
    func testC03_replayIsIdempotent() async throws {
        let (engine, _) = try await makeContext()
        let event = makeMailEvent(title: "[Projet: Atlas] Budget")
        try await engine.ingest([event])
        let first = try await engine.snapshot()
        try await engine.ingest([event, event])
        let second = try await engine.snapshot()
        XCTAssertEqual(first.nodes.count, second.nodes.count)
        XCTAssertEqual(first.relations.count, second.relations.count)
    }

    // C04 — Cloisonnement : personnel et professionnel ne se mélangent jamais.
    func testC04_personalAndProfessionalNeverLink() async throws {
        let (engine, _) = try await makeContext()
        try await engine.setScope(.personal, for: SourceID("gmail"))
        try await engine.setScope(.professional, for: SourceID("folder"))
        try await engine.ingest([
            makeMailEvent(fingerprint: "m1", title: "[Projet: Atlas] Budget"),
            makeFileEvent(name: "Atlas budget.xlsx", path: "Atlas/budget.xlsx")
        ])
        let graph = try await engine.snapshot()
        for edge in graph.relations.values {
            XCTAssertEqual(graph.nodes[edge.from]?.namespace, graph.nodes[edge.to]?.namespace)
        }
        let namespaces = Set(graph.nodes.values.map(\.namespace))
        XCTAssertTrue(namespaces.contains { $0.hasPrefix("personal") })
        XCTAssertTrue(namespaces.contains { $0.hasPrefix("professional") })
        // Deux projets homonymes mais dans deux contextes : deux entités distinctes.
        try await engine.ingest([makeFileEvent(name: "[Projet: Atlas].txt", path: "[Projet: Atlas]/a.txt")])
        let after = try await engine.snapshot()
        XCTAssertEqual(Set(after.nodes(of: .project).map(\.namespace)).count, after.nodes(of: .project).count)
    }

    // C05 — Une source non classée reste isolée dans sa propre frontière.
    func testC05_unclassifiedSourcesAreIsolatedPerSource() async throws {
        let (engine, _) = try await makeContext()
        try await engine.ingest([makeMailEvent(fingerprint: "m1"), makeFileEvent(name: "a.txt", path: "a.txt")])
        let graph = try await engine.snapshot()
        let namespaces = Set(graph.nodes.values.map(\.namespace))
        XCTAssertTrue(namespaces.contains("unclassified:gmail:simulation"))
        XCTAssertTrue(namespaces.contains("unclassified:folder:real"))
        XCTAssertTrue(graph.nodes.values.allSatisfy { $0.scope == .unclassified })
    }

    // C06 — Les données simulées ne se mélangent pas aux données réelles.
    func testC06_simulatedAndRealAreSeparated() async throws {
        let (engine, _) = try await makeContext()
        try await engine.ingest([makeMailEvent(fingerprint: "sim", source: mailSource),
                                 makeMailEvent(fingerprint: "real", source: realMailSource)])
        let graph = try await engine.snapshot()
        XCTAssertEqual(graph.nodes(of: .person).count, 2)
        XCTAssertEqual(Set(graph.nodes.values.map(\.isSimulated)), [true, false])
    }

    // C07 — Sans autorisation, rien n'entre dans la mémoire.
    func testC07_noGrantMeansNoMemory() async throws {
        let (engine, trust) = try await makeContext()
        await trust.revoke(SourceID("gmail"))
        do {
            try await engine.ingest([makeMailEvent()])
            XCTFail("L'ingestion aurait dû être refusée")
        } catch {}
        let graph = try await engine.snapshot()
        XCTAssertTrue(graph.nodes.isEmpty)
    }

    // C08 — La révocation supprime la mémoire dérivée, sauf choix explicite de conservation.
    func testC08_revocationDeletesOrRetains() async throws {
        let (engine, _) = try await makeContext()
        try await engine.ingest([makeMailEvent(fingerprint: "m1"), makeFileEvent(name: "a.txt", path: "a.txt")])
        try await engine.sourceWasRevoked(SourceID("gmail"), retainHistory: false)
        var graph = try await engine.snapshot()
        XCTAssertTrue(graph.nodes.values.allSatisfy { !$0.provenance.contains { $0.sourceID == SourceID("gmail") } })
        XCTAssertFalse(graph.nodes.isEmpty, "La mémoire de l'autre source est préservée")

        try await engine.sourceWasRevoked(SourceID("folder"), retainHistory: true)
        graph = try await engine.snapshot()
        XCTAssertFalse(graph.nodes(of: .document).isEmpty)
        XCTAssertTrue(graph.retainedSources.contains("folder"))
    }

    // C09 — Après panne, une source révoquée n'a plus de mémoire (sauf conservation choisie).
    func testC09_reconcilePermissionsRemovesRevokedMemory() async throws {
        let (engine, trust) = try await makeContext()
        try await engine.ingest([makeMailEvent(fingerprint: "m1")])
        await trust.revoke(SourceID("gmail"))
        try await engine.reconcilePermissions()
        let graph = try await engine.snapshot()
        XCTAssertTrue(graph.nodes.isEmpty)
    }

    // C10 — Les corrections de l'utilisateur gagnent sur l'inférence et survivent aux rejeux.
    func testC10_userCorrectionsSurviveReplay() async throws {
        let (engine, _) = try await makeContext()
        let event = makeMailEvent(title: "[Projet: Atlas] Budget")
        try await engine.ingest([event])
        let project = try await engine.snapshot().nodes(of: .project)[0]
        try await engine.correctNode(project.id, title: "Atlas Europe", status: .confirmed)
        try await engine.ingest([makeMailEvent(fingerprint: "other", title: "[Projet: Atlas] Suite", detectedAt: ctxReference.addingTimeInterval(60))])
        let graph = try await engine.snapshot()
        let corrected = try XCTUnwrap(graph.nodes[project.id])
        XCTAssertEqual(corrected.title, "Atlas Europe")
        XCTAssertEqual(corrected.status, .confirmed)
        XCTAssertTrue(corrected.provenance.contains { $0.isUserProvided })

        // Rejet d'une relation : elle ne revient jamais.
        let relation = try XCTUnwrap(graph.relations(of: .eventRelatesToProject).first)
        try await engine.rejectRelation(relation.id)
        try await engine.ingest([event, makeMailEvent(fingerprint: "third", title: "[Projet: Atlas] Encore")])
        let final = try await engine.snapshot()
        XCTAssertNil(final.relations[relation.id])
    }

    // C11 — Échéances contradictoires : conservées et signalées, jamais écrasées.
    func testC11_contradictoryDeadlinesAreKeptAndFlagged() async throws {
        let (engine, _) = try await makeContext()
        let t0 = ctxReference
        try await engine.ingest([
            makeMailEvent(fingerprint: "a", title: "[Projet: Atlas] Budget", deadline: t0.addingTimeInterval(86_400), detectedAt: t0),
            makeMailEvent(fingerprint: "b", title: "[Projet: Atlas] Budget", deadline: t0.addingTimeInterval(3 * 86_400), detectedAt: t0.addingTimeInterval(60),
                          occurredAt: t0.addingTimeInterval(60))
        ])
        let graph = try await engine.snapshot()
        XCTAssertEqual(graph.nodes(of: .deadline).count, 2)
        let project = try XCTUnwrap(graph.nodes(of: .project).first)
        let summary = try XCTUnwrap(ContextRetrieval.summary(projectID: project.id, graph: graph))
        XCTAssertFalse(summary.ambiguities.isEmpty)
        XCTAssertEqual(summary.latestDeadline?.occurredAt, t0.addingTimeInterval(3 * 86_400), "La plus récente assertion prévaut")
    }

    // C12 — Le résumé d'un projet indique ce qui manque au lieu d'inventer.
    func testC12_summaryReportsMissingInformation() async throws {
        let (engine, _) = try await makeContext()
        try await engine.ingest([makeMailEvent(title: "[Projet: Atlas] Budget", output: nil)])
        let graph = try await engine.snapshot()
        let project = try XCTUnwrap(graph.nodes(of: .project).first)
        let summary = try XCTUnwrap(ContextRetrieval.summary(projectID: project.id, graph: graph))
        XCTAssertTrue(summary.missingInformation.contains { $0.contains("Échéance inconnue") })
        XCTAssertTrue(summary.missingInformation.contains { $0.contains("Périmètre") })
        XCTAssertTrue(summary.missingInformation.contains { $0.contains("document") })
        XCTAssertNil(summary.latestDeadline)
    }

    // Un fichier dont le chemin nomme un seul projet est rattaché ; plusieurs projets : ambiguïté.
    func testDocumentLinkingAndAmbiguity() async throws {
        let (engine, _) = try await makeContext()
        try await engine.setScope(.professional, for: SourceID("gmail"))
        try await engine.setScope(.professional, for: SourceID("folder"))
        try await engine.ingest([
            makeMailEvent(fingerprint: "a", source: realMailSource, title: "[Projet: Atlas] Budget"),
            makeFileEvent(name: "budget.xlsx", path: "Atlas/budget.xlsx")
        ])
        var graph = try await engine.snapshot()
        XCTAssertFalse(graph.relations(of: .documentBelongsToProject).isEmpty)

        let (second, _) = try await makeContext()
        try await second.setScope(.professional, for: SourceID("gmail"))
        try await second.setScope(.professional, for: SourceID("folder"))
        try await second.ingest([
            makeMailEvent(fingerprint: "a", source: realMailSource, title: "[Projet: Atlas] A"),
            makeMailEvent(fingerprint: "b", source: realMailSource, title: "[Projet: Bis] B"),
            makeFileEvent(name: "x.txt", path: "Bis/Atlas/x.txt")
        ])
        graph = try await second.snapshot()
        XCTAssertTrue(graph.nodes(of: .document).contains { $0.properties["ambiguity"] != nil })
        XCTAssertTrue(graph.relations(of: .documentBelongsToProject).isEmpty)
    }

    // Recherche locale et suppression complète.
    func testSearchAndDeleteMemory() async throws {
        let (engine, _) = try await makeContext()
        try await engine.ingest([makeMailEvent(title: "Contrat Dupont")])
        let found = try await engine.search("contrat")
        XCTAssertFalse(found.isEmpty)
        let none = try await engine.search("inexistant")
        XCTAssertTrue(none.isEmpty)
        try await engine.deleteMemory()
        let graph = try await engine.snapshot()
        XCTAssertTrue(graph.nodes.isEmpty)
        let afterDelete = try await engine.search("contrat")
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // Mémoire manuelle : exige un contexte explicite.
    func testManualMemoryRequiresScope() async throws {
        let (engine, _) = try await makeContext()
        do { _ = try await engine.remember(kind: .preference, text: "Réponses courtes", scope: .unclassified); XCTFail() } catch {}
        do { _ = try await engine.remember(kind: .event, text: "x", scope: .personal); XCTFail() } catch {}
        let id = try await engine.remember(kind: .preference, text: "Réponses courtes", scope: .professional)
        let graph = try await engine.snapshot()
        XCTAssertEqual(graph.nodes[id]?.status, .confirmed)
        XCTAssertEqual(graph.nodes[id]?.domain, .identity)
    }

    // Persistance entre deux lancements.
    func testPersistenceAcrossRestart() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (first, _) = try await makeContext(persistent: dir)
        try await first.ingest([makeMailEvent(title: "[Projet: Atlas] Budget")])
        let before = try await first.snapshot()

        let (second, _) = try await makeContext(persistent: dir)
        let after = try await second.snapshot()
        XCTAssertEqual(before.nodes.count, after.nodes.count)
        XCTAssertEqual(before.relations.count, after.relations.count)
        XCTAssertEqual(before.salt, after.salt)
    }

    // Une base illisible n'est jamais effacée ni réinitialisée.
    func testCorruptDatabaseIsPreserved() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = GhostProfile(id: "test-profile", baseDirectory: dir)
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        let file = profile.directory.appendingPathComponent("context.sqlite")
        let garbage = Data("ceci n'est pas une base sqlite".utf8)
        try garbage.write(to: file)

        let (engine, _) = try await makeContext(persistent: dir)
        do { _ = try await engine.snapshot(); XCTFail("L'ouverture aurait dû échouer") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), garbage)
    }

    // Une base d'un autre profil est refusée.
    func testDatabaseOwnedByAnotherProfileIsRejected() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trust = TrustEngine(accessLog: AccessLog())
        let one = ContextEngine(profile: GhostProfile(id: "alice", baseDirectory: dir), trust: trust)
        _ = try await one.snapshot()
        let path = GhostProfile(id: "alice", baseDirectory: dir).directory.appendingPathComponent("context.sqlite")
        // Un autre profil pointant sur le même fichier.
        let other = ContextEngine(profile: GhostProfile(id: "bob", baseDirectory: dir), trust: trust)
        let bobPath = GhostProfile(id: "bob", baseDirectory: dir).directory.appendingPathComponent("context.sqlite")
        try FileManager.default.createDirectory(at: bobPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: path, to: bobPath)
        do { _ = try await other.snapshot(); XCTFail() } catch {}
    }
}


final class ContextAuditRegressionTests: XCTestCase {
    func testSecondDocumentWithSameNameRetractsAutomaticReference() async throws {
        let (engine, _) = try await makeContext()
        try await engine.setScope(.professional, for: mailSource.id)
        try await engine.setScope(.professional, for: folderSource.id)
        let real = makeMailEvent(source: realMailSource, title: "Lire rapport.xlsx", summary: "Voir rapport.xlsx", action: "Lire rapport.xlsx")
        try await engine.ingest([makeFileEvent(name: "rapport.xlsx", path: "A/rapport.xlsx"), real])
        let before = try await engine.snapshot()
        let eventID = try XCTUnwrap(before.nodes(of: .event).first { $0.properties["eventID"] == real.id.uuidString }?.id)
        XCTAssertEqual(before.relations(of: .eventReferencesDocument).filter { $0.from == eventID }.count, 1)
        try await engine.ingest([makeFileEvent(name: "rapport.xlsx", path: "B/rapport.xlsx")])
        let after = try await engine.snapshot()
        XCTAssertTrue(after.relations(of: .eventReferencesDocument).filter { $0.from == eventID }.isEmpty,
                      "Une référence devenue ambiguë ne doit plus désigner automatiquement le premier document")
        XCTAssertNotNil(after.nodes[eventID]?.properties["ambiguity"])
    }
}

final class ContextConfirmationAuditTests: XCTestCase {
    func testExplicitDocumentConfirmationSurvivesNewHomonym() async throws {
        let (engine, _) = try await makeContext()
        try await engine.setScope(.professional, for: mailSource.id)
        try await engine.setScope(.professional, for: folderSource.id)
        let mail = makeMailEvent(source: realMailSource, title: "Lire rapport.xlsx", summary: "Voir rapport.xlsx", action: "Lire rapport.xlsx")
        try await engine.ingest([makeFileEvent(name: "rapport.xlsx", path: "A/rapport.xlsx"), mail])
        let before = try await engine.snapshot()
        let event = try XCTUnwrap(before.nodes(of: .event).first { $0.properties["eventID"] == mail.id.uuidString })
        let edge = try XCTUnwrap(before.relations(of: .eventReferencesDocument).first { $0.from == event.id })
        try await engine.confirmRelation(edge.id)
        try await engine.ingest([makeFileEvent(name: "rapport.xlsx", path: "B/rapport.xlsx")])
        let after = try await engine.snapshot()
        XCTAssertEqual(after.relations[edge.id]?.status, .confirmed)
        XCTAssertEqual(after.relations[edge.id]?.userCorrected, true)
    }
}
