import XCTest
@testable import GhostBrain
@testable import GhostContext
@testable import GhostPerception

// MARK: - Priorité, plans, incertitude, Trust

final class BrainEngineUnitTests: XCTestCase {
    private let ctx = PriorityContext(senderInteractions: 0, projectConfirmed: false, preferenceBoost: 0, preferenceNotes: [])

    private func assess(deadlineHours: Double?, text: String = "demande", kind: WorkKind = .produce, deliverable: String? = "Fichier Excel",
                        context: PriorityContext? = nil, followUps: Int = 0, missing: Int = 0) -> PriorityAssessment {
        PriorityEngine.assess(deadline: deadlineHours.map { brainNow.addingTimeInterval($0 * 3600) }, conflict: false, text: text,
                              kind: kind, deliverable: deliverable, context: context ?? ctx, followUps: followUps,
                              missingCount: missing, totalInfo: 4, now: brainNow)
    }

    func testPriorityIsExplainedAndDeterministic() {
        let a = assess(deadlineHours: 20), b = assess(deadlineHours: 20)
        XCTAssertEqual(a.score, b.score)
        XCTAssertEqual(a.level, b.level)
        XCTAssertEqual(Set(a.factors.map(\.name)), ["Urgence", "Importance", "Conséquence d'un retard", "Effort vs temps", "Relances", "Informations disponibles"])
        XCTAssertTrue(a.factors.allSatisfy { !$0.explanation.isEmpty })
    }

    func testCloseDeadlineAloneIsNeverCritical() {
        let a = assess(deadlineHours: -2, text: "photos de l'équipe", kind: .reply, deliverable: nil)
        XCTAssertLessThan(a.level, .critical, "échéance dépassée mais aucune importance : plafonnée")
    }

    func testMajorObligationIsHighEvenWithFarDeadline() {
        let known = PriorityContext(senderInteractions: 5, projectConfirmed: true, preferenceBoost: 0, preferenceNotes: [])
        let a = assess(deadlineHours: 24 * 20, text: "relire le contrat client", kind: .review, deliverable: "Contrat", context: known)
        XCTAssertGreaterThanOrEqual(a.level, .high)
        XCTAssertTrue(a.notes.contains { $0.contains("obligation") })
    }

    func testFarDeadlineIsLowerThanNearDeadline() {
        XCTAssertGreaterThan(assess(deadlineHours: 12).score, assess(deadlineHours: 24 * 10).score)
        XCTAssertLessThan(assess(deadlineHours: nil).level, assess(deadlineHours: 6).level)
    }

    func testFollowUpsAndPreferencesRaiseScore() {
        XCTAssertGreaterThan(assess(deadlineHours: 48, followUps: 2).score, assess(deadlineHours: 48).score)
        let pref = PriorityContext(senderInteractions: 0, projectConfirmed: false, preferenceBoost: 0.3, preferenceNotes: ["x"])
        XCTAssertGreaterThan(assess(deadlineHours: 48, context: pref).score, assess(deadlineHours: 48).score)
    }

    func testPlanStepIdsAreStableAndPlanIsValid() {
        let goal = Goal(kind: .explicitRequest, expectedResult: "Fichier Excel", deliverable: "Fichier Excel", origin: "t",
                        people: [PersonRef(name: "Marie", email: "m@x.test", role: "demandeur")], projectID: nil, projectTitle: nil,
                        deadline: brainNow.addingTimeInterval(86_400), deadlineText: "demain", constraints: [], availableInfo: [], missingInfo: [],
                        confidence: 0.8, beliefs: [])
        func plan(_ resources: [ResourceRef]) -> MissionPlan {
            PlanningEngine.build(missionID: "m1", goal: goal, kind: .produce, resources: resources, missing: [], strategy: "s",
                                 deadline: goal.deadline, deadlineConflict: false, grants: GrantSnapshot(grants: ["folder": .watchFolder, "gmail": .readMail]),
                                 originSourceID: "gmail", previous: nil, calendar: brainCalendar)
        }
        let p1 = plan([]), p2 = plan([])
        XCTAssertEqual(p1.steps.map(\.id), p2.steps.map(\.id))
        XCTAssertTrue(PlanningEngine.validate(p1).isEmpty)
        XCTAssertEqual(Set(p1.steps.map(\.id)).count, p1.steps.count)
        XCTAssertTrue(p1.steps.allSatisfy { !$0.verification.isEmpty }, "chaque étape est vérifiable")
        // Un plan corrompu est détecté.
        var broken = p1; broken.steps[1].dependsOn = ["inconnu"]
        XCTAssertFalse(PlanningEngine.validate(broken).isEmpty)
        var dup = p1; dup.steps.append(dup.steps[0])
        XCTAssertFalse(PlanningEngine.validate(dup).isEmpty)
        // Actualisation : une étape terminée le reste.
        var done = p1; done.steps[1].state = .completed
        let p3 = PlanningEngine.build(missionID: "m1", goal: goal, kind: .produce, resources: [], missing: [], strategy: "s", deadline: goal.deadline,
                                      deadlineConflict: false, grants: .empty, originSourceID: "gmail", previous: done, calendar: brainCalendar)
        XCTAssertEqual(p3.steps[1].state, .completed)
        XCTAssertEqual(p3.revision, done.revision + 1)
    }

