import Foundation
import llama

public enum LocalLLMError: Error, LocalizedError, Sendable {
    case notInstalled, loadFailed(String), tokenization, decode(Int32), tooLong(Int, Int), cancelled
    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "L'IA de GHOST n'est pas téléchargée."
        case .loadFailed(let s): return "Chargement de l'IA impossible : \(s)"
        case .tokenization: return "Texte impossible à découper pour l'IA."
        case .decode(let code): return "Erreur de calcul de l'IA (code \(code))."
        case .tooLong(let n, let limit): return "Demande trop longue pour l'IA locale (\(n) jetons, limite \(limit))."
        case .cancelled: return "Génération annulée."
        }
    }
}

/// Exécute un modèle GGUF avec llama.cpp (Metal sur Apple Silicon). Une génération à la fois ; chaque génération repart d'un contexte vide
/// (aucune conversation n'est conservée entre deux demandes). Les appels sont bloquants : utilisez-les hors du thread principal.
public final class LocalLlamaEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    public let contextSize: Int
    private static let backend: Void = {
        llama_backend_init()
        // Les journaux internes de llama.cpp (plusieurs milliers de lignes au chargement) ne sont pas conservés.
        if ProcessInfo.processInfo.environment["GHOST_LLM_VERBOSE"] == nil { llama_log_set({ _, _, _ in }, nil) }
    }()

    public init(modelPath: String, contextSize: Int = 8192) throws {
        _ = Self.backend
        self.contextSize = contextSize
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(modelPath, modelParams) else { throw LocalLLMError.loadFailed("fichier de modèle illisible ou incompatible") }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = 1024
        contextParams.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        contextParams.n_threads_batch = contextParams.n_threads
        guard let created = llama_init_from_model(loaded, contextParams) else { llama_model_free(loaded); throw LocalLLMError.loadFailed("mémoire insuffisante pour le contexte") }
        model = loaded; context = created
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    public struct Output: Sendable { public var text: String; public var promptTokens: Int; public var outputTokens: Int }

    /// `prompt` est déjà au format de conversation du modèle (voir `chatPrompt`). Avec `grammar` (GBNF), la sortie respecte la grammaire par construction.
    public func generate(prompt: String, grammar: String?, maxTokens: Int, temperature: Float = 0.2, shouldStop: @Sendable () -> Bool = { false }) throws -> Output {
        try lock.withLock {
            guard let model, let context, let vocab = llama_model_get_vocab(model) else { throw LocalLLMError.notInstalled }
            llama_memory_clear(llama_get_memory(context), true)

            var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
            let count = Int(llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true))
            guard count > 0 else { throw LocalLLMError.tokenization }
            guard count + maxTokens <= contextSize else { throw LocalLLMError.tooLong(count + maxTokens, contextSize) }
            tokens = Array(tokens.prefix(count))

            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
            defer { llama_sampler_free(sampler) }
            if let grammar, let g = llama_sampler_init_grammar(vocab, grammar, "root") { llama_sampler_chain_add(sampler, g) }
            if temperature > 0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
                llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
                llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
            } else {
                llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            }

            // Lecture du prompt par paquets.
            var offset = 0
            while offset < tokens.count {
                if shouldStop() { throw LocalLLMError.cancelled }
                let n = min(1024, tokens.count - offset)
                let status = tokens.withUnsafeMutableBufferPointer { buffer in
                    llama_decode(context, llama_batch_get_one(buffer.baseAddress! + offset, Int32(n)))
                }
                guard status == 0 else { throw LocalLLMError.decode(status) }
                offset += n
            }

            let began = Date()
            var bytes: [UInt8] = []
            var produced = 0
            var piece = [CChar](repeating: 0, count: 256)
            while produced < maxTokens {
                if shouldStop() { throw LocalLLMError.cancelled }
                var token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }
                let length = Int(llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false))
                if length > 0 { bytes += piece.prefix(length).map { UInt8(bitPattern: $0) } }
                produced += 1
                let status = llama_decode(context, llama_batch_get_one(&token, 1))
                guard status == 0 else { throw LocalLLMError.decode(status) }
            }
            if ProcessInfo.processInfo.environment["GHOST_LLM_DEBUG"] != nil {
                FileHandle.standardError.write(Data("LLM prompt=\(count) jetons, sortie=\(produced) jetons en \(String(format: "%.1f", Date().timeIntervalSince(began))) s (après lecture du prompt)\n".utf8))
            }
            return Output(text: String(decoding: bytes, as: UTF8.self), promptTokens: count, outputTokens: produced)
        }
    }

    /// Format de conversation ChatML (Qwen 2.5).
    public static func chatPrompt(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
    }
}
