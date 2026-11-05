import Foundation
import CoreGraphics
import GhostPerception

/// Empreinte visuelle 16×16 : deux captures quasi identiques ne sont pas relues (économie de calcul, rien n'est conservé).
enum ImageFingerprint {
    static func hash(_ image: CGImage) -> [Bool] {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return pixels.map { Int($0) > mean }
    }
    static func distance(_ a: [Bool], _ b: [Bool]) -> Int {
        guard a.count == b.count else { return Int.max }
        return zip(a, b).filter { $0 != $1 }.count
    }
}

/// Source de perception « écran » : une capture de la fenêtre au premier plan toutes les quelques secondes, lue localement.
///
/// Ce qui sort de cette source — et rien d'autre — : des **blocs de texte utiles** (une demande adressée à l'utilisateur ou un
/// rendez-vous), débarrassés des données sensibles. Pas d'image, pas de texte d'écran en masse, rien qui ne soit pas utile.
/// En pause ou arrêt, le moteur de perception n'interroge plus la source : aucune capture n'a lieu.
public final class ScreenSource: PerceptionSource, @unchecked Sendable {
    public let descriptor: EventSource
    public let pollInterval: TimeInterval
    private let frames: FrameSource
    private let recognizer: TextRecognizer
    private let policy: PrivacyPolicy
    private let trust: TrustEngine
    private let understanding: UnderstandingEngine
    private let extractor: AppointmentExtractor
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var lastHash: [Bool] = []
    private var seen: [String: Date] = [:]
    private var stats = (captures: 0, skipped: 0, lastLog: Date.distantPast)

    public init(id: SourceID = SourceID("screen"), frames: FrameSource, recognizer: TextRecognizer, policy: PrivacyPolicy = PrivacyPolicy(),
                trust: TrustEngine, pollInterval: TimeInterval = 3, understanding: UnderstandingEngine = UnderstandingEngine(),
                appointments: AppointmentExtractor = AppointmentExtractor(), clock: @escaping @Sendable () -> Date = { Date() }) {
        descriptor = EventSource(id: id, kind: .screen, displayName: "Écran")
        self.frames = frames; self.recognizer = recognizer; self.policy = policy; self.trust = trust
        self.pollInterval = pollInterval; self.understanding = understanding; extractor = appointments; self.clock = clock
    }

    public func poll() async throws -> [RawObservation] {
        // Autorisation de l'utilisateur dans GHOST (en plus de la permission macOS) : refus journalisé.
        guard await trust.isAuthorized(descriptor.id, .observeScreen) else {
            try await trust.require(descriptor.id, .observeScreen, operation: "screen.capture", target: "écran")
            return []
        }
        guard let frame = try await frames.capture() else { return [] }
        if case .skip = policy.decide(frame.context) { note(skipped: true); return [] }
        let fingerprint = ImageFingerprint.hash(frame.image)
        let unchanged = lock.withLock { () -> Bool in
            defer { lastHash = fingerprint }
            return !fingerprint.isEmpty && ImageFingerprint.distance(lastHash, fingerprint) <= 2
        }
        guard !unchanged else { return [] }
        note(skipped: false)
        try Task.checkCancellation()

        let now = clock()
        var observations: [RawObservation] = []
        for block in TextBlocks.group(try await recognizer.recognize(frame.image)) {
            guard let text = policy.sanitize(block.text) else { continue }
            let key = Self.key(app: frame.context.app, text: text)
            let alreadySeen = lock.withLock { () -> Bool in
                if let date = seen[key], now.timeIntervalSince(date) < 24 * 3600 { return true }
                seen[key] = now; return false
            }
            if alreadySeen { continue }
            var snapshot = ScreenSnapshot(app: frame.context.app, bundleID: frame.context.bundleID, windowTitle: frame.context.windowTitle,
                                          text: text, contentKey: key, capturedAt: now)
            let draft = extractor.drafts(in: text, reference: now).first
            if let draft { snapshot.metadata.merge(Self.metadata(for: draft)) { $1 } }
            // Seul un bloc utile devient un événement : demande adressée à l'utilisateur ou rendez-vous.
            let event = understanding.interpret(EventNormalizer().normalize(.screen(snapshot), from: descriptor), detectedAt: now)
            if event.isMissionCandidate || draft != nil { observations.append(.screen(snapshot)) }
        }
        prune(now)
        return observations
    }

    public func revokeAccess() async throws {}
    public func resetState() async throws { lock.withLock { lastHash = []; seen = [:] } }

    // MARK: Aides

    static func key(app: String, text: String) -> String {
        let normalized = (app + "|" + text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return String(Digest.sha256(Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    /// Un rendez-vous traverse le pipeline sous forme de métadonnées de l'événement (bornées, sans le texte complet).
    public static func metadata(for draft: AppointmentDraft) -> [String: String] {
        var m = ["appt.title": draft.title, "appt.start": String(draft.start.timeIntervalSince1970), "appt.end": String(draft.end.timeIntervalSince1970),
                 "appt.explicitTime": draft.hasExplicitTime ? "1" : "0", "appt.certain": draft.certain ? "1" : "0",
                 "appt.confidence": String(format: "%.2f", draft.confidence), "appt.excerpt": draft.excerpt]
        if let place = draft.location { m["appt.location"] = place }
        return m
    }

    private func note(skipped: Bool) {
        let now = clock()
        let message: String? = lock.withLock {
            if skipped { stats.skipped += 1 } else { stats.captures += 1 }
            guard now.timeIntervalSince(stats.lastLog) >= 60, stats.captures + stats.skipped > 0 else { return nil }
            defer { stats = (0, 0, now) }
            return "\(stats.captures) lecture(s), \(stats.skipped) ignorée(s) (vie privée) sur la dernière minute"
        }
        if let message {
            let trust = self.trust, id = descriptor.id
            Task { await trust.accessLog.record(id, operation: "screen.observe", target: message, outcome: .allowed) }
        }
    }

    private func prune(_ now: Date) {
        lock.withLock {
            guard seen.count > 2_000 else { return }
            seen = seen.filter { now.timeIntervalSince($0.value) < 3 * 3600 }
        }
    }
}
