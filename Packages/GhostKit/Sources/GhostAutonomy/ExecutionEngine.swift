import Foundation
import GhostBrain
import GhostPerception

public enum ExecutionUpdate: Sendable { case archive(ExecutionArchive), issue(String) }

/// Ordonnanceur local. Chaque opération est bornée, contrôlée et checkpointée avant/après.
public actor ExecutionEngine: PerceptionEventConsumer {
    public nonisolated let updates: AsyncStream<ExecutionUpdate>
    private let continuation: AsyncStream<ExecutionUpdate>.Continuation
    public nonisolated let trust: ExecutionTrust
    private let tools: ToolEngine
    private let store: ExecutionStore
    private let brain: BrainEngine
    private let profileID: String
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UInt64] = [:]
    private var globallyPaused = true
    /// Capacités distinguées : seul le backend local existe ; le cloud est une interface préparée, indisponible.
    private let backends: [ExecutionBackend] = [LocalExecutionBackend(), CloudExecutionBackend()]
    // Point de test : un arrêt injecté reste une erreur, jamais un succès d'outil simulé.
    var afterTool: (@Sendable (ToolID) async throws -> Void)?
    func setAfterTool(_ hook: (@Sendable (ToolID) async throws -> Void)?) { afterTool = hook }

    public init(profile: GhostProfile, brain: BrainEngine, persistent: Bool = true) {
        profileID = profile.id; self.brain = brain
        trust = ExecutionTrust(); tools = ToolEngine(trust: trust)
        store = ExecutionStore(url: persistent ? profile.directory.appendingPathComponent("executions.json") : nil, profileID: profile.id)
        (updates, continuation) = AsyncStream.makeStream(of: ExecutionUpdate.self, bufferingPolicy: .bufferingNewest(30))
    }
    deinit { tasks.values.forEach { $0.cancel() }; continuation.finish() }
    public func snapshot() async throws -> ExecutionArchive { try await store.snapshot() }
    public func consume(_ events: [GhostEvent]) async {} // une perception n'autorise jamais une exécution

    public func recover() async throws {
        try await store.commit { archive in
            for id in Array(archive.executions.keys) {
                guard var context = archive.executions[id] else { continue }
                if [.running, .verifying, .authorized].contains(context.state) {
                    context.state = .paused
                    context.error = "Reprise après interruption : autorisez les dossiers puis reprenez explicitement."
                    context.history.append(ExecutionLog(message: "Checkpoint récupéré après interruption."))
                    archive.executions[id] = context
                }
            }
        }
        await publish()
    }
    @discardableResult
    public func prepare(missionID: String, declaredSensitive: Bool = false, capability: ExecutionCapability = .local) async throws -> String {
        // Local et cloud sont distingués dès la préparation : un backend indisponible refuse, sans repli silencieux.
        let backend = backends.first { $0.capability == capability }
        guard let backend, backend.isAvailable else {
            throw ExecutionError.denied(backend?.unavailableReason ?? "Aucun exécuteur pour cette capacité.")
        }
        let state = try await brain.snapshot()
        guard let mission = state.missions[missionID], mission.verdict == .confirmed, mission.state == .ready,
              mission.workKind == .produce, mission.goal.deliverable == "Fichier Excel", !mission.deadlineConflict,
              !mission.missingInfo.contains(where: { $0.severity != .minor }) else {
            throw ExecutionError.approval("Une mission Excel confirmée, prête et sans ambiguïté est nécessaire. Les autres missions restent au Brain.")
        }
        let binding = try ExecutionIdentity.binding(mission)
        let archive = try await store.snapshot()
        if let existing = archive.executions.values.first(where: { $0.mission.id == missionID && $0.binding == binding && $0.state != .cancelled }) { return existing.id }
        let id = UUID().uuidString.lowercased()
        let ids: [ToolID] = [.listAuthorizedFiles, .readAuthorizedFile, .createSpreadsheet, .saveArtifact, .verifyArtifact, .notifyUser]
        var steps: [ExecutionOperation] = []
        for (index, tool) in ids.enumerated() {
            steps.append(ExecutionOperation(id: id + ":" + tool.rawValue, tool: tool, dependsOn: index == 0 ? [] : [steps[index - 1].id]))
        }
        guard ids.allSatisfy(backend.supports) else { throw ExecutionError.denied("Un outil du plan n'est pas pris en charge par ce backend.") }
        var context = ExecutionContext(id: id, profileID: profileID, mission: mission, binding: binding, state: .pending,
                                       operations: steps, createdAt: Date(), updatedAt: Date())
        context.capability = capability
        context.declaredSensitive = declaredSensitive
        context.history.append(ExecutionLog(message: "Plan local dérivé du Brain : lecture CSV/TSV, création XLSX, vérification, notification. Validation et remise externe du plan initial restent hors périmètre."))
        try await store.commit { $0.executions[id] = context }
        await publish(); return id
    }
    public func authorize(_ id: String, input: URL, output: URL, allowReadContents: Bool, allowCreate: Bool) async throws {
        let context = try await context(id)
        guard !context.state.isTerminal else { throw ExecutionError.invalid("Exécution terminée.") }
        try await trust.authorize(executionID: id, namespace: context.mission.namespace, input: input, output: output,
                                  allowContentRead: allowReadContents, allowCreate: allowCreate)
        do {
            try await update(id) {
                $0.inputPath = input.path; $0.outputPath = output.path
                try Self.move(&$0, to: .authorized)
                $0.error = nil; $0.approval = nil
                $0.history.append(ExecutionLog(message: "Lecture du contenu et création de nouveaux fichiers autorisées pour ces deux dossiers uniquement."))
            }
        } catch { await trust.revoke(id); throw error }
        await publish()
    }
    public func start(_ id: String) async throws {
        guard !globallyPaused else { throw ExecutionError.denied("GHOST est en pause ou arrêté.") }
        let c = try await context(id)
        guard c.state == .authorized else { throw ExecutionError.approval("Autorisez de nouveau les dossiers avant de démarrer ou reprendre.") }
        guard tasks[id] == nil else { return }
        let token = generations[id, default: 0]
        tasks[id] = Task { [weak self] in await self?.run(id, token: token) }
    }
    /// Interface de test/CLI locale : attend l'achèvement d'une tâche déjà démarrée.
    public func waitForIdle(_ id: String) async { let task = tasks[id]; await task?.value }
    public func pause(_ id: String) async throws {
        let c = try await context(id); guard !c.state.isTerminal else { return }
        invalidate(id)
        try await update(id) { try Self.move(&$0, to: .paused); $0.history.append(ExecutionLog(message: "Pause demandée ; aucune opération suivante ne sera engagée.")) }
        await tellBrain(id, kind: "paused", "Exécution locale en pause")
        await publish()
    }
    public func cancel(_ id: String) async throws {
        let c = try await context(id); guard !c.state.isTerminal else { return }
        invalidate(id); await trust.revoke(id)
        try await update(id) { try Self.move(&$0, to: .cancelled); $0.history.append(ExecutionLog(message: "Exécution annulée. Les fichiers déjà créés restent en place.")) }
        await tellBrain(id, kind: "cancelled", "Exécution locale annulée par l'utilisateur ; les fichiers déjà créés restent en place")
        await publish()
    }
    public func setGlobalPaused(_ paused: Bool) async {
        globallyPaused = paused
        if paused, let archive = try? await store.snapshot() {
            for c in archive.executions.values where !c.state.isTerminal && c.state != .pending && c.state != .waitingForApproval {
                do { try await pause(c.id) } catch { report(error) }
            }
        }
    }
    public func approve(_ id: String) async throws {
        let c = try await context(id)
        guard c.state == .waitingForApproval else { throw ExecutionError.invalid("Aucune demande d'approbation.") }
        if c.approvalKind == "sensitive" {
            try await trust.approveSensitive(id, namespace: c.mission.namespace)
            try await update(id) { try Self.move(&$0, to: .authorized); $0.approval = nil; $0.approvalKind = nil }
        } else if c.approvalKind == "collision" {
            try await update(id) {
                $0.outputVersion += 1; $0.artifact = nil; $0.verification = nil
                for i in $0.operations.indices where [.saveArtifact, .verifyArtifact, .notifyUser].contains($0.operations[i].tool) { $0.operations[i].status = "pending"; $0.operations[i].attempts = 0 }
                try Self.move(&$0, to: .authorized); $0.approval = nil; $0.approvalKind = nil
                $0.history.append(ExecutionLog(message: "Nouvelle version de sortie approuvée ; aucun remplacement."))
            }
        } else { throw ExecutionError.approval("Ce blocage nécessite une correction des sources ou de la mission ; une approbation ne crée pas une capacité inexistante.") }
        await publish()
    }
    public func deny(_ id: String) async throws { try await cancel(id) }

    public func sourceWasRevoked(_ source: SourceID, retainHistory: Bool) async throws {
        let archive = try await store.snapshot()
        for c in archive.executions.values where c.mission.triggers.contains(where: { $0.sourceID == source.rawValue }) || c.mission.resources.contains(where: { $0.sourceID == source.rawValue }) {
            invalidate(c.id); await trust.revoke(c.id)
            try await store.commit {
                if retainHistory {
                    if !$0.executions[c.id]!.state.isTerminal { $0.executions[c.id]!.state = .paused }
                } else { $0.executions[c.id] = nil }
            }
        }
        await publish()
    }
    public func deleteMemory() async throws {
        let ids = Array(tasks.keys); ids.forEach { invalidate($0) }
        await trust.revokeAll()
        try await store.commit { $0.executions.removeAll() }
        await publish()
    }
    private func run(_ id: String, token: UInt64) async {
        defer { if generations[id, default: 0] == token { tasks[id] = nil } }
        do {
            try await requireCurrent(id, token: token)
            try await tools.validateInputs(try await context(id))
            try await update(id) { try Self.move(&$0, to: .running) }
            await publish()
            while let index = try await context(id).operations.firstIndex(where: { $0.status != "completed" }) {
                try await requireCurrent(id, token: token)
                var c = try await context(id)
                let operation = c.operations[index]
                guard operation.dependsOn.allSatisfy({ dependency in c.operations.contains { $0.id == dependency && $0.status == "completed" } }) else { throw ExecutionError.invalid("Dépendance d'opération non satisfaite.") }
                guard operation.attempts < 3 else { throw ExecutionError.invalid("Trois tentatives atteintes ; intervention nécessaire.") }
                try await update(id) {
                    $0.operations[index].status = "started"; $0.operations[index].attempts += 1
                    try Self.move(&$0, to: operation.tool == .verifyArtifact ? .verifying : .running)
                    $0.history.append(ExecutionLog(operationID: operation.id, message: "Début : \(operation.tool.rawValue)"))
                }
                c = try await context(id)
                let result: ToolResult
                do { result = try await tools.execute(operation.tool, context: c) }
                catch ExecutionError.transient where c.operations[index].attempts < 3 {
                    try await update(id) {
                        $0.operations[index].status = "pending"
                        $0.history.append(ExecutionLog(operationID: operation.id, message: "Erreur temporaire : nouvelle tentative bornée."))
                    }
                    continue
                }
                if let hook = afterTool { try await hook(operation.tool) }
                try await requireCurrent(id, token: token)
                if let report = result.verification, report.status != .passed {
                    try await update(id) { $0.verification = report }
                    throw ExecutionError.invalid("Vérification échouée : " + report.problems.joined(separator: "; "))
                }
                try await update(id) {
                    if operation.tool == .listAuthorizedFiles { $0.inputNames = result.files }
                    if operation.tool == .readAuthorizedFile { $0.inputs = result.inputs }
                    if operation.tool == .createSpreadsheet { $0.records = result.records; $0.stagedArtifact = result.data }
                    if let artifact = result.artifact { $0.artifact = artifact }
                    if let verification = result.verification { $0.verification = verification }
                    if let notification = result.notification { $0.notification = notification }
                    $0.operations[index].status = "completed"
                    $0.history.append(ExecutionLog(operationID: operation.id, message: "Terminé : \(operation.tool.rawValue)" + (result.artifact?.recovered == true ? " (fichier identique récupéré, sans réécriture)" : "")))
                }
                await publish()
            }
            try await requireCurrent(id, token: token)
            let c = try await context(id)
            guard c.verification?.status == .passed, let artifact = c.artifact else { throw ExecutionError.invalid("La mission ne peut pas terminer sans résultat vérifié.") }
            try await update(id) { try Self.move(&$0, to: .verifying) }
            try await brain.recordVerifiedLocalArtifact(missionID: c.mission.id, executionID: id, fileName: artifact.fileName,
                                                        hash: artifact.hash, verification: c.verification!.checks)
            try await requireCurrent(id, token: token)
            try await update(id) { $0.brainReported = true; try Self.move(&$0, to: .completed); $0.stagedArtifact = nil; $0.error = nil; $0.approval = nil }
            await publish()
        } catch {
            if generations[id, default: 0] != token || Task.isCancelled { return }
            do {
                try await update(id) { c in
                    c.error = error.localizedDescription
                    if case ExecutionError.approval = error {
                        c.approval = error.localizedDescription
                        let tool = c.operations.first { $0.status != "completed" }?.tool
                        c.approvalKind = tool == .saveArtifact ? "collision" : (c.declaredSensitive && tool == .listAuthorizedFiles ? "sensitive" : "review")
                        try Self.move(&c, to: .waitingForApproval)
                    } else if case ExecutionError.denied = error {
                        c.approval = error.localizedDescription; c.approvalKind = "permissions"
                        try Self.move(&c, to: .waitingForApproval)
                    } else { try Self.move(&c, to: .failed) }
                    c.history.append(ExecutionLog(message: "Arrêt : \(error.localizedDescription)"))
                }
                let kind: String
                if case ExecutionError.approval = error { kind = "approval" }
                else if case ExecutionError.denied = error { kind = "denied" } else { kind = "failed" }
                await tellBrain(id, kind: kind, "Exécution locale interrompue : \(error.localizedDescription)")
                await publish()
            } catch { report(error) }
        }
    }
    /// Retour au Brain : actions effectuées, erreurs, demandes d'approbation et étapes restantes (jamais d'état inventé :
    /// le Brain n'enregistre qu'une trace dans l'historique de la mission, sans changer son état).
    private func tellBrain(_ id: String, kind: String, _ message: String) async {
        guard let c = try? await context(id) else { return }
        let done = c.operations.filter { $0.status == "completed" }.map { $0.tool.rawValue }
        let remaining = c.operations.count - done.count
        let summary = "\(message). Opérations terminées : \(done.isEmpty ? "aucune" : done.joined(separator: ", ")) ; \(remaining) étape(s) restante(s) sur \(c.operations.count)."
        do { try await brain.recordExecutionEvent(missionID: c.mission.id, executionID: id, kind: kind, summary: summary) }
        catch { report(error) }
    }
    private func requireCurrent(_ id: String, token: UInt64) async throws {
        try Task.checkCancellation()
        guard !globallyPaused, generations[id, default: 0] == token else { throw ExecutionError.cancelled }
        let c = try await context(id)
        guard let current = try await brain.snapshot().missions[c.mission.id], current.isOpen,
              current.verdict == .confirmed, current.namespace == c.mission.namespace,
              try ExecutionIdentity.binding(current) == c.binding else { throw ExecutionError.approval("La mission a changé ou a été annulée : révision humaine requise.") }
        try Task.checkCancellation()
        guard !globallyPaused, generations[id, default: 0] == token else { throw ExecutionError.cancelled }
    }
    private func context(_ id: String) async throws -> ExecutionContext {
        guard let c = try await store.snapshot().executions[id] else { throw ExecutionError.invalid("Exécution introuvable.") }; return c
    }
    private func update(_ id: String, _ edit: (inout ExecutionContext) throws -> Void) async throws {
        try await store.commit { archive in
            guard var c = archive.executions[id] else { throw ExecutionError.invalid("Exécution introuvable.") }
            try edit(&c); c.updatedAt = Date(); archive.executions[id] = c
        }
    }
    private func invalidate(_ id: String) { generations[id, default: 0] &+= 1; tasks[id]?.cancel(); tasks[id] = nil }
    private static func move(_ c: inout ExecutionContext, to state: ExecutionState) throws {
        guard c.state.canMove(to: state) else { throw ExecutionError.invalid("Transition d'exécution invalide : \(c.state.rawValue) → \(state.rawValue).") }
        c.state = state
    }
    private func report(_ error: any Error) { continuation.yield(.issue(error.localizedDescription)) }
    private func publish() async { do { continuation.yield(.archive(try await store.snapshot())) } catch { report(error) } }
}
