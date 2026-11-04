import Foundation
import GhostPerception

public enum ContextUpdate: Sendable { case snapshot(ContextSnapshot), issue(String) }

/// Sérialise l'analyse, les corrections et les transactions ; ne lit aucune nouvelle source.
public actor ContextEngine: PerceptionEventConsumer {
    public nonisolated let updates: AsyncStream<ContextUpdate>
    private let continuation: AsyncStream<ContextUpdate>.Continuation
    private let profileID: String
    private let databaseURL: URL?
    private let trust: TrustEngine
    private var database: ContextDatabase?
    private var state: ContextSnapshot?
    public private(set) var lastError: String?

    public init(profile: GhostProfile, trust: TrustEngine, persistent: Bool = true) {
        profileID = profile.id
        databaseURL = persistent ? profile.directory.appendingPathComponent("context.sqlite") : nil
        self.trust = trust
        (updates, continuation) = AsyncStream.makeStream(of: ContextUpdate.self, bufferingPolicy: .bufferingNewest(20))
    }
    deinit { continuation.finish() }

    public func consume(_ events: [GhostEvent]) async {
        do { try await ingest(events) }
        catch { report(error) }
    }
    public func ingest(_ events: [GhostEvent]) async throws {
        try ensureLoaded()
        var permitted: [GhostEvent] = []
        for event in events {
            let permission: Permission = event.source.kind == .email ? .readMail : .watchFolder
            // Contrôle indépendant du fait que Perception a déjà vérifié la source.
            try await trust.require(event.source.id, permission, operation: "context.ingest", target: event.source.displayName)
            permitted.append(event)
        }
        // Rejeu idempotent : si tous les événements sont déjà connus, rien n'est écrit.
        let known = try snapshot()
        let fresh = permitted.filter {
            !ContextInference.knows($0, scope: known.scopes[$0.source.id.rawValue] ?? .unclassified, graph: known)
        }
        guard !fresh.isEmpty else { return }
        try mutate { graph in
            for event in fresh {
                let scope = graph.scopes[event.source.id.rawValue] ?? .unclassified
                ContextInference.ingest(event, scope: scope, graph: &graph)
            }
            ContextInference.reconcileDocuments(graph: &graph)
        }
    }
    public func snapshot() throws -> ContextSnapshot { try ensureLoaded(); return state! }
    public func search(_ query: String, domain: MemoryDomain? = nil, scope: ContextScope? = nil) throws -> [ContextNode] {
        try ensureLoaded()
        return try database!.search(query, domain: domain, scope: scope).compactMap { state!.nodes[$0] }
    }
    public func projectSummary(_ id: String) throws -> ContextProjectSummary? {
        ContextRetrieval.summary(projectID: id, graph: try snapshot())
    }
    public func timeline(_ id: String) throws -> [ContextNode] { ContextRetrieval.timeline(projectID: id, graph: try snapshot()) }

    /// La reclassification retire d'abord les données dérivées de cette source.
    /// Le contrôleur peut ensuite rejouer les événements encore autorisés.
    public func setScope(_ scope: ContextScope, for source: SourceID) throws {
        try mutate { graph in
            ContextInference.removeSource(source, graph: &graph)
            graph.scopes[source.rawValue] = scope
        }
    }
    public func sourceWasRevoked(_ source: SourceID, retainHistory: Bool) async throws {
        try mutate { graph in
            graph.scopes[source.rawValue] = nil
            if retainHistory { graph.retainedSources.insert(source.rawValue) }
            else {
                graph.retainedSources.remove(source.rawValue)
                ContextInference.removeSource(source, graph: &graph)
            }
        }
    }
    /// Après panne/reprise, aucune mémoire de source révoquée n'est conservée sans choix explicite.
    public func reconcilePermissions() async throws {
        let snapshot = try snapshot()
        let ids = Set(snapshot.nodes.values.flatMap(\.provenance).compactMap(\.sourceID))
        var removed: [SourceID] = []
        for id in ids where !snapshot.retainedSources.contains(id.rawValue) {
            if await trust.grant(for: id) == nil { removed.append(id) }
        }
        if !removed.isEmpty {
            try mutate { graph in for id in removed { ContextInference.removeSource(id, graph: &graph) } }
        }
    }
    public func deleteMemory() async throws {
        try ensureLoaded()
        let fresh = ContextSnapshot()
        try database!.save(fresh)
        state = fresh; lastError = nil
        continuation.yield(.snapshot(fresh))
    }
    /// Renommer/corriger une entité n'altère pas ses preuves d'origine.
    public func correctNode(_ id: String, title: String, status: KnowledgeStatus? = nil) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4_000 else { throw ContextError.invalid("Le texte doit contenir entre 1 et 4 000 caractères.") }
        try mutate { graph in
            guard var node = graph.nodes[id] else { throw ContextError.invalid("Information introuvable.") }
            node.title = clean; node.properties["userEdited"] = "true"
            node.updatedAt = Date()
            if let status { node.status = status; if status == .confirmed { node.confidence = 1 } }
            node.provenance.append(ContextProvenance(explanation: "Correction explicite de l'utilisateur.", isUserProvided: true))
            graph.nodes[id] = node
            graph.corrections.append(ContextCorrection(targetID: id, action: "information corrigée", date: node.updatedAt))
        }
    }
    public func confirmRelation(_ id: String) throws {
        try mutate { graph in
            guard var edge = graph.relations[id] else { throw ContextError.invalid("Relation introuvable.") }
            edge.status = .confirmed; edge.confidence = 1; edge.userCorrected = true
            edge.lastConfirmedAt = Date(); edge.lastSupportedAt = Date()
            edge.provenance.append(ContextProvenance(explanation: "Relation confirmée explicitement par l'utilisateur.", isUserProvided: true))
            graph.relations[id] = edge
            graph.corrections.append(ContextCorrection(targetID: id, action: "relation confirmée", date: Date()))
        }
    }
    public func rejectRelation(_ id: String) throws {
        try mutate { graph in
            graph.relations[id] = nil
            graph.suppressedRelations.insert(id)
            graph.corrections.removeAll { $0.targetID == id }
        }
    }
    public func correctRelation(_ id: String, targetID: String) throws {
        try mutate { graph in
            guard let old = graph.relations[id], let source = graph.nodes[old.from],
                  let target = graph.nodes[targetID], source.namespace == target.namespace,
                  graph.nodes[old.to]?.kind == target.kind else { throw ContextError.invalid("La cible doit être du même type et du même contexte.") }
            graph.relations[id] = nil; graph.suppressedRelations.insert(id)
            let proof = ContextProvenance(explanation: "Association corrigée explicitement par l'utilisateur.", isUserProvided: true)
            ContextInference.edge(old.kind, old.from, targetID, status: .confirmed, confidence: 1, proof: proof, graph: &graph)
        }
    }
    public func setTaskStatus(_ id: String, status: String) throws {
        guard ["pending", "reviewed", "dismissed"].contains(status) else { throw ContextError.invalid("Statut de demande invalide.") }
        try mutate { graph in
            guard graph.nodes[id]?.kind == .taskCandidate else { throw ContextError.invalid("Demande introuvable.") }
            graph.nodes[id]?.properties["processingStatus"] = status
            graph.nodes[id]?.updatedAt = Date()
            graph.corrections.append(ContextCorrection(targetID: id, action: "demande : \(status)", date: Date()))
        }
    }
    @discardableResult
    public func remember(kind: ContextEntityKind, text: String, scope: ContextScope,
                         projectID: String? = nil) throws -> String {
        guard [.preference, .decision, .project, .person, .organization].contains(kind) else {
            throw ContextError.invalid("Ce type n'est pas une mémoire manuelle.")
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4_000, scope != .unclassified else {
            throw ContextError.invalid("Précisez un contexte personnel ou professionnel et un texte de 1 à 4 000 caractères.")
        }
        var created = ""
        try mutate { graph in
            var ns = ContextInference.namespace(scope: scope, source: SourceID("user"), simulated: false)
            var simulated = false
            if let projectID {
                guard let project = graph.nodes[projectID], project.kind == .project, project.scope == scope else {
                    throw ContextError.invalid("Projet et mémoire doivent appartenir au même contexte.")
                }
                ns = project.namespace; simulated = project.isSimulated
            }
            let proof = ContextProvenance(explanation: "Information fournie explicitement par l'utilisateur.", isUserProvided: true)
            created = ContextInference.node(kind, key: UUID().uuidString, title: clean, namespace: ns, scope: scope,
                simulated: simulated, status: .confirmed, confidence: 1, date: Date(), properties: ["userEdited": "true"], proof: proof, graph: &graph)
            if kind == .decision, let projectID {
                ContextInference.edge(.decisionBelongsToProject, created, projectID, status: .confirmed, confidence: 1, proof: proof, graph: &graph)
            }
        }
        return created
    }
    public func deleteNode(_ id: String) throws {
        try mutate { graph in
            guard let deleted = graph.nodes.removeValue(forKey: id) else { return }
            graph.suppressedNodes.insert(id)
            // Supprimer un événement supprime aussi ses contributions dérivées.
            if deleted.kind == .event, let event = deleted.properties["eventID"], let uuid = UUID(uuidString: event) {
                for key in Array(graph.nodes.keys) {
                    graph.nodes[key]?.provenance.removeAll { $0.eventID == uuid }
                    if graph.nodes[key]?.provenance.isEmpty == true { graph.nodes[key] = nil }
                }
                for key in Array(graph.relations.keys) { graph.relations[key]?.provenance.removeAll { $0.eventID == uuid } }
            }
            ContextInference.prune(graph: &graph)
        }
    }
    /// Réessai explicite après une erreur de stockage ; aucune remise à zéro.
    public func report(_ error: any Error) {
        lastError = error.localizedDescription; continuation.yield(.issue(error.localizedDescription))
    }
    private func ensureLoaded() throws {
        guard state == nil else { return }
        let db = try ContextDatabase(url: databaseURL, profileID: profileID)
        let loaded = try db.load()
        database = db; state = loaded
    }
    private func mutate(_ body: (inout ContextSnapshot) throws -> Void) throws {
        try ensureLoaded()
        var candidate = state!
        try body(&candidate)
        try database!.save(candidate)
        state = candidate; lastError = nil
        continuation.yield(.snapshot(candidate))
    }
}
