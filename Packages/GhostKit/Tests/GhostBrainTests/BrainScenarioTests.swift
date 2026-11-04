import XCTest
@testable import GhostBrain
@testable import GhostContext
@testable import GhostPerception

/// Scénarios obligatoires de la Mission 004 (A à J) — modèle simulé, aucune API payante.
final class BrainScenarioTests: XCTestCase {

    // A — Demande explicite : mission créée automatiquement, objectif, échéance, ressources, plan concret.
    func testA_explicitRequestCreatesMission() async throws {
        let env = try await BrainEnv.make()
        // Un document pertinent est déjà connu du contexte (même contexte professionnel).
        try await env.brain.process([env.file("Résultats commerciaux octobre.xlsx", path: "Ventes/Résultats commerciaux octobre.xlsx")])
        let event = env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-a")
        XCTAssertTrue(event.isMissionCandidate, "Perception doit marquer la demande comme candidate")
        let records = try await env.brain.process([event])
        XCTAssertEqual(records.first?.kind, .createMission)

        let _v1 = try await env.missions()
        let mission = try XCTUnwrap(_v1.first)
        XCTAssertEqual(mission.goal.kind, .explicitRequest)
        XCTAssertEqual(mission.goal.deliverable, "Fichier Excel")
        XCTAssertTrue(brainCalendar.isDate(try XCTUnwrap(mission.deadline), inSameDayAs: parisDate(2026, 11, 5)), "demain matin → jeudi")
        XCTAssertFalse(mission.resources.isEmpty, "le document pertinent du contexte est retrouvé")
        XCTAssertEqual(mission.resources.first?.title, "Résultats commerciaux octobre.xlsx")
        XCTAssertEqual(mission.state, .proposed)
        XCTAssertGreaterThanOrEqual(mission.plan.steps.count, 5)
        XCTAssertTrue(mission.plan.steps.contains { $0.key == "build" && $0.title.contains("Fichier Excel") })
        XCTAssertEqual(mission.plan.steps.first?.state, .completed)
        XCTAssertTrue(mission.history.contains { $0.kind == "detected" })
        XCTAssertFalse(mission.priority.factors.isEmpty)
    }

    // B — Information sans action : aucune mission.
    func testB_informationCreatesNoMission() async throws {
        let env = try await BrainEnv.make()
        let event = env.mail(from: "Thomas Leroy <thomas.leroy@acme.example>", subject: "Réunion d'équipe déplacée",
                             body: "Pour info, la réunion d'équipe est déplacée à lundi 10h, même salle.")
        let records = try await env.brain.process([event])
        XCTAssertTrue([.ignore, .remember].contains(records.first?.kind))
        let _v2 = try await env.missions()
        XCTAssertTrue(_v2.isEmpty)
        XCTAssertFalse(records.first?.reasons.isEmpty ?? true)
    }

    // C — Demande ambiguë : pas de mission ferme ; surveillance et question de clarification.
    func testC_ambiguousRequestIsMonitoredNotCreated() async throws {
        let env = try await BrainEnv.make()
        let event = env.mail(subject: "Idée", body: "Il faudrait qu'on regarde ça prochainement.")
        let records = try await env.brain.process([event])
        XCTAssertEqual(records.first?.kind, .monitor)
        let _v3 = try await env.missions()
        XCTAssertTrue(_v3.isEmpty)
        let state = try await env.state()
        XCTAssertEqual(state.watches.count, 1)
        XCTAssertFalse(state.watches.values.first?.clarificationQuestion.isEmpty ?? true)
        XCTAssertTrue(records.first?.uncertainties.first?.contains("Je pense qu'une demande existe") ?? false)
        XCTAssertTrue(records.first?.alternatives.contains { $0.kind == .createMission } ?? false, "l'alternative écartée est conservée")
    }

    // D — Demande déjà traitée : la mission existante est actualisée, jamais dupliquée.
    func testD_similarEventDoesNotDuplicate() async throws {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-d")])
        // Relance dans le même fil.
        let reminder = env.mail(subject: "Re: Résultats du mois",
                                body: "Petit rappel : as-tu pu préparer le fichier Excel des résultats du mois ?", thread: "t-d")
        let records = try await env.brain.process([reminder])
        XCTAssertEqual(records.first?.kind, .updateMission)
        let _v4 = try await env.missions()
        XCTAssertEqual(_v4.count, 1)
        let _v5 = try await env.missions()
        let mission = try XCTUnwrap(_v5.first)
        XCTAssertEqual(mission.triggers.count, 2)
        XCTAssertTrue(mission.history.contains { $0.kind == "follow-up" })

        // Même contenu retransmis sans rien de nouveau : ignoré comme doublon.
        let copy = env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-d", id: "autre-id")
        let again = try await env.brain.process([copy])
        let _v6 = try await env.missions()
        XCTAssertEqual(_v6.count, 1)
        XCTAssertTrue([.ignore, .updateMission].contains(again.first?.kind))
    }

