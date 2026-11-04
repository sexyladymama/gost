import Foundation

/// Petite surcouche sur `NSRegularExpression` (insensible à la casse, Unicode).
struct Pattern: Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        // Les motifs sont des constantes du code : une erreur est un bug.
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .useUnicodeWordBoundaries])
    }

    struct Match {
        let range: NSRange
        let groups: [String?]
        let text: String
    }

    func firstMatch(in text: String) -> Match? { matches(in: text).first }

    func matches(in text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { result in
            let groups = (0..<result.numberOfRanges).map { index -> String? in
                let range = result.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            return Match(range: result.range, groups: groups, text: ns.substring(with: result.range))
        }
    }

    func contains(_ text: String) -> Bool { firstMatch(in: text) != nil }
}

enum TextTools {
    /// Découpe en phrases (ponctuation forte ou retour à la ligne).
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character == "\n" {
                result.append(current); current = ""
                continue
            }
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                result.append(current); current = ""
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Raccourcit un extrait pour l'afficher comme justification.
    static func excerpt(_ text: String, limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
