import Foundation
import GhostPerception

/// Règles déterministes, appliquées à une copie du graphe avant transaction SQLite.
enum ContextInference {
    static func namespace(scope: ContextScope, source: SourceID, simulated: Bool) -> String {
        let boundary = scope == .unclassified ? "unclassified:\(source.rawValue)" : scope.rawValue
        return boundary + (simulated ? ":simulation" : ":real")
    }
    static func nodeID(_ kind: ContextEntityKind, key: String, namespace: String, graph: ContextSnapshot) -> String {
        ContextText.id(graph.salt + "|" + namespace + "|" + kind.rawValue + "|" + key)
    }
    /// `true` si cet événement a déjà été intégré (ou supprimé volontairement) dans ce graphe.
    static func knows(_ event: GhostEvent, scope: ContextScope, graph: ContextSnapshot) -> Bool {
        let ns = namespace(scope: scope, source: event.source.id, simulated: event.source.isSimulated)
        let id = nodeID(.event, key: event.source.id.rawValue + "|" + event.fingerprint, namespace: ns, graph: graph)
        return graph.nodes[id] != nil || graph.suppressedNodes.contains(id)
    }
    @discardableResult
    static func node(_ kind: ContextEntityKind, key: String, title: String, namespace: String,
                     scope: ContextScope, simulated: Bool, status: KnowledgeStatus, confidence: Double,
                     date: Date, occurredAt: Date? = nil, properties: [String: String] = [:],
                     proof: ContextProvenance, graph: inout ContextSnapshot) -> String {
        let id = nodeID(kind, key: key, namespace: namespace, graph: graph)
        guard !graph.suppressedNodes.contains(id) else { return id }
        if var old = graph.nodes[id] {
            if old.properties["userEdited"] != "true", date >= old.updatedAt {
                old.title = title
                old.properties.merge(properties) { _, new in new }
            }
            old.createdAt = min(old.createdAt, date); old.updatedAt = max(old.updatedAt, date)
            if !old.provenance.contains(where: { $0.eventID == proof.eventID && $0.sourceID == proof.sourceID && $0.explanation == proof.explanation }) {
                old.provenance.append(proof)
            }
            // La répétition ne transforme pas une hypothèse en fait.
            graph.nodes[id] = old
        } else {
            graph.nodes[id] = ContextNode(id: id, kind: kind, scope: scope, namespace: namespace,
                isSimulated: simulated, title: title, status: status, confidence: confidence,
                createdAt: date, updatedAt: date, occurredAt: occurredAt, properties: properties, provenance: [proof])
        }
        return id
    }
    static func edge(_ kind: ContextRelationKind, _ from: String, _ to: String,
                     status: KnowledgeStatus = .hypothesis, confidence: Double = 0.65,
                     proof: ContextProvenance, graph: inout ContextSnapshot) {
        guard let source = graph.nodes[from], let target = graph.nodes[to], source.namespace == target.namespace else { return }
        let id = ContextText.id(graph.salt + "|" + kind.rawValue + "|" + from + "|" + to)
        guard !graph.suppressedRelations.contains(id) else { return }
        if var old = graph.relations[id] {
            if !old.provenance.contains(where: { $0.eventID == proof.eventID && $0.sourceID == proof.sourceID && $0.explanation == proof.explanation }) { old.provenance.append(proof) }
            old.createdAt = min(old.createdAt, proof.recordedAt)
            old.lastSupportedAt = max(old.lastSupportedAt, proof.recordedAt)
            if old.status == .confirmed { old.lastConfirmedAt = max(old.lastConfirmedAt ?? proof.recordedAt, proof.recordedAt) }
            graph.relations[id] = old
        } else {
            graph.relations[id] = ContextRelation(id: id, kind: kind, from: from, to: to, status: status,
                confidence: confidence, createdAt: proof.recordedAt, lastSupportedAt: proof.recordedAt,
                lastConfirmedAt: status == .confirmed ? proof.recordedAt : nil, provenance: [proof], userCorrected: false)
        }
    }