    // E — Nouvelle information : échéance modifiée → mission actualisée, priorité recalculée, historique conservé.
    func testE_deadlineChangeUpdatesAndKeepsHistory() async throws {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-e")])
        let _v7 = try await env.missions()
        let before = try XCTUnwrap(_v7.first)
        env.clock.advance(3600)
        let change = env.mail(subject: "Re: Résultats du mois",
                              body: "Peux-tu préparer le fichier Excel des résultats du mois pour lundi ? L'échéance est finalement décalée, merci.",
                              thread: "t-e")
        let records = try await env.brain.process([change])
        XCTAssertEqual(records.first?.kind, .updateMission)
        let _v8 = try await env.missions()
        let after = try XCTUnwrap(_v8.first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertNotEqual(after.deadline, before.deadline)
        XCTAssertEqual(after.deadlineClaims.count, 2)
        XCTAssertEqual(after.deadlineClaims.filter(\.superseded).count, 1, "l'ancienne assertion est conservée, marquée remplacée")
        XCTAssertGreaterThan(after.history.count, before.history.count)
        XCTAssertTrue(after.history.contains { $0.kind == "deadline" && $0.before != nil && $0.after != nil })
        XCTAssertLessThan(after.priority.score, before.priority.score, "échéance plus lointaine → score recalculé à la baisse")
        XCTAssertTrue(after.history.starts(with: before.history), "l'historique n'est jamais réécrit")
    }

    // F — Informations manquantes : mission bloquée, aucune prétention de pouvoir réaliser le travail.
    func testF_missingInformationBlocksMission() async throws {
        let env = try await BrainEnv.make()
        let event = env.mail(subject: "Chiffres", body: "Peux-tu préparer un fichier Excel avec les chiffres du trimestre pour vendredi ?", thread: "t-f")
        let records = try await env.brain.process([event])
        XCTAssertEqual(records.first?.kind, .createMission)
        let _v9 = try await env.missions()
        let m = try XCTUnwrap(_v9.first)
        XCTAssertEqual(m.state, .blocked)
        XCTAssertTrue(m.missingInfo.contains { $0.severity == .block && $0.text.contains("Données sources introuvables") })
        XCTAssertEqual(m.plan.steps.first { $0.key == "gather" }?.state, .blocked)
        XCTAssertTrue(m.beliefs.contains { $0.subject == "Ressources" && $0.level == .unknown })
        XCTAssertNotEqual(m.state, .ready)
        XCTAssertTrue(UncertaintyEngine.statement(missing: m.missingInfo, conflict: false, confidence: m.confidence).contains("il me manque"))

        // Livrable non précisé → clarification.
        let vague = env.mail(from: "Paul <paul@acme.example>", subject: "Dossier", body: "Peux-tu rédiger quelque chose pour demain ?", thread: "t-f2")
        let r2 = try await env.brain.process([vague])
        if r2.first?.kind == .clarify {
            let _v10 = try await env.missions()
            let c = try XCTUnwrap(_v10.first { $0.dedupeKey.hasSuffix("t-f2") })
            XCTAssertEqual(c.state, .needsClarification)
            XCTAssertNotNil(c.clarificationQuestion)
        }
    }

    // G — Contradiction : deux sources, deux échéances ; les deux sont conservées, aucune n'est inventée.
    func testG_contradictoryDeadlinesAreKept() async throws {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-g")])
        env.clock.advance(1800)
        let other = env.mail(from: "Julie Bernard <julie.bernard@acme.example>", subject: "Résultats du mois",
                             body: "Pour le fichier Excel des résultats du mois, il faudrait le préparer pour lundi, peux-tu le faire ?",
                             thread: "t-g")
        let records = try await env.brain.process([other])
        XCTAssertEqual(records.first?.kind, .updateMission)
        let _v11 = try await env.missions()
        let m = try XCTUnwrap(_v11.first)
        XCTAssertTrue(m.deadlineConflict)
        XCTAssertNil(m.deadline, "aucune échéance définitive n'est inventée")
        XCTAssertEqual(m.deadlineClaims.filter { !$0.superseded }.count, 2)
        XCTAssertEqual(m.state, .needsClarification)
        XCTAssertTrue(m.missingInfo.contains { $0.text.hasPrefix("Échéances contradictoires") })
        XCTAssertNotEqual(m.state, .ready)
        // L'utilisateur tranche : les autres assertions restent consultables.
        try await env.brain.resolveDeadline(m.id, to: parisDate(2026, 11, 9, 9))
        let _v12 = try await env.missions()
        let resolved = try XCTUnwrap(_v12.first)
        XCTAssertFalse(resolved.deadlineConflict)
        XCTAssertEqual(resolved.deadlineClaims.count, 3)
    }

    // H — Permissions insuffisantes : la lecture non autorisée est signalée, jamais contournée.
    func testH_missingPermissionIsReportedNotBypassed() async throws {
        let env = try await BrainEnv.make(grants: [(SourceID("gmail"), .readMail)])   // aucun dossier autorisé
        let event = env.mail(subject: "Rapport", body: "Peux-tu relire le rapport trimestriel avant vendredi ?", thread: "t-h")
        try await env.brain.process([event])
        let _v13 = try await env.missions()
        let m = try XCTUnwrap(_v13.first)
        XCTAssertTrue(m.permissions.contains { $0.capability == .read && $0.sourceID == "folder" && $0.status == .missing })
        XCTAssertEqual(m.state, .blocked)
        XCTAssertTrue(m.plan.steps.contains { $0.state == .blocked && ($0.blockedReason?.contains("Autorisation manquante") ?? false) })
        // Les écritures et envois ne sont jamais accordés automatiquement.
        XCTAssertTrue(m.permissions.filter { $0.capability != .read }.allSatisfy { $0.status == .approvalRequired })
        XCTAssertFalse(BrainTrust.executionAllowed(m))
        // L'utilisateur autorise ensuite le dossier : la réévaluation lève le blocage de permission.
        await env.trust.grant(SourceID("folder"), permission: .watchFolder, scope: "test")
        try await env.brain.reevaluate()
        let _v14 = try await env.missions()
        let after = try XCTUnwrap(_v14.first)
        XCTAssertFalse(after.permissions.contains { $0.status == .missing })
    }

    // I — Pause et arrêt : aucun traitement ; missions intactes ; la reprise ne duplique rien.
    func testI_pauseStopsProcessingAndResumeHasNoDuplicates() async throws {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-i")])
        let saved = try await env.state()
        await env.brain.setActive(false)
        let later = env.mail(from: "Paul <paul.martin@fournisseur.example>", subject: "Contrat",
                             body: "Peux-tu relire le contrat fournisseur avant vendredi ?", thread: "t-i2")
        await env.brain.consume([later])
        var paused = try await env.state()
        XCTAssertEqual(paused.missions.count, saved.missions.count, "aucun traitement en pause")
        XCTAssertEqual(paused.ledger.count, saved.ledger.count)
        let deferred = await env.brain.deferredCount
        XCTAssertEqual(deferred, 1)
        XCTAssertEqual(paused.missions.first?.value.history, saved.missions.first?.value.history, "missions intactes")

        await env.brain.setActive(true)
        await env.brain.catchUp([later])
        await env.brain.catchUp([later])   // rejouée deux fois
        paused = try await env.state()
        XCTAssertEqual(paused.missions.count, saved.missions.count + 1)
    }

    // J — Reprise après panne : un échec d'écriture ne laisse rien de partiel ; la reprise ne crée aucun doublon.
    func testJ_crashRecoveryNoDuplicateAndConsistentState() async throws {
        let store = MissionStore(url: nil)
        let env = try await BrainEnv.make(store: store)
        let event = env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-j")
        await store.setFailNextSaves(1)
        do { _ = try await env.brain.process([event]) } catch {}   // l'écriture échoue : « panne »
        var state = try await env.state()
        XCTAssertTrue(state.missions.isEmpty)
        XCTAssertTrue(state.ledger.isEmpty, "l'événement n'est pas marqué traité tant que la transaction n'a pas réussi")

        let records = try await env.brain.process([event])         // reprise
        XCTAssertEqual(records.first?.kind, .createMission)
        _ = try await env.brain.process([event])                    // rejouée : ignorée
        state = try await env.state()
        XCTAssertEqual(state.missions.count, 1)
        XCTAssertEqual(state.ledger.count, 1)
        let m = try XCTUnwrap(state.missions.values.first)
        XCTAssertTrue(MissionLifecycle.validate(m).isEmpty)
        XCTAssertEqual(m.history.first?.kind, "detected")
        // Identifiant déterministe : même sans registre, la même situation donne la même mission.
        XCTAssertEqual(m.id, BrainID.make("mission|" + m.dedupeKey))
    }
}
