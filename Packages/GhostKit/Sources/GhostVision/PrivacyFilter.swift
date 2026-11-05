import Foundation

public enum PrivacyDecision: Sendable, Equatable {
    case allow
    case skip(String)
}

/// Règles de vie privée appliquées **avant** toute lecture de texte et sur chaque bloc lu.
/// Les valeurs par défaut sont prudentes ; l'utilisateur peut ajouter des applications à exclure.
public struct PrivacyPolicy: Sendable {
    public var excludedBundleIDs: Set<String>
    public var excludedAppNames: Set<String>
    public var extraExcludedApps: Set<String>
    /// Fragments de titre de fenêtre indiquant une navigation privée.
    public var privateWindowMarkers: [String]
    /// Fragments de titre de fenêtre indiquant de la banque, du paiement ou une connexion.
    public var sensitiveWindowMarkers: [String]
    /// Fragments de texte qui font **ignorer le bloc entier** (pas seulement le masquer).
    public var blockMarkers: [String]

    public init(extraExcludedApps: Set<String> = []) {
        excludedBundleIDs = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
            "com.dashlane.dashlane", "com.lastpass.lastpassmacdesktop", "org.keepassxc.keepassxc", "com.apple.keychainaccess",
            "com.apple.Passwords", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.screensaver",
            "com.apple.systempreferences", "com.apple.SecurityAgent", "app.ghost.shell"
        ]
        excludedAppNames = ["1password", "bitwarden", "dashlane", "lastpass", "keepass", "keychain", "mots de passe", "passwords"]
        self.extraExcludedApps = extraExcludedApps
        privateWindowMarkers = ["navigation privée", "private browsing", "incognito", "fenêtre privée", "private window", "inprivate"]
        sensitiveWindowMarkers = [
            "banque", "bank", "paypal", "boursorama", "crédit agricole", "credit agricole", "bnp", "société générale", "societe generale",
            "lcl", "revolut", "n26", "qonto", "coinbase", "binance", "impots.gouv", "ameli", "mot de passe", "password", "sign in",
            "se connecter", "connexion", "2fa", "authentification", "vérification en deux étapes", "wallet", "portefeuille"
        ]
        blockMarkers = [
            "cvv", "cvc", "cryptogramme", "numéro de carte", "numero de carte", "card number", "iban", "bic", "mot de passe",
            "password", "code de vérification", "verification code", "one-time", "otp", "secret key", "clé secrète", "recovery phrase",
            "phrase de récupération", "numéro de sécurité sociale", "n° de sécu"
        ]
    }

    /// Décision sur l'application et la fenêtre, avant même de lire du texte.
    public func decide(_ context: ScreenContext) -> PrivacyDecision {
        if let id = context.bundleID, excludedBundleIDs.contains(id) { return .skip("application exclue") }
        let app = context.app.lowercased()
        if excludedAppNames.contains(where: { app.contains($0) }) || extraExcludedApps.contains(where: { app.contains($0.lowercased()) }) {
            return .skip("application exclue")
        }
        let title = (context.windowTitle ?? "").lowercased()
        if privateWindowMarkers.contains(where: { title.contains($0) }) { return .skip("navigation privée") }
        if sensitiveWindowMarkers.contains(where: { title.contains($0) }) { return .skip("fenêtre sensible (banque, paiement ou connexion)") }
        return .allow
    }

    /// Filtre un bloc de texte lu : renvoie `nil` s'il contient des marqueurs sensibles, sinon le texte avec les secrets masqués.
    public func sanitize(_ text: String) -> String? {
        let lower = text.lowercased()
        if blockMarkers.contains(where: { Self.contains(lower, marker: $0) }) { return nil }
        return Self.redact(text)
    }

    /// Les marqueurs courts (« bic », « otp », « cvv »…) doivent être des mots entiers : « public » ne contient pas « bic ».
    static func contains(_ text: String, marker: String) -> Bool {
        guard marker.count <= 4 else { return text.contains(marker) }
        return text.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: marker) + "(?![\\p{L}\\p{N}])",
                          options: .regularExpression) != nil
    }

    static let redactions: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#, "[IBAN]"),
            (#"\b(?:sk|pk)[-_][A-Za-z0-9_\-]{16,}\b"#, "[clé]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[clé]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, "[clé]"),
            (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#, "[jeton]"),
            (#"\b[12]\s?\d{2}\s?\d{2}\s?\d{2}\s?\d{3}\s?\d{3}(?:\s?\d{2})?\b"#, "[n° sécu]")
        ]
        return patterns.compactMap { p in (try? NSRegularExpression(pattern: p.0)).map { ($0, p.1) } }
    }()

    /// Masque numéros de carte (algorithme de Luhn), IBAN, clés d'API, jetons et numéros de sécurité sociale.
    public static func redact(_ text: String) -> String {
        var out = text
        for (regex, replacement) in redactions {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        if let cards = try? NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#) {
            let ns = out as NSString
            for match in cards.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let candidate = ns.substring(with: match.range)
                // Le motif peut englober l'espace ou le tiret qui suit le dernier chiffre : on ne masque que les chiffres.
                let core = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
                let range = NSRange(location: match.range.location, length: (core as NSString).length)
                if luhn(core.filter(\.isNumber)) { out = (out as NSString).replacingCharacters(in: range, with: "[carte]") }
            }
        }
        return out
    }

    static func luhn(_ digits: String) -> Bool {
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard numbers.count >= 13, numbers.count <= 19 else { return false }
        var sum = 0
        for (index, value) in numbers.reversed().enumerated() {
            var v = value
            if index % 2 == 1 { v *= 2; if v > 9 { v -= 9 } }
            sum += v
        }
        return sum % 10 == 0
    }
}
