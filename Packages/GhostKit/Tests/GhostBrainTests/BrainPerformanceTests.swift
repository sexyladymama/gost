import XCTest
@testable import GhostBrain
@testable import GhostContext
@testable import GhostPerception

/// Mesures réelles de performance (affichées, non inventées). Les seuils sont volontairement larges.
final class BrainPerformanceTests: XCTestCase {
    func testThroughputOnLargeBatch() async throws {
        let env = try await BrainEnv.make()
        let n = 300
        var events: [GhostEvent] = []
        for i in 0..<n {
            if i % 3 == 0 {
                events.append(env.mail(from: "Contact \(i) <c\(i)@acme.example>", subject: "Demande \(i)", body: "Peux-tu préparer un fichier Excel avec les chiffres \(i) pour vendredi ?", thread: "perf-\(i)", id: "perf-\(i)"))
            } else if i % 3 == 1 {
                events.append(env.mail(from: "Info \(i) <i\(i)@acme.example>", subject: "Info \(i)", body: "Pour info, la salle \(i) est réservée lundi 10h.", id: "perf-\(i)"))
            } else {
                events.append(env.mail(from: "News <n\(i)@news.example>", subject: "Lettre \(i)", body: "Pour vous désabonner, cliquez ici.", id: "perf-\(i)", bulk: true))
            }
        }
        let start = Date()
        let records = try await env.brain.process(events)
        let elapsed = Date().timeIntervalSince(start)
        let state = try await env.state()
        print(String(format: "PERF %d événements → %d décisions, %d missions en %.2f s (%.1f ms/événement)", n, records.count, state.missions.count, elapsed, elapsed * 1000 / Double(n)))
        XCTAssertEqual(records.count, n)
        XCTAssertEqual(state.missions.count, n / 3)
        XCTAssertLessThan(elapsed, 60, "traitement par lot trop lent")
        // Reprise : relire les mêmes événements ne coûte presque rien et ne crée rien.
        let again = Date()
        _ = try await env.brain.process(events)
        let replay = Date().timeIntervalSince(again)
        print(String(format: "PERF rejeu de %d événements déjà traités : %.3f s", n, replay))
        XCTAssertLessThan(replay, 5)
        let finalState = try await env.state()
        XCTAssertEqual(finalState.missions.count, n / 3)
    }

    /// Cas courant : les événements arrivent un par un (le coût augmente avec la taille du graphe).
    func testSequentialArrival() async throws {
        let env = try await BrainEnv.make()
        let n = 150
        let start = Date()
        var worst: TimeInterval = 0
        for i in 0..<n {
            let t = Date()
            _ = try await env.brain.process([env.mail(from: "Contact \(i) <c\(i)@acme.example>", subject: "Demande \(i)",
                                                      body: "Peux-tu préparer un fichier Excel avec les chiffres \(i) pour vendredi ?", thread: "seq-\(i)", id: "seq-\(i)")])
            worst = max(worst, Date().timeIntervalSince(t))
        }
        let total = Date().timeIntervalSince(start)
        print(String(format: "PERF séquentiel %d événements : %.2f s au total (%.1f ms en moyenne, pire %.0f ms)", n, total, total * 1000 / Double(n), worst * 1000))
        XCTAssertLessThan(worst, 2, "un événement isolé doit rester traité en moins de 2 s à ce volume")
    }
}
