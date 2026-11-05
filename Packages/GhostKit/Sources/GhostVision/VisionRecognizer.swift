import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision

/// Lecture du texte **sur le Mac** avec la reconnaissance de texte d'Apple (français et anglais). Aucun envoi réseau.
public struct VisionTextRecognizer: TextRecognizer {
    public var languages: [String]
    public var accurate: Bool

    public init(languages: [String] = ["fr-FR", "en-US"], accurate: Bool = true) {
        self.languages = languages; self.accurate = accurate
    }

    public func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        let languages = self.languages, accurate = self.accurate
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { throw VisionError.recognitionFailed(error.localizedDescription) }
            try Task.checkCancellation()
            let results = (request.results ?? [])
            return results.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
            }
        }.value
    }
}
#endif
