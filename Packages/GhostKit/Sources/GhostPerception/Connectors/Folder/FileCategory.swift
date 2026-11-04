import Foundation

/// Catégorie d'un fichier, déduite de son extension (le contenu n'est pas lu).
public enum FileCategory: String, Codable, Sendable, CaseIterable {
    case document, spreadsheet, presentation, pdf, text, image, audio, video, archive, code, other

    public var label: String {
        switch self {
        case .document: return "Document"
        case .spreadsheet: return "Tableur"
        case .presentation: return "Présentation"
        case .pdf: return "PDF"
        case .text: return "Texte"
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Vidéo"
        case .archive: return "Archive"
        case .code: return "Code"
        case .other: return "Fichier"
        }
    }

    private static let map: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ extensions: [String]) { extensions.forEach { map[$0] = category } }
        add(.document, ["doc", "docx", "pages", "odt", "rtf"])
        add(.spreadsheet, ["xls", "xlsx", "xlsm", "numbers", "ods", "csv", "tsv"])
        add(.presentation, ["ppt", "pptx", "key", "odp"])
        add(.pdf, ["pdf"])
        add(.text, ["txt", "md", "markdown"])
        add(.image, ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "svg"])
        add(.audio, ["mp3", "m4a", "wav", "aac", "flac"])
        add(.video, ["mov", "mp4", "m4v", "avi", "mkv"])
        add(.archive, ["zip", "tar", "gz", "tgz", "rar", "7z", "dmg"])
        add(.code, ["swift", "py", "js", "ts", "json", "html", "css", "c", "h", "java", "rb", "go", "rs", "sh", "yml", "yaml"])
        return map
    }()

    public static func from(extension ext: String) -> FileCategory {
        map[ext.lowercased()] ?? .other
    }

    /// Paquets macOS (dossiers vus comme un seul document) : non parcourus.
    static let packageExtensions: Set<String> = ["pages", "numbers", "key", "app", "bundle", "rtfd",
                                                 "photoslibrary", "xcodeproj", "xcworkspace"]
}
