import XCTest
@testable import GhostBrain
@testable import GhostContext
@testable import GhostPerception

/// Évaluation de la qualité du cerveau sur des scénarios de référence.
///
/// Les résultats attendus sont fixés **avant** l'exécution (raisonnement de l'utilisateur type,
/// pas copie de la sortie). Les taux affichés sont calculés sur les exécutions réelles ;
/// aucun chiffre n'est écrit à la main. Pour écrire le rapport :
/// `GHOST_BRAIN_EVAL_OUT=/chemin/rapport.md swift test --filter BrainEvaluationTests`
final class BrainEvaluationTests: XCTestCase {

    struct Step { var delay: TimeInterval = 0; var make: (BrainEnv) -> GhostEvent }
    struct Reference {
        var name: String
        var grants: [(SourceID, Permission)] = [(SourceID("gmail"), .readMail), (SourceID("folder"), .watchFolder)]
        var setup: [Step] = []
        var steps: [Step]
        var expectMission: Bool
        var kinds: Set<DecisionKind>
        var deadlineDay: (Int, Int, Int)? = nil
        var expectNoDeadline = false
        var priority: MissionPriority? = nil
        var state: MissionState? = nil
        var missionCount: Int? = nil
    }

    static func mail(_ subject: String, _ body: String, thread: String? = nil, from: String = "Marie Dupont <marie.dupont@acme.example>",
                     bulk: Bool = false, reply: Bool = false, to: [String] = ["moi@ghost.test"], cc: [String] = [], delay: TimeInterval = 0) -> Step {
        Step(delay: delay) { $0.mail(from: from, subject: subject, body: body, thread: thread, id: "ref-" + subject + body.prefix(12), bulk: bulk, reply: reply, to: to, cc: cc) }
    }
    static func file(_ name: String) -> Step { Step { $0.file(name) } }

