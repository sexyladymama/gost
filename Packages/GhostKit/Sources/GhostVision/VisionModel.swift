import Foundation
import CoreGraphics

/// Application et fenêtre au premier plan au moment de la capture.
public struct ScreenContext: Sendable, Hashable {
    public var app: String
    public var bundleID: String?
    public var windowTitle: String?
    public init(app: String, bundleID: String? = nil, windowTitle: String? = nil) {
        self.app = app; self.bundleID = bundleID; self.windowTitle = windowTitle
    }
}

/// Image capturée : traitée en mémoire puis abandonnée. Elle n'est jamais écrite sur le disque.
public struct CapturedFrame: @unchecked Sendable {
    public var image: CGImage
    public var context: ScreenContext
    public init(image: CGImage, context: ScreenContext) { self.image = image; self.context = context }
}

/// Source d'images d'écran. L'implémentation réelle (ScreenCaptureKit) renvoie `nil` lorsque la capture est
/// impossible ou interdite : écran verrouillé, permission macOS absente, application de GHOST au premier plan.
public protocol FrameSource: Sendable {
    func capture() async throws -> CapturedFrame?
}

/// Ligne de texte reconnue, avec sa position normalisée (origine en bas à gauche, comme Vision).
public struct RecognizedLine: Sendable, Hashable {
    public var text: String
    public var box: CGRect
    public var confidence: Float
    public init(text: String, box: CGRect, confidence: Float = 1) {
        self.text = text; self.box = box; self.confidence = confidence
    }
}

public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage) async throws -> [RecognizedLine]
}

/// Bloc de texte cohérent (une bulle de message, un paragraphe, une notification).
public struct TextBlock: Sendable, Hashable {
    public var text: String
    public var lineCount: Int
    public init(text: String, lineCount: Int) { self.text = text; self.lineCount = lineCount }
}

public enum VisionError: Error, LocalizedError, Sendable {
    case captureFailed(String), recognitionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .captureFailed(let s): return "Capture de l'écran : \(s)"
        case .recognitionFailed(let s): return "Lecture du texte : \(s)"
        }
    }
}

/// Regroupe les lignes reconnues en blocs : des lignes proches verticalement et alignées appartiennent au même message.
public enum TextBlocks {
    public static func group(_ lines: [RecognizedLine], maxBlockLength: Int = 800) -> [TextBlock] {
        let usable = lines.filter { $0.text.trimmingCharacters(in: .whitespaces).count >= 2 && $0.confidence >= 0.3 }
        guard !usable.isEmpty else { return [] }
        // De haut en bas (Vision : y croît vers le haut).
        let ordered = usable.sorted { $0.box.maxY > $1.box.maxY }
        let heights = ordered.map(\.box.height).sorted()
        let typical = max(heights[heights.count / 2], 0.005)
        var blocks: [[RecognizedLine]] = []
        for line in ordered {
            if var last = blocks.last, let previous = last.last {
                let gap = previous.box.minY - line.box.maxY
                let horizontallyRelated = line.box.minX < previous.box.maxX && line.box.maxX > previous.box.minX
                let sameColumn = abs(line.box.minX - previous.box.minX) < 0.12
                if gap < typical * 1.3 && horizontallyRelated && sameColumn {
                    last.append(line)
                    blocks[blocks.count - 1] = last
                    continue
                }
            }
            blocks.append([line])
        }
        return blocks.compactMap { group in
            // Une phrase qui passe à la ligne (bulle de message, paragraphe) reste UNE phrase : on ne sépare par un saut de ligne
            // qu'après une ponctuation finale.
            var text = ""
            for line in group.map({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                if text.isEmpty { text = line; continue }
                text += (text.last.map { ".!?:;".contains($0) } ?? false) ? "\n" : " "
                text += line
            }
            guard text.count >= 12 else { return nil }
            return TextBlock(text: String(text.prefix(maxBlockLength)), lineCount: group.count)
        }
    }
}
