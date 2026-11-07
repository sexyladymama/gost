import Foundation
import GhostBrain

/// Fournisseur d'IA de la passerelle commune : le modèle embarqué de GHOST. Tourne sur ce Mac, sans clé ni réseau.
public final class LocalOpenModelProvider: ModelProvider, @unchecked Sendable {
    public let id = "ghost-local"
    public var model: String { LocalModelStore.modelID }
    public let isSimulated = false
    public let isLocal = true
    public var capabilities: Set<ModelCapability> { [.text, .structuredProtocol, .multiTurnProtocol] }

    private let store: LocalModelStore
    private let lock = NSLock()
    private var engine: LocalLlamaEngine?
    private let contextSize: Int
    private var idleTask: Task<Void, Never>?
    /// Le modèle occupe ≈ 5 Go : il est libéré après cette durée sans demande (rechargé à la demande suivante).
    public var idleSeconds: Double = 180

    public init(store: LocalModelStore, contextSize: Int = 6144) { self.store = store; self.contextSize = contextSize }

    public func availability() async -> String? {
        store.isInstalled ? nil : "L'IA de GHOST n'est pas téléchargée (Objectifs ▸ IA de GHOST, \(LocalModelStore.totalBytes / 1_000_000_000) Go)."
    }

    /// Libère la mémoire (≈ 5 Go) ; le modèle est rechargé à la demande suivante.
    public func unload() { lock.withLock { engine = nil; idleTask?.cancel(); idleTask = nil } }

    private func scheduleIdleUnload() {
        let delay = idleSeconds
        lock.withLock {
            idleTask?.cancel()
            idleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.unload()
            }
        }
    }

    private func loadedEngine() throws -> LocalLlamaEngine {
        try lock.withLock {
            if let engine { return engine }
            guard store.isInstalled else { throw LocalLLMError.notInstalled }
            let created = try LocalLlamaEngine(modelPath: store.modelPath, contextSize: contextSize)
            engine = created; return created
        }
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                let engine = try loadedEngine()
                defer { scheduleIdleUnload() }
                let grammar = request.task == .agentStep ? AgentGrammar.gbnf(tools: AgentGrammar.toolNames(in: request.system), actions: AgentGrammar.actions(in: request.system)) : nil
                let output = try engine.generate(prompt: LocalLlamaEngine.chatPrompt(system: request.system, user: request.user), grammar: grammar,
                                                 maxTokens: min(request.maxOutputTokens, 2_048), temperature: grammar == nil ? 0.4 : 0.1, shouldStop: { cancelled.value })
                return ModelResponse(text: output.text.trimmingCharacters(in: .whitespacesAndNewlines), provider: id, model: model,
                                     usage: ModelUsage(inputTokens: output.promptTokens, outputTokens: output.outputTokens), isSimulated: false)
            }.value
        } onCancel: { cancelled.set() }
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
