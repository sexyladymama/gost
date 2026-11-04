import Foundation

public enum ContextRetrieval {
    public static func timeline(projectID: String, graph: ContextSnapshot) -> [ContextNode] {
        guard let summary = summary(projectID: projectID, graph: graph) else { return [] }
        return (summary.events + summary.decisions + summary.deadlines).sorted {
            let left = $0.occurredAt ?? $0.createdAt, right = $1.occurredAt ?? $1.createdAt
            return left == right ? $0.createdAt < $1.createdAt : left < right
        }
    }
    public static func summary(projectID: String, graph: ContextSnapshot) -> ContextProjectSummary? {
        guard let project = graph.nodes[projectID], project.kind == .project else { return nil }
        let associated = graph.relations.values.filter { $0.to == projectID }.compactMap { graph.nodes[$0.from] }
        let events = associated.filter { $0.kind == .event }
        let tasks = associated.filter { $0.kind == .taskCandidate }
        let eventIDs = Set(events.map(\.id)), taskIDs = Set(tasks.map(\.id))
        let refs = graph.relations.values.filter { $0.kind == .eventReferencesDocument && eventIDs.contains($0.from) }.compactMap { graph.nodes[$0.to] }
        let docs = Dictionary((associated.filter { $0.kind == .document } + refs).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.title < $1.title }
        let deadlines = graph.relations.values.filter { $0.kind == .taskHasDeadline && taskIDs.contains($0.from) }.compactMap { graph.nodes[$0.to] }
        var ambiguities = events.compactMap { $0.properties["ambiguity"] } + docs.compactMap { $0.properties["ambiguity"] }
        for task in tasks {
            let taskDates = graph.relations.values.filter { $0.kind == .taskHasDeadline && $0.from == task.id }.compactMap { graph.nodes[$0.to]?.occurredAt }
            if Set(taskDates).count > 1 { ambiguities.append("Plusieurs échéances conservées pour « \(task.title) » ; les anciennes assertions restent consultables.") }
        }
        let ordered = deadlines.sorted {
            let a = Double($0.properties["assertedAt"] ?? "") ?? 0, b = Double($1.properties["assertedAt"] ?? "") ?? 0
            return a == b ? $0.updatedAt > $1.updatedAt : a > b
        }
        var latest = ordered.first
        if let first = ordered.first {
            let ties = ordered.filter { $0.properties["assertedAt"] == first.properties["assertedAt"] }
            if Set(ties.compactMap(\.occurredAt)).count > 1 { latest = nil; ambiguities.append("Les dernières échéances sont simultanées et contradictoires.") }
        }
        var missing: [String] = []
        if project.status != .confirmed { missing.append("Périmètre du projet à confirmer.") }
        for task in tasks {
            if (task.properties["output"] ?? "").isEmpty { missing.append("Livrable à préciser pour « \(task.title) ».") }
            if !graph.relations.values.contains(where: { $0.kind == .taskHasDeadline && $0.from == task.id }) { missing.append("Échéance inconnue pour « \(task.title) ».") }
        }
        if docs.isEmpty { missing.append("Aucun document associé avec suffisamment d'indices.") }
        return ContextProjectSummary(project: project, events: events, documents: docs,
            people: associated.filter { $0.kind == .person }, tasks: tasks,
            decisions: associated.filter { $0.kind == .decision }, deadlines: deadlines,
            latestDeadline: latest, ambiguities: Array(Set(ambiguities)).sorted(), missingInformation: missing)
    }
}