    static let references: [Reference] = [
        Reference(name: "01 Excel demain, source connue", setup: [file("Résultats commerciaux octobre.xlsx")],
                  steps: [mail("Résultats du mois", requestExcel, thread: "r1")], expectMission: true, kinds: [.createMission],
                  deadlineDay: (2026, 11, 5), priority: .high, state: .proposed),
        Reference(name: "02 Excel demain, source absente", steps: [mail("Résultats du mois", requestExcel, thread: "r2")],
                  expectMission: true, kinds: [.createMission], deadlineDay: (2026, 11, 5), priority: .high, state: .blocked),
        Reference(name: "03 Rapport Q3 (anglais), vendredi",
                  steps: [mail("Q3 report", "Hi, could you send me the Q3 sales report by Friday? Thanks, John", thread: "r3", from: "John Smith <john.smith@client.example>")],
                  expectMission: true, kinds: [.createMission], deadlineDay: (2026, 11, 6), priority: .normal, state: .blocked),
        Reference(name: "04 Relance contrat avant vendredi",
                  steps: [mail("Relance : contrat fournisseur", "Bonjour,\n\nJe me permets de revenir vers toi : as-tu pu relire le contrat ?\nJ'en aurais besoin avant vendredi.\n\nPaul", thread: "r4", from: "Paul Martin <paul.martin@fournisseur.example>")],
                  expectMission: true, kinds: [.createMission], deadlineDay: (2026, 11, 6), priority: .high),
        Reference(name: "05 Disponibilité réunion jeudi 14 h",
                  steps: [mail("Point projet", "Est-ce que tu serais disponible jeudi à 14h pour faire un point sur le projet ?", thread: "r5", from: "Julie Bernard <julie.bernard@acme.example>")],
                  expectMission: true, kinds: [.createMission], priority: .normal),
        Reference(name: "06 Newsletter", steps: [mail("Les nouveautés de la semaine", "Découvrez notre sélection d'articles.\nPour vous désabonner, cliquez ici.", from: "La Lettre Tech <newsletter@lettre-tech.example>", bulk: true)],
                  expectMission: false, kinds: [.ignore]),
        Reference(name: "07 Information horaire (en copie)", steps: [mail("Réunion d'équipe déplacée", "Pour info, la réunion d'équipe est déplacée à lundi 10h, même salle.", from: "Thomas Leroy <thomas.leroy@acme.example>", cc: ["equipe@acme.example"])],
                  expectMission: false, kinds: [.ignore, .remember]),
        Reference(name: "08 Remerciement", steps: [mail("Re: Déjeuner", "Merci pour hier, c'était un vrai plaisir !", from: "Sarah Cohen <sarah.cohen@partner.example>", reply: true)],
                  expectMission: false, kinds: [.ignore, .remember]),
        Reference(name: "09 Demande vague", steps: [mail("Idée", "Il faudrait qu'on regarde ça prochainement.", thread: "r9")],
                  expectMission: false, kinds: [.monitor]),
        Reference(name: "10 Souhait vague de rencontre", steps: [mail("Discussion", "On devrait se voir un de ces jours pour en discuter.", thread: "r10")],
                  expectMission: false, kinds: [.ignore, .remember, .monitor]),
        Reference(name: "11 Demande adressée à quelqu'un d'autre (en copie)",
                  steps: [mail("Budget", "Marie, peux-tu préparer le budget pour lundi ?", thread: "r11", to: ["marie@acme.example"], cc: ["moi@ghost.test"])],
                  expectMission: false, kinds: [.ignore, .monitor, .remember]),
        Reference(name: "12 Message automatique", steps: [mail("Votre facture est disponible", "Votre facture est disponible dans votre espace. Ne pas répondre à ce message.", from: "Service <noreply@service.example>")],
                  expectMission: false, kinds: [.ignore]),
        Reference(name: "13 Annulation par le demandeur",
                  steps: [mail("Résultats du mois", requestExcel, thread: "r13"), mail("Re: Résultats du mois", "Finalement plus besoin du fichier, désolée.", thread: "r13", delay: 600)],
                  expectMission: true, kinds: [.updateMission], state: .cancelled, missionCount: 1),
        Reference(name: "14 Échéance modifiée",
                  steps: [mail("Résultats du mois", requestExcel, thread: "r14"),
                          mail("Re: Résultats du mois", "Peux-tu préparer le fichier Excel des résultats du mois pour lundi ? L'échéance est finalement décalée.", thread: "r14", delay: 600)],
                  expectMission: true, kinds: [.updateMission], deadlineDay: (2026, 11, 9), missionCount: 1),
        Reference(name: "15 Relance sans doublon",
                  steps: [mail("Résultats du mois", requestExcel, thread: "r15"),
                          mail("Re: Résultats du mois", "Petit rappel : as-tu pu préparer le fichier Excel des résultats du mois ?", thread: "r15", delay: 600)],
                  expectMission: true, kinds: [.updateMission], missionCount: 1),
        Reference(name: "16 Échéances contradictoires",
                  steps: [mail("Résultats du mois", requestExcel, thread: "r16"),
                          mail("Résultats du mois", "Pour le fichier Excel des résultats du mois, il faudrait le préparer pour lundi, peux-tu le faire ?", thread: "r16", from: "Julie Bernard <julie.bernard@acme.example>", delay: 600)],
                  expectMission: true, kinds: [.updateMission], expectNoDeadline: true, state: .needsClarification, missionCount: 1),
        Reference(name: "17 Accusé de réception",
                  steps: [mail("Résultats du mois", requestExcel, thread: "r17"), mail("Re: Résultats du mois", "Merci, bien reçu le fichier, c'est parfait.", thread: "r17", delay: 600)],
                  expectMission: true, kinds: [.completeMission], state: .completed, missionCount: 1),
        Reference(name: "18 Relecture de contrat, document connu", setup: [file("Contrat Dupont.docx")],
                  steps: [mail("Contrat", "Peux-tu relire le contrat Dupont avant vendredi ?", thread: "r18", from: "Paul Martin <paul.martin@fournisseur.example>")],
                  expectMission: true, kinds: [.createMission], deadlineDay: (2026, 11, 6), priority: .high, state: .proposed),
        Reference(name: "19 Dossier non autorisé", grants: [(SourceID("gmail"), .readMail)],
                  steps: [mail("Rapport", "Peux-tu relire le rapport trimestriel avant vendredi ?", thread: "r19")],
                  expectMission: true, kinds: [.createMission], state: .blocked),
        Reference(name: "20 Urgent, devis client", steps: [mail("Devis", "URGENT : peux-tu m'envoyer le devis client dès que possible ?", thread: "r20", from: "Luc Moreau <luc.moreau@client.example>")],
                  expectMission: true, kinds: [.createMission], priority: .high),
        Reference(name: "21 Contrat cadre fin de mois, interlocuteur inconnu",
                  steps: [mail("Contrat cadre", "Peux-tu relire et signer le contrat cadre client d'ici fin du mois ?", thread: "r21", from: "Anne Roux <anne.roux@nouveau.example>")],
                  expectMission: true, kinds: [.createMission], priority: .normal),
        Reference(name: "22 Relecture ce soir",
                  steps: [mail("Présentation", "Peux-tu relire ma présentation avant ce soir ?", thread: "r22", from: "Hugo Petit <hugo.petit@acme.example>")],
                  expectMission: true, kinds: [.createMission], priority: .high),
        Reference(name: "23 Conversation courte", steps: [mail("Re: Point", "ok d'accord", thread: "r23", from: "Hugo Petit <hugo.petit@acme.example>", reply: true)],
                  expectMission: false, kinds: [.ignore, .remember]),
        Reference(name: "24 Fichier sans lien", steps: [file("photo-vacances.jpg")], expectMission: false, kinds: [.ignore]),
        Reference(name: "25 Dépendance résolue par un fichier",
                  steps: [mail("Résultats du mois", requestExcel, thread: "r25"), Step(delay: 600) { $0.file("Résultats commerciaux octobre.xlsx") }],
                  expectMission: true, kinds: [.updateMission], state: .proposed, missionCount: 1),
        Reference(name: "26 Obligation sans demande", steps: [mail("Rappel calendrier", "Le rapport mensuel doit être remis le 15 novembre.", thread: "r26", from: "Direction <direction@acme.example>")],
                  expectMission: false, kinds: [.monitor, .remember, .ignore])
    ]

