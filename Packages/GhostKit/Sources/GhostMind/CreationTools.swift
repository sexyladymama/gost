import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Où GHOST range ce qu'il crée. N'écrase jamais un fichier existant : un nom pris reçoit un suffixe « (2) ».
public protocol OutputWriter: Sendable {
    var folderName: String? { get }
    func write(_ data: Data, preferredName: String) throws -> URL
}

/// Dossier de création choisi par l'utilisateur (accès accordé par le sélecteur macOS).
public final class FolderOutputWriter: OutputWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var folder: URL?
    public init(folder: URL? = nil) { self.folder = folder }
    public func setFolder(_ url: URL?) { lock.withLock { folder = url } }
    public var folderName: String? { lock.withLock { folder?.lastPathComponent } }

    static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.unicodeScalars.map { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) || " -_.()".unicodeScalars.contains($0) ? Character($0) : "_" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(120)
        return result.isEmpty ? "GHOST" : String(result)
    }

    public func write(_ data: Data, preferredName: String) throws -> URL {
        guard let folder = lock.withLock({ folder }) else { throw MindError.invalid("Aucun dossier de création choisi.") }
        guard data.count <= 20 * 1_024 * 1_024 else { throw MindError.invalid("Fichier trop volumineux.") }
        let name = Self.safeName(preferredName)
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for n in 1...99 {
            let candidate = n == 1 ? name : stem + " (\(n))" + (ext.isEmpty ? "" : "." + ext)
            let url = folder.appendingPathComponent(candidate)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd < 0 { if errno == EEXIST { continue }; throw MindError.invalid("Impossible de créer le fichier dans le dossier choisi.") }
            defer { close(fd) }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                guard written > 0 else { throw MindError.invalid("Écriture interrompue.") }
                offset += written
            }
            guard fsync(fd) == 0 else { throw MindError.invalid("La synchronisation sur disque a échoué.") }
            return url
        }
        throw MindError.invalid("Trop de fichiers portent déjà ce nom.")
    }
}

/// Contrôle d'un SVG produit par un modèle : jamais enregistré tel quel sans vérification.
public enum SVGGuard {
    /// Extrait le premier élément `<svg>…</svg>` d'une réponse.
    public static func extract(_ text: String) -> String? {
        guard let start = text.range(of: "<svg", options: .caseInsensitive), let end = text.range(of: "</svg>", options: [.caseInsensitive, .backwards]),
              start.lowerBound < end.upperBound else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// Renvoie un message d'erreur, ou `nil` si le SVG est acceptable.
    public static func problem(_ svg: String) -> String? {
        guard svg.utf8.count <= 60_000 else { return "SVG trop volumineux." }
        let lower = svg.lowercased()
        for forbidden in ["<script", "<foreignobject", "javascript:", "onload", "onclick", "onerror", "<!doctype", "<!entity", "<image", "<iframe", "<use "] where lower.contains(forbidden) {
            return "Élément interdit dans un logo : \(forbidden.trimmingCharacters(in: CharacterSet(charactersIn: "<! ")))."
        }
        if lower.range(of: #"(?:xlink:)?href\s*=\s*["'](?!#)"#, options: .regularExpression) != nil { return "Lien externe interdit." }
        if lower.components(separatedBy: "<").count > 600 { return "SVG trop complexe." }
        // Les dimensions doivent figurer sur l'élément <svg> lui-même (et non sur un enfant).
        guard let open = lower.range(of: "<svg"), let close = lower[open.lowerBound...].firstIndex(of: ">") else { return "SVG mal formé." }
        let rootTag = lower[open.lowerBound..<close]
        guard rootTag.contains("viewbox") || (rootTag.contains("width=") && rootTag.contains("height=")) else { return "SVG sans dimensions." }
        let parser = XMLParser(data: Data(svg.utf8)); parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return "SVG mal formé." }
        return nil
    }

    #if canImport(AppKit)
    /// Rend le SVG en PNG et vérifie qu'il n'est pas vide (des pixels de plusieurs couleurs, ou une couverture suffisante).
    public static func render(_ svg: String, side: Int = 1024) -> (png: Data?, problem: String?) {
        guard let image = NSImage(data: Data(svg.utf8)), image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (nil, "macOS ne sait pas afficher ce SVG.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var colors = Set<UInt32>(), opaque = 0, samples = 0
        for y in stride(from: 8, to: side, by: 32) {
            for x in stride(from: 8, to: side, by: 32) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                samples += 1
                if c.alphaComponent > 0.05 { opaque += 1 }
                colors.insert(UInt32(c.redComponent * 15) << 12 | UInt32(c.greenComponent * 15) << 8 | UInt32(c.blueComponent * 15) << 4 | UInt32(c.alphaComponent * 15))
            }
        }
        guard samples > 0, colors.count >= 2, Double(opaque) / Double(samples) >= 0.03 else { return (nil, "Le logo est vide ou uni.") }
        return (rep.representation(using: .png, properties: [:]), nil)
    }
    #endif
}

/// Génération de logos et de documents par le modèle de langage (jamais de contenu inventé en l'absence de modèle).
enum CreationPrompts {
    static let logoSystem = """
    Tu es un graphiste. Dessine un logo simple, net et professionnel, en SVG.
    Contraintes strictes : un seul élément <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">, formes géométriques simples (rect, circle, path, polygon, ellipse, line, g), 2 à 3 couleurs, aucun script, aucune image, aucun lien, aucune police externe.
    Si un texte doit figurer, utilise un seul élément <text> avec font-family="Helvetica, Arial, sans-serif".
    Réponds UNIQUEMENT par le code SVG, sans explication.
    """
    static let documentSystem = """
    Tu rédiges des documents pour l'utilisateur, en français clair et professionnel, au format Markdown.
    La première ligne est un titre de la forme « # Titre ». N'invente aucun fait (nom, chiffre, date, adresse) qui ne figure pas dans la demande ; laisse un passage à compléter plutôt que d'inventer.
    Réponds UNIQUEMENT par le document.
    """

    static func prompt(request: String, brief: String) -> String {
        let payload: [String: Any] = ["demande": request, "consigne": brief]
        return String(data: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }

    static func title(fromMarkdown text: String, fallback: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3) where line.hasPrefix("#") {
            let t = line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(80)) }
        }
        return fallback
    }

    static func validDocument(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (80...30_000).contains(t.count) && !t.contains("{{")
    }
}

#if canImport(AppKit)
/// Markdown simple (titres, listes, gras ignoré) → RTF lisible dans TextEdit, Pages et Word.
enum MarkdownRTF {
    static func render(_ markdown: String) -> Data? {
        let out = NSMutableAttributedString()
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = rawLine.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            var font = NSFont.systemFont(ofSize: 12)
            if line.hasPrefix("### ") { font = .boldSystemFont(ofSize: 14); line = String(line.dropFirst(4)) }
            else if line.hasPrefix("## ") { font = .boldSystemFont(ofSize: 17); line = String(line.dropFirst(3)) }
            else if line.hasPrefix("# ") { font = .boldSystemFont(ofSize: 22); line = String(line.dropFirst(2)) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font]))
        }
        return try? out.data(from: NSRange(location: 0, length: out.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
#endif
