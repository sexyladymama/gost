import Foundation
import GhostBrain
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum LanguageModelAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// Une intelligence capable de rédiger. GHOST en essaie plusieurs, **locale d'abord**.
public protocol LanguageModel: Sendable {
    var name: String { get }
    /// `true` : le texte ne quitte pas le Mac.
    var isLocal: Bool { get }
    /// `true` : réponses fabriquées par des règles (tests) ; jamais présenté comme une vraie IA.
    var isSimulated: Bool { get }
    func availability() async -> LanguageModelAvailability
    func generate(system: String, prompt: String) async throws -> String
}

/// Modèle de langage intégré à macOS 26 (Apple Intelligence). Fonctionne sur le Mac, sans clé ni réseau.
public struct OnDeviceLanguageModel: LanguageModel {
    public init() {}
    public var name: String { "Apple Intelligence (sur ce Mac)" }
    public var isLocal: Bool { true }
    public var isSimulated: Bool { false }

    public func availability() async -> LanguageModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence n'est pas activé : Réglages Système ▸ Apple Intelligence et Siri.")
                case .deviceNotEligible:
                    return .unavailable("Ce Mac n'est pas compatible avec Apple Intelligence.")
                case .modelNotReady:
                    return .unavailable("Le modèle d'Apple Intelligence est en cours de téléchargement.")
                @unknown default:
                    return .unavailable("Le modèle d'Apple Intelligence est indisponible.")
                }
            }
        }
        return .unavailable("macOS 26 est nécessaire pour le modèle intégré.")
        #else
        return .unavailable("Modèle intégré non disponible dans cette compilation.")
        #endif
    }

    public func generate(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw MindError.invalid("Modèle intégré indisponible.")
    }
}

#if canImport(FoundationModels)
/// Génération GUIDÉE (Apple) : la structure d'une décision d'agent est garantie par le système, pas par la bonne volonté du petit modèle.
@available(macOS 26.0, *)
@Generable
struct GuidedAgentStep {
    @Guide(description: "Type d'étape.", .anyOf(["tool_call", "create_plan", "clarification_required", "final_response", "blocked"]))
    var action: String
    @Guide(description: "La question posée, le résultat final ou la raison du blocage. Vide pour tool_call et create_plan.")
    var text: String
    @Guide(description: "Nom exact de l'outil à appeler quand action vaut tool_call ; vide sinon.")
    var tool: String
    @Guide(description: "Arguments de l'outil (nom et valeur texte).")
    var arguments: [GuidedArgument]
    @Guide(description: "Pourquoi cet outil, en une phrase.")
    var reason: String
    @Guide(description: "Étapes du plan quand action vaut create_plan, dans l'ordre ; vide sinon.")
    var plan: [String]
}
@available(macOS 26.0, *)
@Generable
struct GuidedArgument {
    var name: String
    var value: String
}

@available(macOS 26.0, *)
extension GuidedAgentStep {
    /// Même JSON que celui que le coordinateur valide strictement.
    var json: String {
        var object: [String: Any] = ["action": action]
        if !text.isEmpty { object["text"] = text }
        if action == "tool_call" {
            var args: [String: String] = [:]
            for pair in arguments where !pair.name.isEmpty { args[pair.name] = pair.value }
            object["toolCall"] = ["tool": tool, "arguments": args, "reason": reason.isEmpty ? "Étape de la mission." : reason] as [String: Any]
        }
        if action == "create_plan" {
            object["plan"] = plan.enumerated().map { i, title in ["id": String(i + 1), "title": title, "dependsOn": i == 0 ? [] : [String(i)]] as [String: Any] }
        }
        return String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
#endif

extension OnDeviceLanguageModel {
    /// Décision d'agent à structure garantie (voir `GuidedAgentStep`).
    func generateAgentStep(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: prompt, generating: GuidedAgentStep.self).content.json
        }
        #endif
        throw MindError.invalid("Modèle intégré indisponible.")
    }
}