    struct Outcome {
        var ref: Reference
        var kinds: [DecisionKind]
        var missions: [Mission]
        var signature: String
        var failures: [String] = []
    }

    func run(_ ref: Reference) async throws -> Outcome {
        let env = try await BrainEnv.make(grants: ref.grants)
        for step in ref.setup { try await env.brain.process([step.make(env)]) }
        var kinds: [DecisionKind] = []
        for step in ref.steps {
            env.clock.advance(step.delay)
            let records = try await env.brain.process([step.make(env)])
            kinds.append(records.first?.kind ?? .ignore)
        }
        let missions = try await env.missions().sorted { $0.dedupeKey < $1.dedupeKey }
        let sig = kinds.map(\.rawValue).joined(separator: ",") + "|" + missions.map { "\($0.state.rawValue)/\($0.priority.level.rawValue)/\($0.deadline.map { String(Int($0.timeIntervalSince1970)) } ?? "-")" }.joined(separator: ";")
        return Outcome(ref: ref, kinds: kinds, missions: missions, signature: sig)
    }

    func planQualityOK(_ m: Mission) -> Bool {
        guard m.plan.steps.count >= 4, PlanningEngine.validate(m.plan).isEmpty || m.state.isTerminal, !m.successConditions.isEmpty,
              m.plan.steps.allSatisfy({ !$0.verification.isEmpty && !$0.title.isEmpty }),
              m.plan.steps.first?.state == .completed || m.state == .cancelled,
              m.permissions.filter({ $0.capability != .read }).allSatisfy({ $0.status == .approvalRequired }),
              m.plan.steps.contains(where: { $0.needs.contains { $0.capability == .sendCommunication } }) else { return false }
        return true
    }

