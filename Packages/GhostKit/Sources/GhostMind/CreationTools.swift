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
    private var identity: (device: Int32, inode: UInt64)?
    public init(folder: URL? = nil) { setFolder(folder) }
    public func setFolder(_ url: URL?) {
        lock.withLock {
            folder = nil; identity = nil
            guard let url, url.isFileURL else { return }
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return }
            folder = url; identity = (info.st_dev, info.st_ino)
        }
    }
    public var folderName: String? { lock.withLock { folder?.lastPathComponent } }

    static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.unicodeScalars.map { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) || " -_.()".unicodeScalars.contains($0) ? Character($0) : "_" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(120)
        return result.isEmpty ? "GHOST" : String(result)
    }

    public func write(_ data: Data, preferredName: String) throws -> URL {
        try lock.withLock { try writeLocked(data, preferredName: preferredName) }
    }
    private func writeLocked(_ data: Data, preferredName: String) throws -> URL {
        try Task.checkCancellation()
        guard let folder, let identity else { throw MindError.invalid("Aucun dossier de création choisi.") }
        let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw MindError.notAllowed("Le dossier choisi est inaccessible ou a été remplacé.") }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode else {
            throw MindError.notAllowed("Le dossier choisi a été remplacé : choisissez-le à nouveau.")
        }
        guard data.count <= 20 * 1_024 * 1_024 else { throw MindError.invalid("Fichier trop volumineux.") }
        let name = Self.safeName(preferredName)
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for n in 1...99 {
            let candidate = n == 1 ? name : stem + " (\(n))" + (ext.isEmpty ? "" : "." + ext)
            let url = folder.appendingPathComponent(candidate)
            let fd = openat(root, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 { if errno == EEXIST { continue }; throw MindError.invalid("Impossible de créer le fichier dans le dossier choisi.") }
            defer { close(fd) }
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                guard written > 0 else { throw MindError.invalid("Écriture interrompue.") }
                offset += written
            }
            guard fsync(fd) == 0, fsync(root) == 0 else { throw MindError.invalid("La synchronisation sur disque a échoué.") }
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
        if lower.contains("@import") || lower.contains("@font-face") || lower.range(of: #"url\s*\(\s*["']?(?!#)"#, options: .regularExpression) != nil {
            return "Ressource CSS externe ou incorporée interdite."
        }
        if lower.components(separatedBy: "<").count > 600 { return "SVG trop complexe." }
        // Les dimensions doivent figurer sur l'élément <svg> lui-même (et non sur un enfant).
        guard let open = lower.range(of: "<svg"), let close = lower[open.lowerBound...].firstIndex(of: ">") else { return "SVG mal formé." }
        let rootTag = lower[open.lowerBound..<close]
        guard rootTag.contains("viewbox") || (rootTag.contains("width=") && rootTag.contains("height=")) else { return "SVG sans dimensions." }
        let parser = XMLParser(data: Data(svg.utf8)); parser.shouldResolveExternalEntities = false
        let policy = SVGElementPolicy(); parser.delegate = policy
        guard parser.parse(), policy.accepted else { return "SVG mal formé ou élément actif interdit." }
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

/// Un SVG de logo est une image déclarative : aucun script, animation, feuille CSS ou élément inconnu.
private final class SVGElementPolicy: NSObject, XMLParserDelegate {
    var accepted = true
    private let allowed: Set<String> = ["svg", "g", "rect", "circle", "ellipse", "path", "polygon", "polyline", "line", "text", "tspan", "defs", "lineargradient", "radialgradient", "stop", "clippath", "mask", "title", "desc"]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard allowed.contains(elementName.lowercased()), !attributes.keys.contains(where: { $0.lowercased().hasPrefix("on") }) else {
            accepted = false; parser.abortParsing(); return
        }
    }
}

/// Génération de logos et de documents par le modèle de langage (jamais de contenu inventé en l'absence de modèle).
enum CreationPrompts {
    /// Un petit modèle local dessine mal en SVG libre (formes décentrées, texte coupé) : il choisit seulement les paramètres
    /// du logo (nom, initiales, couleurs, style) et GHOST le dessine avec des gabarits soignés.
    static let logoSystem = """
    Tu es un directeur artistique. À partir de la demande, choisis les paramètres d'un logo.
    Réponds UNIQUEMENT par un objet JSON : {"name":"nom de la marque","initials":"1 ou 2 lettres","background":"#RRGGBB","accent":"#RRGGBB","style":"monogram|badge|wordmark"}.
    "name" est le nom cité dans la demande (sinon un nom très court). Couleurs sobres et contrastées, adaptées à l'activité. Aucune explication.
    """
    static let logoLegacySystem = """
    Tu es un graphiste. Dessine un logo simple, net et professionnel, en SVG.
    Contraintes strictes : un seul élément <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">, formes géométriques simples (rect, circle, path, polygon, ellipse, line, g), 2 à 3 couleurs, aucun script, aucune image, aucun lien, aucune police externe.
    Si un texte doit figurer, utilise un seul élément <text> avec font-family="Helvetica, Arial, sans-serif".
    Réponds UNIQUEMENT par le code SVG, sans explication.
    """
    static let documentSystem = """
    Tu rédiges des documents pour l'utilisateur, en français clair et professionnel, au format Markdown.
    La première ligne est un titre de la forme « # Titre ». N'invente aucun fait (nom, chiffre, date, adresse) qui ne figure pas dans la demande ; laisse un passage à compléter plutôt que d'inventer.
    Le nom de l'expéditeur est fourni (« expediteur ») : signe avec lui, n'écris jamais « [Votre nom] ». Pour toute autre information inconnue, laisse un champ entre crochets (« [date] »).
    Réponds UNIQUEMENT par le document.
    """