    func testTrustNeverGrantsWritesOrSends() {
        let all = GrantSnapshot(grants: ["gmail": .readMail, "folder": .watchFolder])
        for capability in Capability.allCases where capability != .read {
            let need = BrainTrust.evaluate(capability, resource: "x", sourceID: "folder", grants: all)
            XCTAssertEqual(need.status, .approvalRequired, "\(capability) ne doit jamais être accordée automatiquement")
        }
        XCTAssertEqual(BrainTrust.evaluate(.read, resource: "x", sourceID: "folder", grants: all).status, .granted)
        XCTAssertEqual(BrainTrust.evaluate(.read, resource: "x", sourceID: "folder", grants: .empty).status, .missing)
    }

    func testStateMachineRejectsIllegalTransitions() {
        XCTAssertFalse(MissionState.completed.canMove(to: .inProgress))
        XCTAssertFalse(MissionState.cancelled.canMove(to: .ready))
        XCTAssertTrue(MissionState.cancelled.canMove(to: .proposed), "réouverture explicite")
        XCTAssertTrue(MissionState.proposed.canMove(to: .ready))
        XCTAssertFalse(MissionState.detected.canMove(to: .completed))
    }

    func testUncertaintyStatementIsHonest() {
        let missing = [MissingItem(text: "Échéance contradictoire", severity: .clarify)]
        XCTAssertTrue(UncertaintyEngine.statement(missing: missing, conflict: false, confidence: 0.7).hasPrefix("Je pense qu'une mission existe, mais il me manque"))
        XCTAssertTrue(UncertaintyEngine.statement(missing: [], conflict: true, confidence: 0.7).contains("je ne choisis pas"))
    }
}

// MARK: - Model Gateway, avis du modèle, réseau

private struct ScriptedProvider: ModelProvider {
    var id = "scripted"; var model = "m"; var isSimulated = true
    var behavior: @Sendable () async throws -> String
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let text = try await behavior()
        return ModelResponse(text: text, provider: id, model: model, usage: ModelUsage(inputTokens: 100, outputTokens: 20), isSimulated: true)
    }
}
private struct FakeHTTP: HTTPClient {
    var handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { try handler(request) }
}

final class ModelGatewayTests: XCTestCase {
    private let req = ModelRequest(task: .refineAmbiguity, system: "s", user: "u")

    func testDisabledGatewayCallsNothing() async {
        let gateway = ModelGateway(providers: [ScriptedProvider { XCTFail("ne doit pas être appelé"); return "" }])
        do { _ = try await gateway.complete(req); XCTFail() } catch { XCTAssertEqual(error as? ModelError, .disabled) }
    }

    func testFallbackToNextProvider() async throws {
        let failing = ScriptedProvider(id: "a") { throw ModelError.providerFailed("panne") }
        let ok = ScriptedProvider(id: "b") { "{}" }
        let gateway = ModelGateway(providers: [failing, ok], policy: GatewayPolicy(enabled: true))
        let response = try await gateway.complete(req)
        XCTAssertEqual(response.provider, "b")
        let log = await gateway.callLog
        XCTAssertEqual(log.map(\.outcome), ["provider-error", "ok"])
    }

    func testTimeoutTriggersFallback() async throws {
        let slow = ScriptedProvider(id: "slow") { try await Task.sleep(nanoseconds: 3_000_000_000); return "{}" }
        let fast = ScriptedProvider(id: "fast") { "{}" }
        let gateway = ModelGateway(providers: [slow, fast], policy: GatewayPolicy(enabled: true, timeout: 0.1))
        let response = try await gateway.complete(req)
        XCTAssertEqual(response.provider, "fast")
        let outcomes = await gateway.callLog.map(\.outcome)
        XCTAssertEqual(outcomes.first, "timeout")
    }

    func testDailyBudgetIsEnforced() async throws {
        let gateway = ModelGateway(providers: [ScriptedProvider { "{}" }], policy: GatewayPolicy(enabled: true, maxCallsPerDay: 2))
        _ = try await gateway.complete(req); _ = try await gateway.complete(req)
        do { _ = try await gateway.complete(req); XCTFail() } catch {
            if case ModelError.budgetExceeded = error {} else { XCTFail("\(error)") }
        }
        let tokens = ModelGateway(providers: [ScriptedProvider { "{}" }], policy: GatewayPolicy(enabled: true, maxTokensPerDay: 100))
        _ = try await tokens.complete(req)
        do { _ = try await tokens.complete(req); XCTFail() } catch { if case ModelError.budgetExceeded = error {} else { XCTFail() } }
    }