    func testEvaluationOfReferenceScenarios() async throws {
        var outcomes: [Outcome] = []
        var stable = 0
        for ref in Self.references {
            var outcome = try await run(ref)
            let second = try await run(ref)
            if second.signature == outcome.signature { stable += 1 } else { outcome.failures.append("instable entre deux analyses") }
            outcomes.append(outcome)
        }

        // Métriques calculées à partir des exécutions réelles.
        var tp = 0, fp = 0, fn = 0, tn = 0
        var kindOK = 0, deadlineTotal = 0, deadlineOK = 0, prioTotal = 0, prioExact = 0, prioNear = 0
        var stateTotal = 0, stateOK = 0, countTotal = 0, countOK = 0, planTotal = 0, planOK = 0
        var permissionViolations = 0, executionAllowed = 0, rows: [String] = []
        for i in outcomes.indices {
            let o = outcomes[i], r = o.ref
            let created = !o.missions.isEmpty
            switch (r.expectMission, created) { case (true, true): tp += 1; case (false, true): fp += 1; case (true, false): fn += 1; case (false, false): tn += 1 }
            var notes: [String] = []
            if r.kinds.contains(o.kinds.last ?? .ignore) { kindOK += 1 } else { notes.append("décision \(o.kinds.last?.rawValue ?? "?") ∉ attendu") }
            let m = o.missions.first
            if let day = r.deadlineDay {
                deadlineTotal += 1
                if let d = m?.deadline, brainCalendar.isDate(d, inSameDayAs: parisDate(day.0, day.1, day.2)) { deadlineOK += 1 } else { notes.append("échéance ≠ attendue") }
            }
            if r.expectNoDeadline { deadlineTotal += 1; if m?.deadline == nil { deadlineOK += 1 } else { notes.append("échéance inventée") } }
            if let p = r.priority, let m {
                prioTotal += 1
                if m.priority.level == p { prioExact += 1 } else { notes.append("priorité \(m.priority.level.rawValue) ≠ \(p.rawValue)") }
                if abs(m.priority.level.rank - p.rank) <= 1 { prioNear += 1 }
            }
            if let s = r.state { stateTotal += 1; if m?.state == s { stateOK += 1 } else { notes.append("état \(m?.state.rawValue ?? "aucun") ≠ \(s.rawValue)") } }
            if let c = r.missionCount { countTotal += 1; if o.missions.count == c { countOK += 1 } else { notes.append("\(o.missions.count) mission(s) ≠ \(c)") } }
            for mission in o.missions {
                planTotal += 1; if planQualityOK(mission) { planOK += 1 } else { notes.append("plan insuffisant") }
                if BrainTrust.executionAllowed(mission) { executionAllowed += 1 }
                permissionViolations += mission.permissions.filter { $0.capability != .read && $0.status != .approvalRequired }.count
            }
            outcomes[i].failures += notes
            rows.append("| \(r.name) | \(o.kinds.map(\.rawValue).joined(separator: " → ")) | \(m.map { "\($0.state.rawValue) · \($0.priority.level.rawValue)" } ?? "—") | \(notes.isEmpty ? "✅" : "❌ " + notes.joined(separator: " ; ")) |")
        }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f %% (%d/%d)", Double(a) / Double(b) * 100, a, b) }
        let precision = pct(tp, tp + fp), recall = pct(tp, tp + fn)
        let report = """
        # Évaluation du cerveau — scénarios de référence

        Généré par `BrainEvaluationTests` (modèle **non utilisé** : règles seules, aucune API). Taux calculés sur \(outcomes.count) scénarios réellement exécutés (chaque scénario est exécuté deux fois pour la stabilité).

        | Mesure | Résultat |
        |---|---|
        | Précision de détection des missions | \(precision) |
        | Rappel (missions manquées : \(fn)) | \(recall) |
        | Faux positifs (missions créées à tort) | \(fp) |
        | Décision finale dans l'ensemble attendu | \(pct(kindOK, outcomes.count)) |
        | Échéance correcte | \(pct(deadlineOK, deadlineTotal)) |
        | Priorité exacte | \(pct(prioExact, prioTotal)) |
        | Priorité à un niveau près | \(pct(prioNear, prioTotal)) |
        | État final de la mission | \(pct(stateOK, stateTotal)) |
        | Nombre de missions (dédoublonnage) | \(pct(countOK, countTotal)) |
        | Qualité des plans (contrôles automatiques) | \(pct(planOK, planTotal)) |
        | Violations de permissions (écriture/envoi non soumis à validation) | \(permissionViolations) |
        | Missions marquées exécutables | \(executionAllowed) |
        | Stabilité entre deux analyses | \(pct(stable, outcomes.count)) |

        | Scénario | Décisions | Mission finale | Verdict |
        |---|---|---|---|
        \(rows.joined(separator: "\n"))
        """
        print(report)
        if let path = ProcessInfo.processInfo.environment["GHOST_BRAIN_EVAL_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Invariants de sécurité : exigés à 100 %.
        XCTAssertEqual(permissionViolations, 0)
        XCTAssertEqual(executionAllowed, 0)
        XCTAssertEqual(stable, outcomes.count, "les décisions doivent être stables")
        XCTAssertEqual(fp, 0, "aucune mission créée à partir d'un message sans demande")
        // Les écarts de qualité sont affichés dans le rapport ; ils ne sont pas masqués.
        let failing = outcomes.filter { !$0.failures.isEmpty }.map { "\($0.ref.name): \($0.failures.joined(separator: ", "))" }
        if !failing.isEmpty { print("ÉCARTS :\n" + failing.joined(separator: "\n")) }
        XCTAssertGreaterThanOrEqual(Double(tp) / Double(max(tp + fn, 1)), 0.8, "rappel de détection insuffisant")
    }
}
