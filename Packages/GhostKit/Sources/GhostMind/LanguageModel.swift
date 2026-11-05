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
        var i = 0
        for email in emails.sorted(by: { $0.count > $1.count }) where !email.isEmpty {
            i += 1; let token = "ADRESSE_\(i)"; mask.mapping[token] = email
            out = out.replacingOccurrences(of: email, with: token, options: .caseInsensitive)
        }
        for name in names.sorted(by: { $0.count > $1.count }) where name.count > 1 {
            i += 1; let token = "PERSONNE_\(i)"; mask.mapping[token] = name
            out = out.replacingOccurrences(of: name, with: token, options: .caseInsensitive)
        }
        return (out, mask)
    }
    public func restore(_ text: String) -> String {
        mapping.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
