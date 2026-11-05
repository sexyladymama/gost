import Foundation
import GhostPerception

public enum CalendarAuthorization: String, Sendable { case notDetermined, denied, authorized }

public struct ExistingEvent: Sendable, Hashable {
    public var identifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public init(identifier: String, title: String, start: Date, end: Date) {
        self.identifier = identifier; self.title = title; self.start = start; self.end = end
    }
}

public struct CalendarEventRequest: Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var notes: String
}

/// Accès à l'agenda. Volontairement limité : créer, relire, chercher autour d'une date, et supprimer **par identifiant**
/// (GHOST ne supprime que ce qu'il a lui-même créé, jamais autre chose).
public protocol CalendarWriter: Sendable {
    func authorization() async -> CalendarAuthorization
    func requestAccess() async -> Bool
    func events(around start: Date, window: TimeInterval) async throws -> [ExistingEvent]
    func create(_ request: CalendarEventRequest) async throws -> String
    func fetch(_ identifier: String) async throws -> ExistingEvent?
    func delete(_ identifier: String) async throws
}

public enum CalendarEntryStatus: String, Codable, Sendable {
    /// Écriture en cours (ou interrompue par une panne : `recoverPending` vérifie avant de recommencer).
    case pending
    case added
    /// Détecté mais non ajouté : heure absente, question, hypothèse, ou ajout automatique non autorisé.
    case suggested
    case alreadyPresent
    case dismissed
    case undone
    case failed
}

public struct CalendarEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var excerpt: String
    public var sourceApp: String
    public var status: CalendarEntryStatus
    public var eventIdentifier: String?
    public var reason: String?
    public var confidence: Double
    public var hasExplicitTime: Bool
    public var createdAt: Date
    public var updatedAt: Date
}

struct CalendarLedger: Codable {
    var schemaVersion = 1
    var entries: [String: CalendarEntry] = [:]
}

public enum CalendarError: Error, LocalizedError, Sendable {
    case unknownEntry, notPermitted(String), verificationFailed(String), storage(String)
    public var errorDescription: String? {
        switch self {
        case .unknownEntry: return "Rendez-vous introuvable."
        case .notPermitted(let s), .verificationFailed(let s), .storage(let s): return s
        }
    }
}

public enum CalendarUpdate: Sendable { case entries([CalendarEntry]), issue(String) }

