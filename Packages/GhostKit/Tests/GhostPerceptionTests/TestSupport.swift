import Foundation
import XCTest
@testable import GhostPerception

/// Calendrier fixe (Europe/Paris) pour des tests déterministes.
let parisCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.locale = Locale(identifier: "fr_FR")
    return calendar
}()

/// Construit une date à Paris.
func paris(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    parisCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Mercredi 4 novembre 2026, 10 h, heure de Paris.
let referenceDate = paris(2026, 11, 4, 10, 0)

/// Horloge manipulable.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date = referenceDate) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { self.now } }
}

/// Répertoire temporaire supprimé en fin de test.
func makeTemporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ghost-tests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Fournisseur e-mail scripté : chaque appel consomme la réponse suivante.
final class ScriptedMailProvider: MailProvider, @unchecked Sendable {
    let displayName = "Boîte scriptée"
    let isSimulated = true
    private let lock = NSLock()
    private var script: [Result<[EmailMessage], PerceptionError>]
    private(set) var fetchCount = 0
    var revoked = false

    init(_ script: [Result<[EmailMessage], PerceptionError>]) { self.script = script }

    func push(_ result: Result<[EmailMessage], PerceptionError>) { lock.withLock { script.append(result) } }
    var fetches: Int { lock.withLock { fetchCount } }

    func accountAddress() async throws -> String? { "moi@ghost.test" }

    func fetchMessages(after date: Date) async throws -> [EmailMessage] {
        let next: Result<[EmailMessage], PerceptionError> = lock.withLock {
            fetchCount += 1
            return script.isEmpty ? .success([]) : script.removeFirst()
        }
        return try next.get()
    }

    func revokeAccess() async throws { lock.withLock { revoked = true } }
}

/// Source factice comptant ses collectes.
actor CountingSource: PerceptionSource {
    nonisolated let descriptor: EventSource
    nonisolated let pollInterval: TimeInterval
    private(set) var polls = 0
    private var failures: [PerceptionError]
    private(set) var revoked = false

    init(id: String, interval: TimeInterval = 0, failures: [PerceptionError] = []) {
        descriptor = EventSource(id: SourceID(id), kind: .email, displayName: id, isSimulated: true)
        pollInterval = interval
        self.failures = failures
    }

    func poll() async throws -> [RawObservation] {
        polls += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return []
    }

    func revokeAccess() async throws { revoked = true }
    func resetState() async {}
}

/// Client HTTP enregistreur : ne contacte jamais le réseau.
final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private let responder: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(responder: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse = { _ in HTTPResponse(status: 200, body: Data("{}".utf8)) }) {
        self.responder = responder
    }

    var recorded: [HTTPRequest] { lock.withLock { requests } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { requests.append(request) }
        return try responder(request)
    }
}

/// Système de fichiers espion : enregistre chaque chemin consulté.
final class SpyFileSystem: FileSystemReader, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var visited: [String] = []

    var visitedPaths: [String] { lock.withLock { visited } }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        lock.withLock { visited.append(url.resolvingSymlinksInPath().path) }
        return try base.contentsOfDirectory(at: url)
    }

    func attributes(at url: URL) throws -> FileAttributes {
        lock.withLock { visited.append(url.path) }
        return try base.attributes(at: url)
    }
}

func email(id: String = UUID().uuidString, from: String = "Marie Dupont <marie.dupont@acme.example>",
           to: [String] = ["moi@ghost.test"], cc: [String] = [], subject: String, body: String,
           date: Date = referenceDate, isBulk: Bool = false, isReply: Bool = false) -> EmailMessage {
    EmailMessage(id: id, from: from, to: to, cc: cc, subject: subject, date: date, bodyText: body,
                 isBulk: isBulk, isReply: isReply)
}

/// Interprète un e-mail via le normaliseur et le moteur de compréhension.
func interpret(_ message: EmailMessage, account: String? = "moi@ghost.test") -> GhostEvent {
    let source = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Test")
    let normalized = EventNormalizer().normalize(.email(message, account: account), from: source)
    return UnderstandingEngine(deadlines: DeadlineExtractor(calendar: parisCalendar))
        .interpret(normalized, detectedAt: referenceDate)
}

/// Attend qu'une condition asynchrone devienne vraie (2 s maximum).
func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// Moteur prêt à l'emploi pour les tests (en mémoire). Par défaut en mode
/// manuel (pas de boucle de fond) pour des tests déterministes.
func makeEngine(clock: TestClock = TestClock(), tick: TimeInterval? = nil) -> (PerceptionEngine, TrustEngine, FileEventStore, AccessLog) {
    let log = AccessLog(clock: clock.function)
    let trust = TrustEngine(accessLog: log, clock: clock.function)
    let store = FileEventStore.inMemory()
    let engine = PerceptionEngine(trust: trust, store: store,
                                  understanding: UnderstandingEngine(deadlines: DeadlineExtractor(calendar: parisCalendar)),
                                  tick: tick, clock: clock.function)
    return (engine, trust, store, log)
}