    static func ingest(_ event: GhostEvent, scope: ContextScope, graph: inout ContextSnapshot) {
        let ns = namespace(scope: scope, source: event.source.id, simulated: event.source.isSimulated)
        let eventKey = event.source.id.rawValue + "|" + event.fingerprint
        let existingID = nodeID(.event, key: eventKey, namespace: ns, graph: graph)
        guard graph.nodes[existingID] == nil, !graph.suppressedNodes.contains(existingID) else { return }
        let proof = ContextProvenance(eventID: event.id, sourceID: event.source.id, fingerprint: event.fingerprint,
            explanation: "Événement structuré de la source autorisée « \(event.source.displayName) ».", recordedAt: event.detectedAt)
        var props = ["summary": event.summary, "sourceID": event.source.id.rawValue, "eventID": event.id.uuidString,
                     "sourceName": event.source.displayName, "kind": event.kind.rawValue]
        if let action = event.expectedAction { props["action"] = action }
        if let output = event.expectedOutput { props["output"] = output }
        let eventID = node(.event, key: eventKey, title: event.title, namespace: ns, scope: scope,
            simulated: event.source.isSimulated, status: .confirmed, confidence: 1, date: event.detectedAt,
            occurredAt: event.occurredAt, properties: props, proof: proof, graph: &graph)

        var persons: [String] = []
        for person in event.people {
            guard let email = person.email?.lowercased(), !email.isEmpty else { continue }
            let id = node(.person, key: email, title: person.displayName, namespace: ns, scope: scope,
                simulated: event.source.isSimulated, status: .confirmed, confidence: 1, date: event.detectedAt,
                properties: ["email": email], proof: proof, graph: &graph)
            persons.append(id)
            edge(.eventMentionsPerson, eventID, id, status: .confirmed, confidence: 1, proof: proof, graph: &graph)
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            let publicDomains = ["gmail.com", "outlook.com", "hotmail.com", "yahoo.com", "icloud.com", "ghost.test"]
            if !domain.isEmpty, !publicDomains.contains(domain) {
                var domainProof = proof; domainProof.explanation = "Domaine e-mail \(domain) ; ne prouve pas un emploi."
                let org = node(.organization, key: domain, title: domain, namespace: ns, scope: scope,
                    simulated: event.source.isSimulated, status: .hypothesis, confidence: 0.45, date: event.detectedAt,
                    proof: domainProof, graph: &graph)
                edge(.personAssociatedWithOrganization, id, org, confidence: 0.45, proof: domainProof, graph: &graph)
            }
        }
        var conversation: String?
        if event.source.kind == .email {
            let thread = event.metadata["thread"]
            let key = event.source.id.rawValue + "|" + (thread ?? eventKey)
            let id = node(.conversation, key: key, title: event.title, namespace: ns, scope: scope,
                simulated: event.source.isSimulated, status: .confirmed, confidence: 1, date: event.detectedAt,
                properties: ["thread": thread ?? "", "sourceID": event.source.id.rawValue], proof: proof, graph: &graph)
            conversation = id
            edge(.eventInConversation, eventID, id, status: .confirmed, confidence: 1, proof: proof, graph: &graph)
            for person in persons { edge(.conversationInvolvesPerson, id, person, status: .confirmed, confidence: 1, proof: proof, graph: &graph) }
        }
        let text = event.title + "\n" + event.summary + "\n" + (event.expectedAction ?? "")
        var projectNames = projectLabels(text)
        if let path = event.metadata["path"] { projectNames += projectLabels(path.replacingOccurrences(of: "/", with: "\n")) }
        projectNames = Array(Set(projectNames)).sorted()
        var projects: [String] = []
        for name in projectNames {
            var projectProof = proof; projectProof.explanation = "Marqueur explicite de projet « \(name) » ; association à confirmer."
            let id = node(.project, key: "label:" + ContextText.normalized(name), title: name, namespace: ns,
                scope: scope, simulated: event.source.isSimulated, status: .hypothesis, confidence: 0.8,
                date: event.detectedAt, properties: ["matchingName": ContextText.normalized(name)], proof: projectProof, graph: &graph)
            projects.append(id)
        }
        if projects.isEmpty, let conversation {
            projects = graph.relations.values.filter { $0.kind == .conversationRelatesToProject && $0.from == conversation }.map(\.to)
            if projects.isEmpty, event.isMissionCandidate, event.metadata["thread"] != nil {
                var p = proof; p.explanation = "Même identifiant de fil ; nom et périmètre du projet à préciser."
                projects = [node(.project, key: "thread:" + conversation, title: "Situation · " + event.title,
                    namespace: ns, scope: scope, simulated: event.source.isSimulated, status: .unknown, confidence: 0.4,
                    date: event.detectedAt, properties: ["needsName": "true"], proof: p, graph: &graph)]
            }
        }
        if projectNames.count > 1, var node = graph.nodes[eventID] {
            node.properties["ambiguity"] = "Plusieurs projets mentionnés ; aucune fusion automatique."
            graph.nodes[eventID] = node
        }
        for project in projects {
            var p = proof; p.explanation = "Mention de projet ou continuité du même fil ; relation déduite, à confirmer."
            edge(.eventRelatesToProject, eventID, project, confidence: 0.8, proof: p, graph: &graph)
            if let conversation { edge(.conversationRelatesToProject, conversation, project, confidence: 0.8, proof: p, graph: &graph) }
            for person in persons { edge(.personParticipatesInProject, person, project, proof: p, graph: &graph) }
        }
        if event.isMissionCandidate {
            let action = event.expectedAction ?? event.summary
            let key = (conversation ?? eventID) + "|" + ContextText.normalized(action)
            var p = proof; p.explanation = "Demande candidate issue des règles de Perception ; aucune exécution."
            let task = node(.taskCandidate, key: key, title: action, namespace: ns, scope: scope,
                simulated: event.source.isSimulated, status: .hypothesis, confidence: event.confidence, date: event.detectedAt,
                properties: ["processingStatus": "pending", "output": event.expectedOutput ?? ""], proof: p, graph: &graph)
            edge(.eventSuggestsTask, eventID, task, confidence: event.confidence, proof: p, graph: &graph)
            for project in projects { edge(.taskRelatesToProject, task, project, proof: p, graph: &graph) }
            if let deadline = event.deadline {
                var d = proof; d.explanation = "Échéance extraite : « \(deadline.text) » (\(deadline.precision.rawValue))."
                let id = node(.deadline, key: task + "|" + String(deadline.date.timeIntervalSince1970),
                    title: deadline.text, namespace: ns, scope: scope, simulated: event.source.isSimulated,
                    status: .hypothesis, confidence: event.confidence, date: event.detectedAt, occurredAt: deadline.date,
                    properties: ["precision": deadline.precision.rawValue, "assertedAt": String(event.occurredAt.timeIntervalSince1970)], proof: d, graph: &graph)
                edge(.taskHasDeadline, task, id, confidence: event.confidence, proof: d, graph: &graph)
            }
        }
        if event.kind == .documentEvent, let path = event.metadata["path"] {
            let key = event.source.id.rawValue + "|" + path
            let document = node(.document, key: key, title: event.title, namespace: ns, scope: scope,
                simulated: event.source.isSimulated, status: .confirmed, confidence: 1, date: event.detectedAt,
                occurredAt: event.occurredAt, properties: ["path": path, "availability": event.metadata["change"] == "deleted" ? "deleted" : "observed"],
                proof: proof, graph: &graph)
            edge(.eventReferencesDocument, eventID, document, status: .confirmed, confidence: 1, proof: proof, graph: &graph)
            for project in projects { edge(.documentBelongsToProject, document, project, proof: proof, graph: &graph) }
        }
    }