    func testTechnicalLogNeverContainsContent() async throws {
        let gateway = ModelGateway(providers: [ScriptedProvider { "réponse secrète" }], policy: GatewayPolicy(enabled: true))
        _ = try await gateway.complete(ModelRequest(task: .refineAmbiguity, system: "s", user: "contenu personnel marie@acme.example"))
        let dump = String(data: try JSONEncoder().encode(await gateway.callLog), encoding: .utf8) ?? ""
        XCTAssertFalse(dump.contains("marie@acme.example"))
        XCTAssertFalse(dump.contains("secrète"))
    }

    func testRedactionMasksPersonalData() {
        let text = "Marie Dupont (marie.dupont@acme.example, +33 6 12 34 56 78) voir https://x.example/doc"
        let out = PromptRedactor.redact(text, names: ["Marie Dupont"])
        XCTAssertFalse(out.contains("Marie")); XCTAssertFalse(out.contains("@acme")); XCTAssertFalse(out.contains("12 34"))
        XCTAssertFalse(out.contains("https://"))
        XCTAssertTrue(out.contains("[personne]") && out.contains("[email]") && out.contains("[lien]"))
    }

    func testAdvisorParsingIsStrict() {
        XCTAssertNotNil(ModelAdvisor.parse("{\"verdict\":\"monitor\",\"confidence\":0.9,\"reason\":\"ok\"}"))
        XCTAssertNotNil(ModelAdvisor.parse("Voici : {\"verdict\":\"clarify\",\"confidence\":0.5,\"reason\":\"x\",\"missing\":[\"date\"]} fin"))
        XCTAssertNil(ModelAdvisor.parse("{\"verdict\":\"delete_everything\",\"confidence\":0.9,\"reason\":\"x\"}"))
        XCTAssertNil(ModelAdvisor.parse("{\"verdict\":\"ignore\",\"confidence\":4,\"reason\":\"x\"}"))
        XCTAssertNil(ModelAdvisor.parse("pas du json"))
        XCTAssertNil(ModelAdvisor.parse("{\"verdict\":\"ignore\",\"confidence\":0.5,\"reason\":\"\(String(repeating: "x", count: 500))\"}"))
    }

    func testModelCannotCreateMissionFromInformation() async throws {
        let model = ScriptedProvider { "{\"verdict\":\"create_mission\",\"confidence\":1.0,\"reason\":\"Je veux une mission\"}" }
        let gateway = ModelGateway(providers: [model], policy: GatewayPolicy(enabled: true))
        let env = try await BrainEnv.make(gateway: gateway)
        let info = env.mail(from: "Thomas <thomas@acme.example>", subject: "Réunion déplacée", body: "Pour info, la réunion est déplacée à lundi 10h.")
        let records = try await env.brain.process([info])
        XCTAssertNotEqual(records.first?.kind, .createMission)
        let _a1 = try await env.missions().isEmpty
        XCTAssertTrue(_a1)
        XCTAssertEqual(records.first?.engine, "rules", "le modèle n'est pas consulté pour une simple information")
        let auto = env.mail(from: "Service <noreply@service.example>", subject: "Votre facture", body: "Votre facture est disponible. Ne pas répondre.", bulk: true)
        let r2 = try await env.brain.process([auto])
        XCTAssertNotEqual(r2.first?.kind, .createMission)
    }

    func testModelOpinionOnAmbiguityIsRecordedAndCapped() async throws {
        let model = ScriptedProvider(id: "simulé") { "{\"verdict\":\"create_mission\",\"confidence\":0.9,\"reason\":\"Demande probable\",\"missing\":[\"objet\"]}" }
        let gateway = ModelGateway(providers: [model], policy: GatewayPolicy(enabled: true))
        let env = try await BrainEnv.make(gateway: gateway)
        let ambiguous = env.mail(subject: "Idée", body: "Il faudrait qu'on regarde ça prochainement.", thread: "t-m")
        let record = try await env.brain.process([ambiguous]).first
        XCTAssertEqual(record?.engine, "rules+model")
        XCTAssertEqual(record?.modelProvider, "simulé")
        XCTAssertEqual(record?.modelIsSimulated, true)
        // Plafond : depuis une surveillance, au mieux une clarification — jamais une mission ferme.
        XCTAssertNotEqual(record?.kind, .createMission)
        if record?.kind == .clarify {
            let _a2 = try await env.missions().first
            let m = try XCTUnwrap(_a2)
            XCTAssertEqual(m.state, .needsClarification)
        }
        XCTAssertTrue(record?.reasons.contains { $0.contains("Avis du modèle") } ?? false)
    }

