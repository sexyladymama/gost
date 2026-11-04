import Foundation
import XCTest
@testable import GhostContext
import GhostPerception

let ctxReference = Date(timeIntervalSince1970: 1_800_000_000)

let mailSource = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Gmail (simulation)", isSimulated: true)
let realMailSource = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Gmail", isSimulated: false)
let folderSource = EventSource(id: SourceID("folder"), kind: .folder, displayName: "Dossier : Projets")

func makeMailEvent(fingerprint: String = UUID().uuidString,
                   source: EventSource = mailSource,
                   title: String = "Budget",
                   summary: String = "Marie demande le budget",
                   from: String = "marie@acme.example",
                   thread: String? = "thread-1",
                   action: String? = "Envoyer le budget",
                   output: String? = "Fichier Excel",
                   deadline: Date? = nil,
                   mission: Bool = true,
                   detectedAt: Date = ctxReference,
                   occurredAt: Date? = nil) -> GhostEvent {
    var metadata: [String: String] = [:]
    if let thread { metadata["thread"] = thread }
    return GhostEvent(
        fingerprint: fingerprint, kind: mission ? .request : .information,
        tags: [], summary: summary, source: source,
        detectedAt: detectedAt, occurredAt: occurredAt ?? detectedAt, title: title,
        people: [Person(name: "Marie", email: from, role: .sender)],
        expectedAction: action, expectedOutput: output,
        deadline: deadline.map { Deadline(date: $0, text: "pour vendredi", precision: .day) },
        confidence: 0.8, evidence: [Evidence(rule: "request.marker", explanation: "test")],
        isMissionCandidate: mission, metadata: metadata)
}

func makeFileEvent(name: String, path: String, source: EventSource = folderSource,
                   fingerprint: String = UUID().uuidString) -> GhostEvent {
    GhostEvent(fingerprint: fingerprint, kind: .documentEvent, tags: [], summary: "Nouveau fichier \(name)",
               source: source, detectedAt: ctxReference, occurredAt: ctxReference, title: name,
               confidence: 0.9, evidence: [Evidence(rule: "document.new", explanation: "test")],
               isMissionCandidate: false, metadata: ["path": path])
}

func makeContext(persistent: URL? = nil, grants: [(SourceID, Permission)] = [(SourceID("gmail"), .readMail), (SourceID("folder"), .watchFolder)])
async throws -> (ContextEngine, TrustEngine) {
    let trust = TrustEngine(accessLog: AccessLog())
    for (id, permission) in grants { await trust.grant(id, permission: permission, scope: "test") }
    let profile = GhostProfile(id: "test-profile", baseDirectory: persistent ?? FileManager.default.temporaryDirectory)
    let engine = ContextEngine(profile: profile, trust: trust, persistent: persistent != nil)
    return (engine, trust)
}

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension ContextSnapshot {
    func nodes(of kind: ContextEntityKind) -> [ContextNode] { nodes.values.filter { $0.kind == kind } }
    func relations(of kind: ContextRelationKind) -> [ContextRelation] { relations.values.filter { $0.kind == kind } }
}
