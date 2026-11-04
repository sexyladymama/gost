import Foundation
import GhostPerception

// MARK: - Contrat commun

public enum ModelTask: String, Codable, Sendable { case refineAmbiguity }

public struct ModelRequest: Sendable {
    public var task: ModelTask
    public var system: String
    public var user: String
    public var maxOutputTokens: Int
    public var requestID: UUID
    public init(task: ModelTask, system: String, user: String, maxOutputTokens: Int = 400, requestID: UUID = UUID()) {
        self.task = task; self.system = system; self.user = user
        self.maxOutputTokens = maxOutputTokens; self.requestID = requestID
    }
}

public struct ModelUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public struct ModelResponse: Sendable {
    public var text: String
    public var provider: String
    public var model: String
    public var usage: ModelUsage
    public var isSimulated: Bool
    public init(text: String, provider: String, model: String, usage: ModelUsage, isSimulated: Bool) {
        self.text = text; self.provider = provider; self.model = model; self.usage = usage; self.isSimulated = isSimulated
    }
}

public enum ModelError: Error, LocalizedError, Sendable, Equatable {
    case disabled, budgetExceeded(String), timeout, providerFailed(String), noProvider
    public var errorDescription: String? {
        switch self {
        case .disabled: return "Modèle externe désactivé."
        case .budgetExceeded(let s): return "Limite atteinte : \(s)."
        case .timeout: return "Le modèle n'a pas répondu à temps."
        case .providerFailed(let s): return "Fournisseur de modèle : \(s)"
        case .noProvider: return "Aucun fournisseur de modèle disponible."
        }
    }
}

/// Un fournisseur de modèle. Le choix du fournisseur est séparé de la logique
/// décisionnelle : le Brain ne connaît que ce protocole.
public protocol ModelProvider: Sendable {
    var id: String { get }
    var model: String { get }
    /// `true` si les réponses sont produites localement par des règles (jamais par un vrai modèle).
    var isSimulated: Bool { get }
    func complete(_ request: ModelRequest) async throws -> ModelResponse
}

public struct GatewayPolicy: Sendable {
    public var enabled: Bool
    public var timeout: TimeInterval
    public var maxCallsPerDay: Int
    public var maxTokensPerDay: Int
    public init(enabled: Bool = false, timeout: TimeInterval = 20, maxCallsPerDay: Int = 200, maxTokensPerDay: Int = 200_000) {
        self.enabled = enabled; self.timeout = timeout
        self.maxCallsPerDay = maxCallsPerDay; self.maxTokensPerDay = maxTokensPerDay
    }
}

/// Entrée de journal **technique** : jamais de contenu, jamais de données personnelles.
public struct ModelCallLog: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var provider: String
    public var model: String
    public var task: ModelTask
    public var usage: ModelUsage?
    public var latencyMs: Int
    public var outcome: String
}

/// Passerelle vers les modèles : fournisseurs ordonnés (repli), délai, plafonds
/// de coût (appels et jetons par jour), journal technique.
public actor ModelGateway {
    private var providers: [ModelProvider]
    public private(set) var policy: GatewayPolicy
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    public private(set) var callLog: [ModelCallLog] = []
    private var dayKey = ""
    private var callsToday = 0
    private var tokensToday = 0

    public init(providers: [ModelProvider], policy: GatewayPolicy = GatewayPolicy(),
                calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers; self.policy = policy; self.calendar = calendar; self.clock = clock
    }

    public func setPolicy(_ policy: GatewayPolicy) { self.policy = policy }
    public func setProviders(_ providers: [ModelProvider]) { self.providers = providers }
    public var isAvailable: Bool { policy.enabled && !providers.isEmpty }
    public var providerSummary: String { providers.map { $0.id + ($0.isSimulated ? " (simulé)" : "") }.joined(separator: " → ") }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        guard policy.enabled else { throw ModelError.disabled }
        guard !providers.isEmpty else { throw ModelError.noProvider }
        rollDay()
        guard callsToday < policy.maxCallsPerDay else { throw ModelError.budgetExceeded("appels quotidiens") }
        guard tokensToday < policy.maxTokensPerDay else { throw ModelError.budgetExceeded("jetons quotidiens") }
        var lastError: Error = ModelError.noProvider
        for provider in providers {
            let start = clock()
            do {
                let response = try await withTimeout(policy.timeout) { try await provider.complete(request) }
                callsToday += 1
                tokensToday += response.usage.inputTokens + response.usage.outputTokens
                record(provider, request, usage: response.usage, since: start, outcome: "ok")
                return response
            } catch {
                callsToday += 1
                record(provider, request, usage: nil, since: start, outcome: Self.outcome(error))
                lastError = error
                continue   // stratégie de repli : fournisseur suivant
            }
        }
        throw lastError
    }

    private static func outcome(_ error: Error) -> String {
        if let e = error as? ModelError {
            switch e {
            case .timeout: return "timeout"
            case .providerFailed: return "provider-error"
            default: return "error"
            }
        }
        return (error as? PerceptionError) != nil ? "network-denied" : "error"
    }

    private func rollDay() {
        let c = calendar.dateComponents([.year, .month, .day], from: clock())
        let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        if key != dayKey { dayKey = key; callsToday = 0; tokensToday = 0 }
    }

    private func record(_ p: ModelProvider, _ r: ModelRequest, usage: ModelUsage?, since: Date, outcome: String) {
        callLog.append(ModelCallLog(id: r.requestID, date: since, provider: p.id, model: p.model, task: r.task, usage: usage,
                                    latencyMs: Int(clock().timeIntervalSince(since) * 1000), outcome: outcome))
        if callLog.count > 500 { callLog.removeFirst(callLog.count - 500) }
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000))
                throw ModelError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ModelError.timeout }
            return first
        }
    }
}