    func testModelFailureFallsBackToRules() async throws {
        let gateway = ModelGateway(providers: [ScriptedProvider { throw ModelError.providerFailed("hors ligne") }], policy: GatewayPolicy(enabled: true))
        let env = try await BrainEnv.make(gateway: gateway)
        let record = try await env.brain.process([env.mail(subject: "Idée", body: "Il faudrait qu'on regarde ça prochainement.")]).first
        XCTAssertEqual(record?.kind, .monitor)
        XCTAssertEqual(record?.engine, "rules")
    }

    func testAnthropicProviderBuildsMaskedRequestAndParsesResponse() async throws {
        let secrets = InMemorySecretStore()
        try secrets.save(Data("sk-test".utf8), for: AnthropicProvider.secretKey)
        let captured = LockedBox<HTTPRequest?>(nil)
        let http = FakeHTTP { request in
            captured.set(request)
            let body = #"{"content":[{"type":"text","text":"{\"verdict\":\"monitor\",\"confidence\":0.8,\"reason\":\"vague\"}"}],"usage":{"input_tokens":50,"output_tokens":12}}"#
            return HTTPResponse(status: 200, body: Data(body.utf8))
        }
        let provider = AnthropicProvider(http: http, secrets: secrets)
        let response = try await provider.complete(ModelRequest(task: .refineAmbiguity, system: "sys", user: "{}"))
        XCTAssertEqual(response.usage, ModelUsage(inputTokens: 50, outputTokens: 12))
        XCTAssertFalse(response.isSimulated)
        let request = try XCTUnwrap(captured.get())
        XCTAssertEqual(request.url.host, "api.anthropic.com")
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.purpose, SourceID("brain"))
        XCTAssertNotNil(ModelAdvisor.parse(response.text))
        // Clé absente : échec explicite, aucune requête.
        let noKey = AnthropicProvider(http: FakeHTTP { _ in XCTFail("aucune requête sans clé"); return HTTPResponse(status: 200, body: Data()) }, secrets: InMemorySecretStore())
        do { _ = try await noKey.complete(ModelRequest(task: .refineAmbiguity, system: "", user: "")); XCTFail() } catch {}
        // Erreurs HTTP.
        for (status, _) in [(401, ""), (429, ""), (500, "")] {
            let bad = AnthropicProvider(http: FakeHTTP { _ in HTTPResponse(status: status, body: Data()) }, secrets: secrets)
            do { _ = try await bad.complete(ModelRequest(task: .refineAmbiguity, system: "", user: "")); XCTFail() } catch {}
        }
    }

    func testEgressRequiresExplicitModelPermission() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        let base = FakeHTTP { _ in HTTPResponse(status: 200, body: Data("{}".utf8)) }
        let guarded = GuardedHTTPClient(base: base, rules: PerceptionSystem.egressRules, trust: trust)
        let request = HTTPRequest(method: "POST", url: URL(string: "https://api.anthropic.com/v1/messages")!, purpose: SourceID("brain"))
        do { _ = try await guarded.send(request); XCTFail("refusé sans autorisation") } catch {}
        await trust.grant(SourceID("brain"), permission: .callExternalModel, scope: "anthropic")
        let ok = try await guarded.send(request)
        XCTAssertEqual(ok.status, 200)
        // Une autre source ne peut pas utiliser cette route, ni un autre hôte.
        do { _ = try await guarded.send(HTTPRequest(url: URL(string: "https://api.anthropic.com/")!, purpose: SourceID("gmail"))); XCTFail() } catch {}
        do { _ = try await guarded.send(HTTPRequest(url: URL(string: "https://api.openai.com/")!, purpose: SourceID("brain"))); XCTFail() } catch {}
        await trust.revoke(SourceID("brain"))
        do { _ = try await guarded.send(request); XCTFail("refusé après révocation") } catch {}
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}

// MARK: - Cycle de vie, actions de l'utilisateur, stockage