    /// Un nom de fichier doit désigner un seul projet/document dans la même frontière.
    static func reconcileDocuments(graph: inout ContextSnapshot) {
        let projects = graph.nodes.values.filter { $0.kind == .project && $0.properties["matchingName"] != nil }
        let documents = graph.nodes.values.filter { $0.kind == .document }
        for doc in documents {
            let text = " " + ContextText.normalized(doc.properties["path"] ?? doc.title) + " "
            let matching = projects.filter { $0.namespace == doc.namespace && text.contains(" " + ($0.properties["matchingName"] ?? "") + " ") }
            if matching.count == 1, let p = matching.first, let proof = doc.provenance.first {
                var evidence = proof; evidence.explanation = "Le chemin du document mentionne uniquement le projet « \(p.title) » ; association supposée."
                edge(.documentBelongsToProject, doc.id, p.id, proof: evidence, graph: &graph)
                let events = graph.relations.values.filter { $0.kind == .eventReferencesDocument && $0.to == doc.id }.map(\.from)
                for event in events { edge(.eventRelatesToProject, event, p.id, proof: evidence, graph: &graph) }
            } else if matching.count > 1 {
                graph.nodes[doc.id]?.properties["ambiguity"] = "Le chemin correspond à plusieurs projets ; association inconnue."
            }
        }
        for event in graph.nodes.values.filter({ $0.kind == .event }) {
            let text = (event.title + " " + (event.properties["summary"] ?? "") + " " + (event.properties["action"] ?? "")).lowercased()
            for name in Set(documents.filter { $0.namespace == event.namespace }.map { $0.title.lowercased() }) where text.contains(name) {
                let candidates = documents.filter { $0.namespace == event.namespace && $0.title.lowercased() == name }
                if candidates.count == 1, let doc = candidates.first, let proof = event.provenance.first {
                    var p = proof; p.explanation = "Nom exact du document cité ; un seul document connu porte ce nom."
                    edge(.eventReferencesDocument, event.id, doc.id, proof: p, graph: &graph)
                } else if candidates.count > 1 {
                    graph.nodes[event.id]?.properties["ambiguity"] = "Plusieurs documents portent le nom cité ; aucun choix automatique."
                }
            }
        }
    }