// MARK: - Anthropic (fournisseur réel)

/// Fournisseur réel : API Messages d'Anthropic. La clé est lue dans le Trousseau,
/// la requête passe par le client filtré (hôte `api.anthropic.com`, autorisation
/// `callExternalModel` exigée) et ne contient que des données **masquées**.
public struct AnthropicProvider: ModelProvider {
    public static let host = "api.anthropic.com"
    public static let secretKey = "anthropic.api-key"
    public static let purpose = SourceID("brain")

    public let id = "anthropic"
    public let model: String
    public let isSimulated = false
    private let http: HTTPClient
    private let secrets: SecretStore

    public init(http: HTTPClient, secrets: SecretStore, model: String = "claude-haiku-5-5") {
        self.http = http; self.secrets = secrets; self.model = model
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        guard let keyData = try? secrets.load(Self.secretKey), let key = String(data: keyData, encoding: .utf8), !key.isEmpty else {
            throw ModelError.providerFailed("clé API absente")
        }
        let body: [String: Any] = [
            "model": model, "max_tokens": request.maxOutputTokens, "system": request.system,
            "messages": [["role": "user", "content": request.user]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw ModelError.providerFailed("requête invalide") }
        let http = HTTPRequest(method: "POST", url: URL(string: "https://\(Self.host)/v1/messages")!,
                               headers: ["x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"],
                               body: data, purpose: Self.purpose)
        let response = try await self.http.send(http)
        switch response.status {
        case 200: break
        case 401, 403: throw ModelError.providerFailed("clé API refusée")
        case 429: throw ModelError.providerFailed("limite de débit du fournisseur")
        default: throw ModelError.providerFailed("statut HTTP \(response.status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first else {
            throw ModelError.providerFailed("réponse illisible")
        }
        let usage = json["usage"] as? [String: Any]
        return ModelResponse(text: text, provider: id, model: model,
                             usage: ModelUsage(inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0),
                             isSimulated: false)
    }
}

// MARK: - Simulé (tests et développement uniquement)

/// **SIMULÉ** : produit des avis par règles locales, sans aucun modèle. Sert aux
/// tests déterministes ; ne doit jamais être présenté comme une vraie IA.
public struct SimulatedModelProvider: ModelProvider {
    public let id = "simulated"
    public let model = "règles-locales"
    public let isSimulated = true
    private let handler: @Sendable (ModelRequest) async throws -> String

    public init(handler: @escaping @Sendable (ModelRequest) async throws -> String = SimulatedModelProvider.defaultHandler) {
        self.handler = handler
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let text = try await handler(request)
        return ModelResponse(text: text, provider: id, model: model,
                             usage: ModelUsage(inputTokens: request.user.count / 4, outputTokens: text.count / 4), isSimulated: true)
    }

    /// Avis prudent : confirme l'ambiguïté lorsque le texte est vague.
    public static let defaultHandler: @Sendable (ModelRequest) async throws -> String = { request in
        let t = request.user.lowercased()
        let vague = ["prochainement", "ça", "ca ", "un de ces jours", "à l'occasion", "bientôt"].contains { t.contains($0) }
        let verdict = vague ? "monitor" : "create_mission"
        return "{\"verdict\":\"\(verdict)\",\"confidence\":0.8,\"reason\":\"Avis simulé par règles locales.\"}"
    }
}

// MARK: - Masquage des données personnelles

/// Retire des textes envoyés à un modèle externe : adresses e-mail, numéros,
/// liens, et les noms de personnes connus de l'événement.
enum PromptRedactor {
    static func redact(_ text: String, names: [String]) -> String {
        var out = text
        for name in names.sorted(by: { $0.count > $1.count }) where name.count > 1 {
            out = out.replacingOccurrences(of: name, with: "[personne]", options: .caseInsensitive)
        }
        let patterns: [(String, String)] = [
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
            (#"https?://\S+"#, "[lien]"),
            (#"\+?\d[\d .\-]{7,}\d"#, "[numéro]")
        ]
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }
}
