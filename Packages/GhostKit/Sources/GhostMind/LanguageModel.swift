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

/// Modèle externe optionnel (passerelle du Brain : Anthropic, clé de l'utilisateur, consentement requis).
public struct GatewayLanguageModel: LanguageModel {
    private let gateway: ModelGateway
    public init(gateway: ModelGateway) { self.gateway = gateway }
    public var name: String { "Modèle externe (avec masquage des noms)" }
    public var isLocal: Bool { false }
    public var isSimulated: Bool { false }
    public func availability() async -> LanguageModelAvailability {
        await gateway.isAvailable ? .available : .unavailable("Modèle externe désactivé ou sans clé (réglages du cerveau).")
    }
    public func generate(system: String, prompt: String) async throws -> String {
        try await gateway.complete(ModelRequest(task: .generate, system: system, user: prompt, maxOutputTokens: 900)).text
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
