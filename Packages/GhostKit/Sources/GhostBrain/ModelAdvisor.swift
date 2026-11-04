import Foundation
import GhostPerception

struct ModelOpinion: Codable {
    var verdict: String
    var confidence: Double
    var reason: String
    var missing: [String]?
}

/// Cadre l'usage du modèle : il **propose** un avis structuré sur les seuls cas
/// ambigus ; le code déterministe valide, plafonne et décide. Le modèle ne peut ni
/// créer une mission à partir d'un message jugé informatif, ni toucher aux permissions.
enum ModelAdvisor {
    static let allowed: Set<String> = ["create_mission", "monitor", "clarify", "ignore"]

    static func isAmbiguous(_ outcome: DecisionOutcome, input: BrainInput) -> Bool {
        let e = input.event
        let actionable = e.tags.contains(.request) || e.tags.contains(.task) || e.tags.contains(.followUp)
        guard actionable, !input.signals.isAutomated else { return false }
        switch outcome.kind {
        case .monitor, .clarify: return true
        case .createMission: return outcome.confidence < input.config.firmThreshold
        default: return false
        }
    }

    static let system = """
    You help a personal assistant decide whether a message needs a task. Answer with ONE JSON object only, no prose:
    {"verdict":"create_mission|monitor|clarify|ignore","confidence":0..1,"reason":"<one sentence, max 200 chars>","missing":["<what is missing>"]}
    - create_mission: a clear request with an expected result addressed to the user.
    - clarify: a real request but an essential detail is missing.
    - monitor: a possible but vague intention.
    - ignore: no action needed.
    Never invent facts. Personal data is masked as [personne], [email], [lien], [numéro].
    """

    static func request(input: BrainInput, outcome: DecisionOutcome) -> ModelRequest {
        let e = input.event
        let names = e.people.compactMap { $0.name } + e.people.compactMap { $0.email }
        func mask(_ s: String) -> String { PromptRedactor.redact(s, names: names) }
        let payload: [String: Any] = [
            "title": mask(e.title), "summary": mask(e.summary), "kind": e.kind.rawValue,
            "expectedAction": mask(e.expectedAction ?? ""), "expectedOutput": e.expectedOutput ?? "",
            "hasDeadline": e.deadline != nil, "rulesDecision": outcome.kind.rawValue,
            "rulesReasons": outcome.reasons.map(mask)
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return ModelRequest(task: .refineAmbiguity, system: system, user: String(data: data, encoding: .utf8) ?? "{}")
    }

    /// Validation stricte : tout ce qui n'est pas exactement conforme est rejeté.
    static func parse(_ text: String) -> ModelOpinion? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let opinion = try? JSONDecoder().decode(ModelOpinion.self, from: data),
              allowed.contains(opinion.verdict), (0...1).contains(opinion.confidence),
              opinion.reason.count <= 400, (opinion.missing ?? []).count <= 5 else { return nil }
        return opinion
    }

    static func reconcile(_ outcome: DecisionOutcome, opinion: ModelOpinion, input: BrainInput,
                          provider: String, simulated: Bool) -> DecisionOutcome {
        var out = outcome
        out.reasons.append("Avis du modèle \(provider)\(simulated ? " (SIMULÉ)" : "") : \(opinion.verdict), confiance \(Int(opinion.confidence * 100)) % — \(opinion.reason)")
        switch (outcome.kind, opinion.verdict) {
        case (.monitor, "clarify"), (.monitor, "create_mission"):
            // Plafond : depuis une simple surveillance, le modèle peut au mieux demander une clarification.
            guard opinion.confidence >= 0.75, input.event.isMissionCandidate, out.goal != nil, out.analysis != nil else {
                out.uncertainties.append("Le modèle suggère une mission, mais ni sa confiance ni le contexte ne suffisent à en créer une.")
                return out
            }
            let question = opinion.missing?.first.map { "Pouvez-vous préciser : \($0) ?" } ?? out.clarification ?? "Que faut-il faire exactement, et pour quand ?"
            let item = MissingItem(text: opinion.missing?.first ?? "Résultat attendu à préciser", severity: .clarify)
            out.analysis?.missing.append(item)
            out.goal?.missingInfo.append(item.text)
            out.kind = .clarify; out.initialState = .needsClarification; out.clarification = question; out.watch = nil
            out.confidence = max(out.confidence, opinion.confidence * 0.8)
        case (.monitor, "ignore"):
            guard opinion.confidence >= 0.8 else { return out }
            out.kind = .ignore; out.watch = nil
        case (.clarify, "monitor"), (.clarify, "ignore"), (.createMission, "monitor"), (.createMission, "ignore"):
            guard opinion.confidence >= 0.8 else { return out }
            out.kind = .monitor; out.initialState = nil
            out.watch = DecisionEngine.makeWatch(input, reason: "avis du modèle : demande trop incertaine",
                                                 question: out.clarification ?? "Que faut-il faire exactement, et pour quand ?")
        default: break
        }
        return out
    }
}