    static func prompt(request: String, brief: String, user: String = "") -> String {
        let payload: [String: Any] = ["demande": request, "consigne": brief, "expediteur": user]
        return String(data: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }

    /// Remplace les champs « [Votre nom] » par le nom de l'utilisateur ; renvoie le texte et le nombre de champs à compléter restants.
    static func fillSender(_ text: String, user: String) -> (text: String, remaining: Int) {
        var out = text
        for field in ["[Votre nom]", "[votre nom]", "[Votre Nom]", "[Nom]", "[Nom et prénom]", "[Prénom Nom]", "[Votre nom et prénom]"] {
            out = out.replacingOccurrences(of: field, with: user).replacingOccurrences(of: field.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"), with: user)
        }
        let remaining = (try? NSRegularExpression(pattern: #"\[[^\]\n]{2,40}\]"#))?.numberOfMatches(in: out, range: NSRange(out.startIndex..., in: out)) ?? 0
        return (out, remaining)
    }

    static func title(fromMarkdown text: String, fallback: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3) where line.hasPrefix("#") {
            let t = line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
            let clean = t.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "").trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { return String(clean.prefix(80)) }
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


/// Paramètres d'un logo choisis par le modèle ; le dessin est fait par GHOST (gabarits centrés, texte à la bonne taille).
struct LogoSpec: Decodable, Equatable {
    var name: String
    var initials: String?
    var background: String
    var accent: String
    var style: String

    static func parse(_ text: String) -> LogoSpec? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8), var spec = try? JSONDecoder().decode(LogoSpec.self, from: data) else { return nil }
        spec.name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...30).contains(spec.name.count) else { return nil }
        func hex(_ s: String, _ fallback: String) -> String { s.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil ? s : fallback }
        spec.background = hex(spec.background, "#0B0F14"); spec.accent = hex(spec.accent, "#8FC7FF")
        // Contraste insuffisant (blanc sur jaune…) : on prend le noir ou le blanc, selon le fond.
        if Self.contrast(spec.background, spec.accent) < 3 { spec.accent = Self.luminance(spec.background) > 0.4 ? "#111111" : "#FFFFFF" }
        let letters = (spec.initials ?? "").filter(\.isLetter).prefix(2)
        spec.initials = letters.isEmpty ? String(spec.name.prefix(1)).uppercased() : letters.uppercased()
        return spec
    }

    static func luminance(_ hex: String) -> Double {
        let v = hex.dropFirst().chunks(2).map { Double(Int($0, radix: 16) ?? 0) / 255 }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        guard v.count == 3 else { return 0 }
        return 0.2126 * lin(v[0]) + 0.7152 * lin(v[1]) + 0.0722 * lin(v[2])
    }
    static func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// SVG 512×512 : fond arrondi, forme centrée, texte centré dont la taille dépend de la longueur.
    func svg() -> String {
        let initials = escaped(initials ?? "G"), name = escaped(name.uppercased())
        let head = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="96" fill="\#(background)"/>"#
        let font = #"font-family="Helvetica, Arial, sans-serif" text-anchor="middle""#
        let nameSize = max(28, min(72, Int(400.0 / (Double(max(self.name.count, 1)) * 0.68))))
        switch style.lowercased() {
        case "wordmark":
            return head + #"<text x="256" y="\#(256 + nameSize / 3)" \#(font) font-size="\#(nameSize)" font-weight="700" letter-spacing="4" fill="\#(accent)">\#(name)</text>"#
                + #"<rect x="156" y="\#(256 + nameSize / 3 + 28)" width="200" height="8" rx="4" fill="\#(accent)"/></svg>"#
        case "badge":
            return head + #"<circle cx="256" cy="226" r="130" fill="none" stroke="\#(accent)" stroke-width="14"/>"#
                + #"<text x="256" y="\#(226 + 56)" \#(font) font-size="170" font-weight="700" fill="\#(accent)">\#(initials)</text>"#
                + #"<text x="256" y="430" \#(font) font-size="\#(min(nameSize, 44))" font-weight="600" letter-spacing="6" fill="\#(accent)">\#(name)</text></svg>"#
        default:   // monogram
            return head + #"<rect x="96" y="96" width="320" height="320" rx="72" fill="\#(accent)"/>"#
                + #"<text x="256" y="\#(256 + 62)" \#(font) font-size="\#(initials.count > 1 ? 170 : 220)" font-weight="700" fill="\#(background)">\#(initials)</text></svg>"#
        }
    }
}

private extension Substring {
    func chunks(_ n: Int) -> [String] { stride(from: 0, to: count, by: n).map { String(self.dropFirst($0).prefix(n)) } }
}