final class MissionLifecycleTests: XCTestCase {
    private func missionEnv() async throws -> (BrainEnv, Mission) {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.file("Résultats commerciaux octobre.xlsx")])
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-l")])
        let _a3 = try await env.missions().first
        return (env, try XCTUnwrap(_a3))
    }

    func testConfirmMovesToReadyOnlyWithoutBlockers() async throws {
        let (env, m) = try await missionEnv()
        XCTAssertEqual(m.state, .proposed)
        try await env.brain.confirm(m.id)
        let _a4 = try await env.missions().first
        let confirmed = try XCTUnwrap(_a4)
        XCTAssertEqual(confirmed.state, .ready)
        XCTAssertEqual(confirmed.verdict, .confirmed)
        XCTAssertFalse(BrainTrust.executionAllowed(confirmed), "READY n'est pas une autorisation d'exécution")
        XCTAssertTrue(confirmed.permissions.filter { $0.capability != .read }.allSatisfy { $0.status == .approvalRequired })

        // Mission bloquée : la confirmation ne la rend pas prête.
        let env2 = try await BrainEnv.make()
        try await env2.brain.process([env2.mail(subject: "Chiffres", body: "Peux-tu préparer un fichier Excel avec les chiffres du trimestre pour vendredi ?", thread: "t-l2")])
        let _a5 = try await env2.missions().first
        let blocked = try XCTUnwrap(_a5)
        try await env2.brain.confirm(blocked.id)
        let _a6 = try await env2.missions().first?.state
        XCTAssertEqual(_a6, .blocked)
    }

    func testRejectSuppressesRecreation() async throws {
        let (env, m) = try await missionEnv()
        try await env.brain.reject(m.id, reason: "pas pour moi")
        let state = try await env.state()
        XCTAssertEqual(state.missions[m.id]?.state, .cancelled)
        XCTAssertTrue(state.suppressedKeys.contains(m.dedupeKey))
        XCTAssertEqual(state.feedback.last?.kind, .reject)
        XCTAssertEqual(state.missions[m.id]?.history.filter(\.byUser).isEmpty, false)
        // Un nouveau message de la même situation n'est pas recréé.
        let again = env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-l", id: "nouveau")
        let record = try await env.brain.process([again]).first
        XCTAssertEqual(record?.kind, .ignore)
        let _a7 = try await env.missions().filter(\.isOpen).count
        XCTAssertEqual(_a7, 0)
    }

    func testUserCorrectionsAreTracedAndKeepHistory() async throws {
        let (env, m) = try await missionEnv()
        try await env.brain.correctGoal(m.id, to: "Tableau des résultats commerciaux d'octobre")
        try await env.brain.setPriority(m.id, to: .critical)
        try await env.brain.addNote(m.id, text: "Marie veut aussi les chiffres par région")
        let _a8 = try await env.missions().first
        let after = try XCTUnwrap(_a8)
        XCTAssertEqual(after.goal.expectedResult, "Tableau des résultats commerciaux d'octobre")
        XCTAssertEqual(after.effectivePriority, .critical)
        XCTAssertEqual(after.priority.level, m.priority.level, "la priorité calculée reste visible à côté de celle de l'utilisateur")
        XCTAssertEqual(after.notes.count, 1)
        XCTAssertTrue(after.history.starts(with: m.history))
        let _a9 = try await env.state().feedback.map(\.kind)
        XCTAssertEqual(Set(_a9), [.correctGoal, .changePriority, .addNote])
        try await env.brain.setPriority(m.id, to: nil)
        let _a10 = try await env.missions().first?.effectivePriority
        XCTAssertEqual(_a10, m.priority.level)
        do { try await env.brain.correctGoal(m.id, to: "  "); XCTFail() } catch {}
        do { try await env.brain.confirm("inconnue"); XCTFail() } catch { XCTAssertEqual(error as? BrainError == nil, false) }
    }

    func testCancellationByRequesterCancelsKeepingHistory() async throws {
        let (env, m) = try await missionEnv()
        let cancel = env.mail(subject: "Re: Résultats du mois", body: "Finalement plus besoin du fichier, désolée pour le dérangement.", thread: "t-l")
        let record = try await env.brain.process([cancel]).first
        XCTAssertEqual(record?.kind, .updateMission)
        let _a11 = try await env.missions().first
        let after = try XCTUnwrap(_a11)
        XCTAssertEqual(after.state, .cancelled)
        XCTAssertTrue(after.history.starts(with: m.history))
        XCTAssertTrue(after.plan.steps.allSatisfy { [.completed, .cancelled].contains($0.state) })
    }

    func testCancellationByThirdPartyIsIgnored() async throws {
        let (env, _) = try await missionEnv()
        let other = env.mail(from: "Quelqu'un <autre@elsewhere.example>", subject: "Re: Résultats du mois", body: "Finalement plus besoin du fichier.", thread: "t-l")
        let record = try await env.brain.process([other]).first
        XCTAssertEqual(record?.kind, .ignore)
        let _a12 = try await env.missions().first?.state
        XCTAssertEqual(_a12, .proposed)
    }

    func testAcknowledgementFromRequesterCompletesMission() async throws {
        let (env, _) = try await missionEnv()
        let ack = env.mail(subject: "Re: Résultats du mois", body: "Merci, bien reçu le fichier, c'est parfait.", thread: "t-l")
        let record = try await env.brain.process([ack]).first
        XCTAssertEqual(record?.kind, .completeMission)
        let _a13 = try await env.missions().first
        let m = try XCTUnwrap(_a13)
        XCTAssertEqual(m.state, .completed)
        XCTAssertTrue(m.history.contains { $0.kind == "completed" && $0.summary.contains("Non exécutée par GHOST") })
        XCTAssertFalse(record?.uncertainties.isEmpty ?? true)
    }

    func testFileArrivalResolvesMissingDependency() async throws {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.mail(subject: "Résultats", body: requestExcel, thread: "t-d2")])
        let _a14 = try await env.missions().first?.state
        XCTAssertEqual(_a14, .blocked)
        let record = try await env.brain.process([env.file("Résultats commerciaux octobre.xlsx")]).first
        XCTAssertEqual(record?.kind, .updateMission)
        let _a15 = try await env.missions().first
        let m = try XCTUnwrap(_a15)
        XCTAssertFalse(m.missingInfo.contains { $0.severity == .block })
        XCTAssertEqual(m.state, .proposed)
        XCTAssertTrue(m.history.contains { $0.kind == "dependency" })
        XCTAssertFalse(record?.uncertainties.isEmpty ?? true, "l'hypothèse est signalée")
    }

    func testUnrelatedFileIsIgnoredAndConversationNeverCreatesMission() async throws {
        let env = try await BrainEnv.make()
        let r = try await env.brain.process([env.file("photo-vacances.jpg")])
        XCTAssertEqual(r.first?.kind, .ignore)
        let chat = env.mail(from: "Sarah <sarah@partner.example>", subject: "Re: Déjeuner", body: "Merci pour hier, c'était un vrai plaisir !", reply: true)
        let r2 = try await env.brain.process([chat])
        XCTAssertTrue([.ignore, .remember].contains(r2.first?.kind))
        let _a16 = try await env.missions().isEmpty
        XCTAssertTrue(_a16)
    }

    func testScopesAreNotMixedWhenFindingResources() async throws {
        // Le document est dans un contexte personnel ; la demande est professionnelle.
        let env = try await BrainEnv.make(scope: .professional)
        try await env.context.setScope(.personal, for: SourceID("folder"))
        try await env.brain.process([env.file("Résultats commerciaux octobre.xlsx")])
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-s")])
        let _a17 = try await env.missions().first
        let m = try XCTUnwrap(_a17)
        XCTAssertTrue(m.resources.isEmpty, "un document personnel n'alimente pas une mission professionnelle")
        XCTAssertEqual(m.state, .blocked)
    }

    func testWatchIsMergedWhenRequestBecomesSpecific() async throws {
        let env = try await BrainEnv.make()
        try await env.brain.process([env.mail(subject: "Idée", body: "Il faudrait qu'on regarde ça prochainement.", thread: "t-w")])
        let _a18 = try await env.state().watches.count
        XCTAssertEqual(_a18, 1)
        env.clock.advance(600)
        try await env.brain.process([env.mail(subject: "Précision", body: "Peux-tu préparer un fichier Excel avec les ventes de novembre pour vendredi ?", thread: "t-w")])
        let state = try await env.state()
        XCTAssertEqual(state.missions.count, 1)
        XCTAssertTrue(state.watches.isEmpty, "la surveillance est fusionnée dans la mission")
    }

    func testRevocationRemovesOrRetainsBrainMemory() async throws {
        let (env, _) = try await missionEnv()
        try await env.brain.sourceWasRevoked(SourceID("gmail"), retainHistory: true)
        let _a19 = try await env.missions().count
        XCTAssertEqual(_a19, 1)
        try await env.brain.sourceWasRevoked(SourceID("gmail"), retainHistory: false)
        let _a20 = try await env.missions().isEmpty
        XCTAssertTrue(_a20)
        let _a21 = try await env.state().ledger.keys.filter { $0.hasPrefix("gmail|") }.isEmpty
        XCTAssertTrue(_a21)
        // Réconciliation après panne.
        let (env2, _) = try await missionEnv()
        await env2.trust.revoke(SourceID("gmail"))
        try await env2.brain.reconcilePermissions()
        let _a22 = try await env2.missions().isEmpty
        XCTAssertTrue(_a22)
    }

    func testDeleteMemoryErasesEverything() async throws {
        let (env, _) = try await missionEnv()
        try await env.brain.deleteMemory()
        let s = try await env.state()
        XCTAssertTrue(s.missions.isEmpty && s.decisions.isEmpty && s.ledger.isEmpty && s.watches.isEmpty && s.feedback.isEmpty)
    }

    func testReevaluationRaisesPriorityAsDeadlineApproaches() async throws {
        let (env, m) = try await missionEnv()
        env.clock.advance(20 * 3600)   // il ne reste que quelques heures avant « demain matin »
        try await env.brain.reevaluate()
        let _a23 = try await env.missions().first
        let after = try XCTUnwrap(_a23)
        XCTAssertGreaterThan(after.priority.score, m.priority.score)
        XCTAssertTrue(after.history.starts(with: m.history))
    }
}