    private static func projectLabels(_ text: String) -> [String] {
        let patterns = [#"(?i)\[(?:projet|project)\s*[:\-]?\s*([^\]\r\n]{1,80})\]"#,
                        #"(?im)^(?:projet|project)\s*:\s*([^\r\n/]{1,80})$"#]
        var values: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { values.append(value) }
            }
        }
        return values
    }

    static func removeSource(_ id: SourceID, graph: inout ContextSnapshot) {
        for key in Array(graph.nodes.keys) {
            let hadSource = graph.nodes[key]?.provenance.contains { $0.sourceID == id } == true
            graph.nodes[key]?.provenance.removeAll { $0.sourceID == id }
            let otherSource = graph.nodes[key]?.provenance.contains { $0.sourceID != nil } == true
            if graph.nodes[key]?.provenance.isEmpty == true || (hadSource && !otherSource) { graph.nodes[key] = nil }
        }
        for key in Array(graph.relations.keys) {
            graph.relations[key]?.provenance.removeAll { $0.sourceID == id }
        }
        prune(graph: &graph)
    }
    static func prune(graph: inout ContextSnapshot) {
        graph.relations = graph.relations.filter { graph.nodes[$0.value.from] != nil && graph.nodes[$0.value.to] != nil && !$0.value.provenance.isEmpty }
        let ids = Set(graph.nodes.keys).union(graph.relations.keys)
        graph.corrections.removeAll { !ids.contains($0.targetID) }
    }
}
