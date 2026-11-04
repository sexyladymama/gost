import XCTest
@testable import GhostBrain
@testable import GhostContext
@testable import GhostPerception

/// Critère final de la Mission 004, avec les vrais composants (aucun réseau, boîte simulée) :
/// événement → Perception → Context → Brain → mission, sans aucune action réelle.
final class BrainEndToEndTests: XCTestCase {

    func testSimulatedMailboxProducesMissionsEndToEnd() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = GhostProfile(id: "e2e", baseDirectory: base)
        let system = PerceptionSystem(profile: profile, persistent: false, tick: nil)
        let context = ContextEngine(profile: profile, trust: system.trust, persistent: false)
        var config = BrainConfig(); config.calendar = brainCalendar
        let store = MissionStore(url: nil)
        let brain = BrainEngine(store: store, context: context, trust: system.trust, config: config)
        await system.engine.addConsumer(context)
        await system.engine.addConsumer(brain)

        // 1. L'utilisateur autorise la boîte de test (action explicite) — rien d'autre.
        await system.trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "simulation")
        let provider = SimulatedMailProvider(deliveredPerFetch: 7)
        await system.engine.register(EmailSource(provider: provider, trust: system.trust, stateStore: system.sourceState,
                                                 startDate: Date(timeIntervalSince1970: 0), pollInterval: 0.01))
        await system.engine.start()

        // 2. Un événement arrive dans la source autorisée ; Perception le détecte.
        let report = await system.engine.runCycle(force: true)
        XCTAssertEqual(report.newEvents.count, 7)

        // 3-8. Context retrouve les informations, le Brain comprend, décide et crée les missions.
        let state = try await brain.snapshot()
        let missions = state.missions.values.sorted { $0.title < $1.title }
        print("\nBOUT EN BOUT — \(state.decisions.count) décisions, \(missions.count) mission(s)")
        for d in state.decisions.sorted(by: { $0.date < $1.date }) {
            print("  \(d.kind.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(d.reasons.first ?? "")")
        }
        for m in missions { print("  ▸ \(m.title) · \(m.state.rawValue) · \(m.priority.level.rawValue)\(m.deadline.map { " · échéance \($0.formatted())" } ?? "")") }

        XCTAssertEqual(state.decisions.count, 7, "chaque événement est analysé exactement une fois")
        let titles = missions.map { $0.title.lowercased() }
        XCTAssertTrue(titles.contains { $0.contains("fichier excel") }, "la demande de Marie devient une mission")
        XCTAssertTrue(missions.contains { $0.goal.deliverable == "Fichier Excel" && $0.deadline != nil })
        XCTAssertFalse(missions.contains { $0.title.lowercased().contains("lettre") }, "la newsletter n'en crée aucune")
        XCTAssertFalse(state.decisions.contains { $0.kind == .createMission && $0.reasons.joined().contains("désabonner") })

        for m in missions {
            XCTAssertFalse(m.plan.steps.isEmpty)                                    // plan opérationnel
            XCTAssertFalse(m.priority.factors.isEmpty)                              // priorité justifiée
            XCTAssertFalse(m.permissions.isEmpty)                                   // autorisations identifiées
            XCTAssertFalse(decisionsExplain(state, m))                              // raison de création conservée
            XCTAssertFalse(BrainTrust.executionAllowed(m))                          // rien n'est exécutable
            XCTAssertTrue(m.permissions.filter { $0.capability != .read }.allSatisfy { $0.status == .approvalRequired })
            XCTAssertFalse([MissionState.inProgress, .completed].contains(m.state)) // aucune action réalisée
            XCTAssertFalse(m.plan.steps.contains { $0.state == .completed && $0.key != "understand" })
        }

        // 9. Aucune action réelle : le journal d'accès ne contient que des lectures autorisées.
        let log = await system.accessLog.all()
        XCTAssertFalse(log.contains { $0.operation.contains("send") || $0.operation.contains("delete") || $0.operation.contains("write") })
        XCTAssertFalse(log.contains { $0.operation == "network.request" }, "aucune requête réseau")

        // Rejouer tout ne crée aucun doublon.
        let events = try await system.store.all()
        await brain.catchUp(events)
        let again = try await brain.snapshot()
        XCTAssertEqual(again.missions.count, missions.count)
        XCTAssertEqual(again.decisions.count, state.decisions.count)
    }

    private func decisionsExplain(_ state: BrainState, _ m: Mission) -> Bool {
        state.decisions.filter { $0.missionID == m.id && $0.kind == .createMission || $0.kind == .clarify && $0.missionID == m.id }.allSatisfy { $0.reasons.isEmpty }
    }
}