final class MissionStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)").appendingPathComponent("missions.json")
    }

    func testPersistenceRoundTrip() async throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MissionStore(url: url)
        let env = try await BrainEnv.make(store: store)
        try await env.brain.process([env.mail(subject: "Résultats du mois", body: requestExcel, thread: "t-p")])
        let before = try await store.snapshot()
        let reopened = try await MissionStore(url: url).snapshot()
        XCTAssertEqual(before.missions, reopened.missions)
        XCTAssertEqual(before.ledger, reopened.ledger)
        XCTAssertEqual(before.decisions, reopened.decisions)
    }

    func testCorruptFileIsNeverOverwritten() async throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("pas du json".utf8)
        try garbage.write(to: url)
        let store = MissionStore(url: url)
        do { _ = try await store.snapshot(); XCTFail() } catch {}
        do { try await store.commit { _ in }; XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testNewerSchemaIsRefusedAndPreserved() async throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\":99}".utf8)
        try future.write(to: url)
        let store = MissionStore(url: url)
        do { _ = try await store.snapshot(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("plus récente")) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testFailedWriteLeavesMemoryUntouched() async throws {
        let store = MissionStore(url: nil)
        await store.setFailNextSaves(1)
        do { try await store.commit { $0.salt = "x" }; XCTFail() } catch {}
        let _a24 = try await store.snapshot().salt
        XCTAssertNotEqual(_a24, "x")
    }
}