/// Ajoute à l'agenda les rendez-vous vus à l'écran.
///
/// Ajout **direct** uniquement si tout est réuni : événement nommé, date et heure explicites, ni question ni hypothèse, dans le
/// futur proche, autorisation `writeCalendar` donnée dans GHOST **et** accès complet accordé à l'agenda par macOS. Sinon le
/// rendez-vous est seulement *suggéré*. Chaque ajout est vérifié en relisant l'agenda, tracé dans un registre persistant,
/// dédoublonné (registre et événements déjà présents) et annulable en un clic. GHOST ne modifie ni ne supprime jamais un
/// événement qu'il n'a pas créé.
public actor CalendarAgent: PerceptionEventConsumer {
    public static let sourceID = SourceID("calendar")
    public nonisolated let updates: AsyncStream<CalendarUpdate>
    private let continuation: AsyncStream<CalendarUpdate>.Continuation
    private let writer: CalendarWriter
    private let trust: TrustEngine
    private let url: URL?
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private var ledger: CalendarLedger?

    public init(writer: CalendarWriter, trust: TrustEngine, ledgerURL: URL?, calendar: Calendar = .current,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.writer = writer; self.trust = trust; url = ledgerURL; self.calendar = calendar; self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: CalendarUpdate.self, bufferingPolicy: .bufferingNewest(20))
    }
    deinit { continuation.finish() }

    public func entries() throws -> [CalendarEntry] {
        try load().entries.values.sorted { $0.start < $1.start }
    }

    // MARK: Perception

    public func consume(_ events: [GhostEvent]) async {
        for event in events where event.source.kind == .screen && event.metadata["appt.start"] != nil {
            do { try await handle(event) } catch { report(error) }
        }
        publish()
    }

    private func handle(_ event: GhostEvent) async throws {
        let m = event.metadata
        guard let title = m["appt.title"], let startValue = m["appt.start"].flatMap(Double.init), let endValue = m["appt.end"].flatMap(Double.init) else { return }
        let start = Date(timeIntervalSince1970: startValue), end = Date(timeIntervalSince1970: endValue)
        let now = clock()
        guard start > now.addingTimeInterval(-300), start < now.addingTimeInterval(400 * 86_400), end > start else { return }   // passé ou trop lointain : ignoré
        let key = Self.key(title: title, start: start)
        var ledger = try load()
        if let existing = ledger.entries[key], existing.status != .failed { return }                                           // déjà traité : jamais de doublon
        let entry = CalendarEntry(id: key, title: title, start: start, end: end, location: m["appt.location"],
                                  excerpt: m["appt.excerpt"] ?? "", sourceApp: m["app"] ?? "écran", status: .suggested, eventIdentifier: nil,
                                  reason: nil, confidence: Double(m["appt.confidence"] ?? "") ?? 0.5,
                                  hasExplicitTime: m["appt.explicitTime"] == "1", createdAt: now, updatedAt: now)
        ledger.entries[key] = entry
        try save(ledger)

        let certain = m["appt.certain"] == "1"
        let granted = await trust.isAuthorized(Self.sourceID, .writeCalendar)
        let access = await writer.authorization()
        if certain, granted, access == .authorized {
            try await add(key)
        } else {
            let why = !certain ? (entry.hasExplicitTime ? "formulation incertaine (question ou hypothèse)" : "aucune heure précisée")
                : (!granted ? "ajout automatique à l'agenda non autorisé dans GHOST" : "accès à l'agenda non accordé par macOS")
            try update(key) { $0.reason = why }
        }
    }

    // MARK: Écriture vérifiée

    private func add(_ key: String) async throws {
        guard let entry = try load().entries[key] else { throw CalendarError.unknownEntry }
        // Un événement équivalent existe déjà dans l'agenda : rien n'est ajouté.
        let nearby = try await writer.events(around: entry.start, window: 2 * 3600)
        if nearby.contains(where: { abs($0.start.timeIntervalSince(entry.start)) < 1800 && Self.similar($0.title, entry.title) }) {
            try update(key) { $0.status = .alreadyPresent; $0.reason = "un événement équivalent existe déjà dans l'agenda" }
            return
        }
        try update(key) { $0.status = .pending }                       // intention journalisée AVANT l'écriture
        let request = CalendarEventRequest(
            title: entry.title, start: entry.start, end: entry.end, location: entry.location,
            notes: "Ajouté par GHOST d'après un message vu dans \(entry.sourceApp) : « \(entry.excerpt) ». Vous pouvez annuler cet ajout depuis GHOST ▸ Agenda.")
        do {
            let identifier = try await writer.create(request)
            guard let stored = try await writer.fetch(identifier), stored.title == entry.title,
                  abs(stored.start.timeIntervalSince(entry.start)) < 1 else {
                try? await writer.delete(identifier)                   // vérification échouée : on retire ce qu'on vient de créer
                try update(key) { $0.status = .failed; $0.reason = "l'événement relu ne correspond pas : ajout retiré" }
                throw CalendarError.verificationFailed("Vérification de l'ajout à l'agenda échouée.")
            }
            try update(key) { $0.status = .added; $0.eventIdentifier = identifier; $0.reason = nil }
        } catch {
            // La vérification a déjà mis l'entrée à jour ; toute autre erreur d'écriture la marque en échec (jamais « en cours » à vie).
            if case CalendarError.verificationFailed = error { throw error }
            try update(key) { $0.status = .failed; $0.reason = error.localizedDescription }
            throw error
        }
    }

    /// Après une panne : une écriture « en cours » est vérifiée dans l'agenda avant toute nouvelle tentative (jamais de doublon).
    public func recoverPending() async {
        guard let pending = try? load().entries.values.filter({ $0.status == .pending }) else { return }
        for entry in pending {
            do {
                let nearby = try await writer.events(around: entry.start, window: 2 * 3600)
                if let found = nearby.first(where: { abs($0.start.timeIntervalSince(entry.start)) < 1 && $0.title == entry.title }) {
                    try update(entry.id) { $0.status = .added; $0.eventIdentifier = found.identifier }
                } else {
                    try await add(entry.id)
                }
            } catch { report(error) }
        }
        publish()
    }

    // MARK: Actions de l'utilisateur

    /// L'utilisateur accepte une suggestion (éventuellement en précisant l'heure). Exige seulement l'accès macOS à l'agenda.
    public func accept(_ id: String, start override: Date? = nil) async throws {
        guard var entry = try load().entries[id], [.suggested, .failed, .dismissed].contains(entry.status) else { throw CalendarError.unknownEntry }
        guard await writer.authorization() == .authorized else { throw CalendarError.notPermitted("Autorisez l'accès à l'agenda dans Réglages Système.") }
        if let override {
            let duration = entry.end.timeIntervalSince(entry.start)
            entry.start = override; entry.end = override.addingTimeInterval(duration); entry.hasExplicitTime = true
            var ledger = try load(); ledger.entries[id] = entry; try save(ledger)
        }
        try await add(id)
        publish()
    }

    public func dismiss(_ id: String) throws {
        try update(id) { $0.status = .dismissed; $0.reason = "ignoré par l'utilisateur" }
        publish()
    }

    /// Supprime de l'agenda **uniquement** l'événement que GHOST a créé (identifiant du registre).
    public func undo(_ id: String) async throws {
        guard let entry = try load().entries[id], entry.status == .added, let identifier = entry.eventIdentifier else { throw CalendarError.unknownEntry }
        guard await writer.authorization() == .authorized else { throw CalendarError.notPermitted("Autorisez l'accès à l'agenda dans Réglages Système.") }
        if try await writer.fetch(identifier) != nil { try await writer.delete(identifier) }
        try update(id) { $0.status = .undone; $0.reason = "ajout annulé par l'utilisateur" }
        publish()
    }

    // MARK: Données

    public func deleteMemory() async throws {
        ledger = CalendarLedger()
        try save(CalendarLedger())
        publish()
    }

    // MARK: Aides et stockage

    static func key(title: String, start: Date) -> String {
        let rounded = Int(start.timeIntervalSince1970 / 900)
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return String(Digest.sha256(Data("\(normalized)|\(rounded)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        func tokens(_ s: String) -> Set<String> {
            Set(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.5
    }

    private func update(_ id: String, _ change: (inout CalendarEntry) -> Void) throws {
        var ledger = try load()
        guard var entry = ledger.entries[id] else { throw CalendarError.unknownEntry }
        change(&entry); entry.updatedAt = clock()
        ledger.entries[id] = entry
        try save(ledger)
    }
    private func load() throws -> CalendarLedger {
        if let ledger { return ledger }
        var loaded = CalendarLedger()
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            guard let value = try? decoder.decode(CalendarLedger.self, from: data), value.schemaVersion == 1 else {
                throw CalendarError.storage("Registre de l'agenda illisible ou d'une autre version ; fichier conservé.")
            }
            loaded = value
        }
        ledger = loaded
        return loaded
    }
    private func save(_ value: CalendarLedger) throws {
        if let url {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = .sortedKeys
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(value).write(to: url, options: .atomic)
            } catch { throw CalendarError.storage("Écriture du registre de l'agenda impossible : \(error.localizedDescription)") }
        }
        ledger = value
    }
    private func publish() { if let all = try? entries() { continuation.yield(.entries(all)) } }
    private func report(_ error: any Error) { continuation.yield(.issue(error.localizedDescription)) }
}