/// Modèle externe optionnel (passerelle du Brain : Anthropic, clé de l'utilisateur, consentement requis).
public struct GatewayLanguageModel: LanguageModel {
    private let gateway: ModelGateway
    private let localOnly: Bool
    private let identity = GatewayModelIdentity()
    public init(gateway: ModelGateway, localOnly: Bool = false) { self.gateway = gateway; self.localOnly = localOnly }
    public var name: String { identity.snapshot.name ?? (localOnly ? "Modèle local via GHOST" : "Modèle externe via GHOST") }
    public var isLocal: Bool { localOnly }
    public var isSimulated: Bool { identity.snapshot.simulated }
    public func availability() async -> LanguageModelAvailability {
        let candidates = await gateway.statuses().filter { $0.isLocal == localOnly }
        if candidates.contains(where: \.available) { return .available }
        return .unavailable(candidates.first?.reason ?? "Aucun modèle compatible disponible.")
    }
    public func generate(system: String, prompt: String) async throws -> String {
        let response = try await gateway.complete(ModelRequest(task: .generate, system: system, user: prompt, maxOutputTokens: 1_800,
                                                              privacy: localOnly ? .localOnly : .externalOnly))
        identity.set(response.provider + " / " + response.model, simulated: response.isSimulated)
        return response.text
    }
}
private final class GatewayModelIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (name: String?, simulated: Bool) = (nil, false)
    var snapshot: (name: String?, simulated: Bool) { lock.withLock { value } }
    func set(_ name: String, simulated: Bool) { lock.withLock { value = (name, simulated) } }
}

/// Adaptateur du modèle Apple existant vers l'unique passerelle Brain/Mind/Core.
public struct OnDeviceModelProvider: ModelProvider {
    public init() {}
    public var id: String { "apple" }
    public var model: String { "system-on-device" }
    public var isLocal: Bool { true }
    public var isSimulated: Bool { false }
    public func availability() async -> String? {
        if case .unavailable(let reason) = await OnDeviceLanguageModel().availability() { return reason }
        return nil
    }
    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        if let reason = await availability() { throw ModelError.providerFailed(reason) }
        let local = OnDeviceLanguageModel()
        let text = request.task == .agentStep
            ? try await local.generateAgentStep(system: request.system, prompt: request.user)
            : try await local.generate(system: request.system, prompt: request.user)
        return ModelResponse(text: text, provider: id, model: model,
                             usage: ModelUsage(inputTokens: (request.user.utf8.count + request.system.utf8.count) / 3, outputTokens: text.utf8.count / 3), isSimulated: false)
    }
}

/// Remplace noms et adresses par des jetons avant l'envoi à un modèle **externe**, puis les remet localement dans la réponse.
public struct ReversibleMask: Sendable {
    private var mapping: [String: String] = [:]

    public static func mask(_ text: String, names: [String], emails: [String]) -> (String, ReversibleMask) {
        var mask = ReversibleMask(), out = text
        // Une passe sur le texte initial : les jetons produits ne peuvent pas être remasqués.
        let known = Set(names + emails).filter { $0.count > 1 }.sorted { $0.count > $1.count }
        let alternatives = known.map { "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\p{L}\\p{N}_])" }
        let email = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: ([email] + alternatives).joined(separator: "|"), options: .caseInsensitive) else { return (text, mask) }
        let ns = text as NSString
        var index = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let original = ns.substring(with: match.range)
            let prefix = original.contains("@") ? "ADRESSE_" : "PERSONNE_"
            var token: String
            repeat { index += 1; token = prefix + String(index) } while text.contains(token)
            mask.mapping[token] = original
            out = (out as NSString).replacingCharacters(in: match.range, with: token)
        }
        return (out, mask)
    }
    public func restore(_ text: String) -> String {
        guard !mapping.isEmpty, let regex = try? NSRegularExpression(pattern: mapping.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")) else { return text }
        var restored = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let value = mapping[ns.substring(with: match.range)] else { continue }
            restored = (restored as NSString).replacingCharacters(in: match.range, with: value)
        }
        return restored
    }
}