// MARK: - Régressions de l'audit des Missions 003/004

private actor AuditModelGate {
    private var entered = 0
    private var opened = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func hold() async {
        entered += 1
        let ready = observers.filter { entered >= $0.0 }
        observers.removeAll { entered >= $0.0 }
        ready.forEach { $0.1.resume() }
        if opened { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func waitForEntry(_ count: Int = 1) async {
        if entered >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release() { opened = true; let all = pending; pending.removeAll(); all.forEach { $0.resume() } }
}

final class BrainAuditRegressionTests: XCTestCase {
    private func assertInvalidatedAnalysis(_ action: String) async throws {
        let gate = AuditModelGate()
        let provider = SimulatedModelProvider { _ in
            await gate.hold()
            return #"{"verdict":"monitor","confidence":0.9,"reason":"Avis de test"}"#
        }
        let gateway = ModelGateway(providers: [provider], policy: GatewayPolicy(enabled: true, timeout: 5))
        let env = try await BrainEnv.make(gateway: gateway)
        let event = env.mail(subject: "Idée confidentielle", body: "Il faudrait qu'on regarde ça prochainement.")
        let processing = Task { try await env.brain.process([event]) }
        await gate.waitForEntry()
        switch action {
        case "pause": await env.brain.setActive(false)
        case "revoke":
            await env.trust.revoke(mailSrc.id)
            try await env.brain.sourceWasRevoked(mailSrc.id, retainHistory: false)
        default: try await env.brain.deleteMemory()
        }
        await gate.release()
        _ = try await processing.value
        let state = try await env.state()
        XCTAssertTrue(state.missions.isEmpty)
        XCTAssertTrue(state.watches.isEmpty, "Une analyse invalidée ne doit pas recréer une surveillance")
        XCTAssertTrue(state.decisions.isEmpty, "Une analyse invalidée ne doit pas enregistrer de décision")
        XCTAssertTrue(state.ledger.isEmpty)
    }
    func testPauseInvalidatesModelAnalysisAlreadyInFlight() async throws { try await assertInvalidatedAnalysis("pause") }
    func testRevocationInvalidatesModelAnalysisAlreadyInFlight() async throws { try await assertInvalidatedAnalysis("revoke") }
    func testDeletionInvalidatesModelAnalysisAlreadyInFlight() async throws { try await assertInvalidatedAnalysis("delete") }

    func testRevocationPurgesDecisionsFeedbackAndRejectedKeys() async throws {
        let env = try await BrainEnv.make()
        let event = env.mail(subject: "Rapport confidentiel", body: requestExcel, thread: "audit-secret-thread")
        _ = try await env.brain.process([event])
        let initial = try await env.missions()
        let mission = try XCTUnwrap(initial.first)
        try await env.brain.addNote(mission.id, text: "audit-note-secret")
        try await env.brain.reject(mission.id, reason: "audit-rejection-secret")
        await env.trust.revoke(mailSrc.id)
        try await env.brain.sourceWasRevoked(mailSrc.id, retainHistory: false)
        let state = try await env.state()
        XCTAssertTrue(state.missions.isEmpty)
        XCTAssertTrue(state.decisions.isEmpty)
        XCTAssertTrue(state.feedback.isEmpty)
        XCTAssertTrue(state.suppressedKeys.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(encoded.contains("audit-note-secret"))
        XCTAssertFalse(encoded.contains("audit-rejection-secret"))
    }

    func testFallbackCannotExceedDailyCallBudget() async throws {
        let failing = SimulatedModelProvider { _ in throw ModelError.providerFailed("panne fictive") }
        let gateway = ModelGateway(providers: [failing, failing], policy: GatewayPolicy(enabled: true, maxCallsPerDay: 1))
        do { _ = try await gateway.complete(ModelRequest(task: .refineAmbiguity, system: "s", user: "u")) } catch {}
        let log = await gateway.callLog
        XCTAssertEqual(log.count, 1, "Le fournisseur de repli doit aussi respecter le plafond")
    }

    func testConcurrentRequestsReserveCallBudgetBeforeAwaiting() async throws {
        let gate = AuditModelGate()
        let provider = SimulatedModelProvider { _ in await gate.hold(); return "{}" }
        let gateway = ModelGateway(providers: [provider], policy: GatewayPolicy(enabled: true, maxCallsPerDay: 1))
        let first = Task { try await gateway.complete(ModelRequest(task: .refineAmbiguity, system: "s", user: "premier")) }
        await gate.waitForEntry()
        let second = Task { try? await gateway.complete(ModelRequest(task: .refineAmbiguity, system: "s", user: "second")) }
        // Laisse l'appel concurrent terminer (refus) ou atteindre le fournisseur.
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        _ = try await first.value
        let response = await second.value
        XCTAssertNil(response)
        let log = await gateway.callLog
        XCTAssertEqual(log.count, 1)
    }
}

final class ModelBudgetPersistenceAuditTests: XCTestCase {
    func testRestartDoesNotResetDailyCallBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let policy = GatewayPolicy(enabled: true, maxCallsPerDay: 1)
        let request = ModelRequest(task: .refineAmbiguity, system: "s", user: "donnée fictive")
        let provider = SimulatedModelProvider()
        let first = ModelGateway(providers: [provider], policy: policy, clock: { brainNow }, usageURL: url)
        _ = try await first.complete(request)
        let restarted = ModelGateway(providers: [provider], policy: policy, clock: { brainNow }, usageURL: url)
        do { _ = try await restarted.complete(request); XCTFail("Le budget doit survivre au redémarrage") }
        catch { guard case ModelError.budgetExceeded = error else { return XCTFail("\(error)") } }
        let log = await restarted.callLog
        XCTAssertTrue(log.isEmpty)
        let nextDay = ModelGateway(providers: [provider], policy: policy, clock: { brainNow.addingTimeInterval(86_400) }, usageURL: url)
        _ = try await nextDay.complete(request)
        let dump = try String(contentsOf: url)
        XCTAssertFalse(dump.contains("donnée fictive"))
    }

    func testCorruptQuotaFileIsPreservedAndBlocksProvider() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-quota-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("fichier invalide à préserver".utf8)
        try bytes.write(to: url)
        let provider = SimulatedModelProvider { _ in XCTFail("Aucun appel sans suivi de quotas fiable"); return "{}" }
        let gateway = ModelGateway(providers: [provider], policy: GatewayPolicy(enabled: true), usageURL: url)
        do { _ = try await gateway.complete(ModelRequest(task: .refineAmbiguity, system: "s", user: "u")); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}

final class BrainIsolationAuditTests: XCTestCase {
    func testSimulatedPreferenceNeverInfluencesRealContext() async throws {
        let env = try await BrainEnv.make()
        let simulatedSource = EventSource(id: mailSrc.id, kind: .email, displayName: "Simulation", isSimulated: true)
        let simulatedEvent = env.mail(subject: "[Projet: Atlas] Simulation", body: requestExcel, thread: "sim", source: simulatedSource)
        try await env.context.ingest([simulatedEvent])
        let simulatedGraph = try await env.context.snapshot()
        let project = try XCTUnwrap(simulatedGraph.nodes.values.first { $0.kind == .project && $0.isSimulated })
        _ = try await env.context.remember(kind: .preference, text: "Marie : priorité élevée", scope: .professional, projectID: project.id)
        let realEvent = env.mail(subject: "[Projet: Atlas] Réel", body: requestExcel, thread: "real")
        try await env.context.ingest([realEvent])
        let graph = try await env.context.snapshot()
        let realLens = ContextLens(graph: graph, event: realEvent)
        XCTAssertTrue(realLens.preferences(matching: ["Marie"]).isEmpty)
        let simulatedLens = ContextLens(graph: graph, event: simulatedEvent)
        XCTAssertEqual(simulatedLens.preferences(matching: ["Marie"]).count, 1)
    }
}

final class BrainCompletionEvidenceAuditTests: XCTestCase {
    func testFileMetadataAloneCannotCompleteMission() async throws {
        let env = try await BrainEnv.make()
        _ = try await env.brain.process([env.file("resultats_commerciaux_source.xlsx")])
        _ = try await env.brain.process([env.mail(subject: "Résultats commerciaux", body: requestExcel, thread: "completion-audit")])
        let missions = try await env.missions()
        let mission = try XCTUnwrap(missions.first)
        XCTAssertFalse(mission.missingInfo.contains { $0.severity == .block })
        env.clock.advance(10)
        let decisions = try await env.brain.process([env.file("resultats_commerciaux_final.xlsx")])
        let current = try await env.state()
        XCTAssertNotEqual(decisions.last?.kind, .completeMission, "Un nom et une extension ne prouvent pas que le contenu est correct")
        XCTAssertNotEqual(current.missions[mission.id]?.state, .completed)
        XCTAssertEqual(decisions.last?.kind, .updateMission)
    }
}
