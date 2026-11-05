import Foundation
import AppKit
import XCTest
import GhostPerception
@testable import GhostVision

let visionCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Paris")!
    c.locale = Locale(identifier: "fr_FR")
    return c
}()
func parisAt(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    visionCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
/// Mercredi 4 novembre 2026, 10 h (Paris).
let visionNow = parisAt(2026, 11, 4, 10)

/// Dessine des lignes de texte (noir sur blanc, gros corps) dans une image : sert à tester le VRAI OCR sans permission d'écran.
func renderScreen(_ lines: [String], width: Int = 1400, fontSize: CGFloat = 40) -> CGImage {
    let lineHeight = fontSize * 1.9
    let height = Int(CGFloat(lines.count) * lineHeight + 80)
    // Dessin dans un CGContext dont makeImage() renvoie une COPIE indépendante des pixels
    // (l'image d'un NSBitmapImageRep partage la mémoire de celui-ci et devient invalide quand il est libéré).
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black]
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 40, y: CGFloat(height) - 40 - lineHeight * CGFloat(index + 1) + fontSize * 0.2), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

/// Source d'images simulée : une file de captures (ou `nil` = rien à capturer).
final class FakeFrames: FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [CapturedFrame?]
    private(set) var captureCount = 0
    init(_ frames: [CapturedFrame?]) { queue = frames }
    func capture() async throws -> CapturedFrame? {
        lock.withLock { captureCount += 1; return queue.isEmpty ? nil : queue.removeFirst() }
    }
}
struct CountingRecognizer: TextRecognizer {
    final class Box: @unchecked Sendable { var calls = 0; let lock = NSLock() }
    let inner: TextRecognizer, box = Box()
    func recognize(_ image: CGImage) async throws -> [RecognizedLine] { box.lock.withLock { box.calls += 1 }; return try await inner.recognize(image) }
    var calls: Int { box.lock.withLock { box.calls } }
}

/// Agenda simulé (aucune permission nécessaire) ; reproduit les cas d'échec utiles.
actor FakeCalendar: CalendarWriter {
    var access: CalendarAuthorization = .authorized
    var store: [String: ExistingEvent] = [:]
    var createdNotes: [String: String] = [:]
    var failAfterCreate = false
    var corruptFetch = false
    private var counter = 0
    func setAccess(_ value: CalendarAuthorization) { access = value }
    func setFailAfterCreate(_ value: Bool) { failAfterCreate = value }
    func setCorruptFetch(_ value: Bool) { corruptFetch = value }
    func seed(_ title: String, at start: Date) -> String {
        counter += 1; let id = "seed-\(counter)"
        store[id] = ExistingEvent(identifier: id, title: title, start: start, end: start.addingTimeInterval(3600)); return id
    }
    func authorization() async -> CalendarAuthorization { access }
    func requestAccess() async -> Bool { access == .authorized }
    func events(around start: Date, window: TimeInterval) async throws -> [ExistingEvent] {
        store.values.filter { abs($0.start.timeIntervalSince(start)) <= window }
    }
    func create(_ request: CalendarEventRequest) async throws -> String {
        counter += 1; let id = "ev-\(counter)"
        store[id] = ExistingEvent(identifier: id, title: request.title, start: request.start, end: request.end)
        createdNotes[id] = request.notes
        if failAfterCreate { throw CalendarError.storage("panne après création") }
        return id
    }
    func fetch(_ identifier: String) async throws -> ExistingEvent? {
        guard var event = store[identifier] else { return nil }
        if corruptFetch { event.title = "Autre chose" }
        return event
    }
    func delete(_ identifier: String) async throws { store[identifier] = nil }
}

func apptEvent(_ draft: AppointmentDraft, app: String = "WhatsApp") -> GhostEvent {
    var metadata = ScreenSource.metadata(for: draft); metadata["app"] = app; metadata["origin"] = "screen"
    return GhostEvent(fingerprint: UUID().uuidString, kind: .information, tags: [], summary: "test",
                      source: EventSource(id: SourceID("screen"), kind: .screen, displayName: "Écran"),
                      detectedAt: visionNow, occurredAt: visionNow, title: app, confidence: 0.9, evidence: [], isMissionCandidate: false, metadata: metadata)
}
func draft(_ title: String = "Dîner", start: Date = parisAt(2026, 11, 10, 21), certain: Bool = true, explicit: Bool = true) -> AppointmentDraft {
    AppointmentDraft(title: title, start: start, end: start.addingTimeInterval(7200), hasExplicitTime: explicit, certain: certain,
                     confidence: certain ? 0.95 : 0.5, excerpt: "On a un dîner le 10 novembre à 21h", location: nil)
}
