import Foundation
import GhostBrain
import GhostContext
import GhostPerception

public enum MindUpdate: Sendable { case state(MindState), issue(String) }

/// L'intelligence qui agit : à partir d'une mission du Brain, comprend ce qui est demandé et prépare le travail.
///
/// - **Autonome sur ce qui reste chez soi** : rédiger un brouillon ne demande aucune validation.
/// - **Jamais autonome sur ce qui engage l'utilisateur** : un mail ne part que sur le clic « Envoyer » (`send(_:confirmedByUser:)`
///   refuse sans cette confirmation). Aucune autre voie d'envoi n'existe.
/// - Un brouillon n'est jamais recréé deux fois pour la même mission, et un envoi interrompu n'est jamais rejoué tout seul.
public actor MindEngine: PerceptionEventConsumer {
    public nonisolated let updates: AsyncStream<MindUpdate>
    private let continuation: AsyncStream<MindUpdate>.Continuation
    private let brain: BrainEngine
    private let context: ContextEngine
    private let trust: TrustEngine
    private let models: [LanguageModel]
    private let sender: MailSender
    private let searcher: PlaceSearcher?
    private let output: OutputWriter?
    private let homeArea: @Sendable () -> String?
    private let url: URL?
    private let userName: String
    private let clock: @Sendable () -> Date
    private var state: MindState?
    public private(set) var autonomous = true

    public init(profile: GhostProfile, brain: BrainEngine, context: ContextEngine, trust: TrustEngine, models: [LanguageModel],
                sender: MailSender, userName: String, searcher: PlaceSearcher? = nil, output: OutputWriter? = nil, homeArea: @escaping @Sendable () -> String? = { nil },
                persistent: Bool = true, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.brain = brain; self.context = context; self.trust = trust; self.models = models; self.sender = sender
        self.searcher = searcher; self.output = output; self.homeArea = homeArea
        self.userName = userName; self.clock = clock
        url = persistent ? profile.directory.appendingPathComponent("mind.json") : nil
        (updates, continuation) = AsyncStream.makeStream(of: MindUpdate.self, bufferingPolicy: .bufferingNewest(20))
    }
    deinit { continuation.finish() }

    public func setAutonomous(_ value: Bool) { autonomous = value }
    public func snapshot() throws -> MindState { try load() }

    /// Intelligence utilisable : la première disponible (locale d'abord) ; sinon la raison de l'indisponibilité.
    public func modelStatus() async -> (name: String?, availability: LanguageModelAvailability) {
        var reason: String?
        for model in models {
            switch await model.availability() {
            case .available: return (model.name, .available)
            case .unavailable(let r): reason = reason ?? r
            }
        }
        return (nil, .unavailable(reason ?? "Aucun modèle de langage."))
    }

    // MARK: Perception

    public func consume(_ events: [GhostEvent]) async {
        guard autonomous else { return }
        let ids = Set(events.map(\.id))
        guard let missions = try? await brain.snapshot().missions.values else { return }
        for mission in missions.sorted(by: { $0.createdAt < $1.createdAt })
        where mission.isOpen && mission.triggers.contains(where: { ids.contains($0.eventID) }) {
            do { try await handle(mission) } catch { report(error) }
        }
        publish()
    }

    /// Comprend la mission et prépare le travail correspondant (idempotent).
    public func handle(_ mission: Mission) async throws {
        let current = try load()
        guard current.handled[mission.id] == nil else { return }
        let request = mission.triggers.last?.excerpt ?? mission.title
        var intent = IntentClassifier.classify(request)
        if case .unsupported = intent { intent = IntentClassifier.classify(mission.title) }
        switch intent {
        case .writeMessage(let recipient, let topic):
            try await draftMail(mission: mission, request: request, recipient: recipient, topic: topic)
        case .findPlaces(let query, let area, let when):
            try await searchPlaces(mission: mission, request: request, query: query, area: area, when: when)
        case .createLogo(let brief):
            try await createArtifact(mission: mission, request: request, kind: .logo, brief: brief)
        case .createDocument(let brief):
            try await createArtifact(mission: mission, request: request, kind: .document, brief: brief)
        case .unsupported:
            return   // la mission reste simplement proposée dans « Missions »
        }
    }

    // MARK: Mail

    private func draftMail(mission: Mission, request: String, recipient: String?, topic: String) async throws {
        let graph = try await context.snapshot()
        let match = RecipientResolver.resolve(hint: recipient, in: graph, namespace: mission.namespace)
        let name = match?.name ?? recipient
        let made = await generate(request: request, recipientName: name, recipientEmail: match?.email, topic: topic)
        var note = made.note
        if match == nil {
            let missing = "Destinataire à préciser : aucune adresse connue" + (recipient.map { " pour « \($0) »" } ?? "") + "."
            note = [note, missing].compactMap { $0 }.joined(separator: " ")
        }
        let id = String(Digest.sha256(Data(("mail|" + mission.id).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        let now = clock()
        let draft = MailDraft(id: id, missionID: mission.id, recipientName: name, recipientEmail: match?.email, subject: made.subject, body: made.body,
                              status: made.usedModel ? .ready : .needsModel, version: 1, generatedBy: made.by, basis: request, note: note,
                              createdAt: now, updatedAt: now)
        var s = try load()
        s.drafts[id] = draft; s.handled[mission.id] = id
        try save(s)
    }

    private struct Made { var subject: String; var body: String; var by: String; var usedModel: Bool; var note: String? }

    private func generate(request: String, recipientName: String?, recipientEmail: String?, topic: String) async -> Made {
        var firstReason: String?
        for model in models {
            if case .unavailable(let reason) = await model.availability() { firstReason = firstReason ?? reason; continue }
            var prompt = EmailDrafter.prompt(request: request, recipient: recipientName, topic: topic, user: userName)
            var mask: ReversibleMask?
            if !model.isLocal {   // modèle externe : noms et adresses masqués avant l'envoi, restaurés ici
                // Noms complets ET prénoms : « Paul » seul dans la demande doit disparaître comme « Paul Martin ».
                var names: [String] = []
                for full in [recipientName, userName].compactMap({ $0 }) {
                    names.append(full); names += full.split(separator: " ").map(String.init).filter { $0.count > 2 }
                }
                let masked = ReversibleMask.mask(prompt, names: Array(Set(names)), emails: [recipientEmail].compactMap { $0 })
                prompt = masked.0; mask = masked.1
            }
            do {
                let output = try await model.generate(system: EmailDrafter.system, prompt: prompt)
                if let content = EmailDrafter.parse(mask?.restore(output) ?? output) {
                    return Made(subject: content.subject, body: content.body, by: model.name + (model.isSimulated ? " (SIMULÉ)" : ""), usedModel: true, note: nil)
                }
                firstReason = firstReason ?? "Réponse du modèle inexploitable."
            } catch { firstReason = firstReason ?? error.localizedDescription }
        }
        let simple = EmailDrafter.simplified(recipient: recipientName, topic: topic, user: userName)
        return Made(subject: simple.subject, body: simple.body, by: "brouillon simplifié (sans IA)", usedModel: false,
                    note: "Brouillon simplifié : " + (firstReason ?? "aucun modèle de langage disponible.") + " Utilisez « Refaire » une fois le modèle disponible.")
    }

    // MARK: Création (logos, documents)

    private func createArtifact(mission: Mission, request: String, kind: CreationKind, brief: String) async throws {
        let id = String(Digest.sha256(Data(("create|" + mission.id).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        let creation = await runCreation(id: id, missionID: mission.id, kind: kind, request: request, brief: brief, version: 1, createdAt: clock())
        var s = try load()
        s.creations[id] = creation; s.handled[mission.id] = id
        try save(s)
    }

    private func runCreation(id: String, missionID: String, kind: CreationKind, request: String, brief: String, version: Int, createdAt: Date) async -> Creation {
        var title = kind == .logo ? "Logo" : "Document"
        func make(_ status: CreationStatus, paths: [String] = [], by: String? = nil, note: String? = nil) -> Creation {
            Creation(id: id, missionID: missionID, kind: kind, title: title, basis: request, status: status, paths: paths, generatedBy: by, note: note,
                     version: version, hidden: false, createdAt: createdAt, updatedAt: clock())
        }
        guard let output, output.folderName != nil else {
            return make(.needsFolder, note: "Choisissez le dossier où GHOST range ce qu'il crée (Sources ▸ Création), puis « Refaire ».")
        }
        var reason: String?
        for model in models {
            if case .unavailable(let r) = await model.availability() { reason = reason ?? r; continue }
            var prompt = CreationPrompts.prompt(request: request, brief: brief)
            var mask: ReversibleMask?
            if !model.isLocal {
                let masked = ReversibleMask.mask(prompt, names: [userName] + userName.split(separator: " ").map(String.init).filter { $0.count > 2 }, emails: [])
                prompt = masked.0; mask = masked.1
            }
            do {
                let raw = try await model.generate(system: kind == .logo ? CreationPrompts.logoSystem : CreationPrompts.documentSystem, prompt: prompt)
                let text = mask?.restore(raw) ?? raw
                let by = model.name + (model.isSimulated ? " (SIMULÉ)" : "")
                #if canImport(AppKit)
                if kind == .logo {
                    guard let svg = SVGGuard.extract(text) else { reason = reason ?? "Le modèle n'a pas produit de SVG."; continue }
                    if let problem = SVGGuard.problem(svg) { reason = reason ?? problem; continue }
                    let rendered = SVGGuard.render(svg)
                    guard let png = rendered.png else { reason = reason ?? rendered.problem; continue }
                    let name = "Logo GHOST"
                    let svgURL = try output.write(Data(svg.utf8), preferredName: name + ".svg")
                    let pngURL = try output.write(png, preferredName: ((svgURL.lastPathComponent as NSString).deletingPathExtension) + ".png")
                    return make(.done, paths: [svgURL.path, pngURL.path], by: by)
                } else {
                    guard CreationPrompts.validDocument(text), let rtf = MarkdownRTF.render(text) else { reason = reason ?? "Document inexploitable."; continue }
                    title = CreationPrompts.title(fromMarkdown: text, fallback: "Document")
                    let url = try output.write(rtf, preferredName: title + ".rtf")
                    return make(.done, paths: [url.path], by: by)
                }
                #endif
            } catch { reason = reason ?? error.localizedDescription }
        }
        return make(models.isEmpty || reason == nil || reason?.contains("Apple Intelligence") == true ? .needsModel : .failed,
                    note: (reason ?? "Aucun modèle de langage disponible.") + " Rien n'a été inventé : « Refaire » dès que c'est possible.")
    }

    public func redoCreation(_ id: String) async throws {
        var s = try load()
        guard let old = s.creations[id] else { throw MindError.invalid("Création introuvable.") }
        var brief = old.basis
        switch IntentClassifier.classify(old.basis) { case .createLogo(let b), .createDocument(let b): brief = b; default: break }
        var new = await runCreation(id: id, missionID: old.missionID, kind: old.kind, request: old.basis, brief: brief, version: old.version + 1, createdAt: old.createdAt)
        new.paths = old.status == .done && new.status != .done ? old.paths : new.paths   // l'ancienne version reste consultable si la nouvelle échoue
        s.creations[id] = new
        try save(s); publish()
    }

    public func hideCreation(_ id: String) throws {
        var s = try load()
        guard var creation = s.creations[id] else { throw MindError.invalid("Création introuvable.") }
        creation.hidden = true; s.creations[id] = creation
        try save(s); publish()
    }

    // MARK: Recherche de lieux

    public static let searchSource = SourceID("search")

    private func searchPlaces(mission: Mission, request: String, query: String, area: String?, when: String?) async throws {
        let id = String(Digest.sha256(Data(("search|" + mission.id).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        let search = await runSearch(id: id, missionID: mission.id, request: request, query: query, area: area, when: when)
        var s = try load()
        s.searches[id] = search; s.handled[mission.id] = id
        try save(s)
    }

    private func runSearch(id: String, missionID: String, request: String, query: String, area: String?, when: String?) async -> PlaceSearch {
        func make(_ status: PlaceSearchStatus, _ results: [PlaceResult] = [], note: String? = nil, area: String? = area) -> PlaceSearch {
            PlaceSearch(id: id, missionID: missionID, query: query, area: area, when: when, basis: request, status: status, results: results,
                        note: note, hidden: false, searchedAt: clock())
        }
        guard await trust.isAuthorized(Self.searchSource, .searchOnline) else {
            return make(.notAuthorized, note: "La recherche en ligne n'est pas autorisée : activez-la dans Sources ▸ Recherche.")
        }
        let zone = (area == nil || area == "chez nous") ? (area == nil ? nil : homeArea()) : area
        guard let zone, !zone.trimmingCharacters(in: .whitespaces).isEmpty else {
            return make(.needsArea, note: area == "chez nous"
                        ? "« Chez nous » : indiquez votre quartier ou votre ville dans Sources ▸ Recherche pour que GHOST sache où chercher."
                        : "Aucune zone précisée : indiquez où chercher.")
        }
        guard let searcher else { return make(.failed, note: "Aucun service de recherche disponible.", area: zone) }
        do {
            let results = try await searcher.search(query: query, area: zone)
            await trust.accessLog.record(Self.searchSource, operation: "places.search", target: "« \(query) » autour de « \(zone) »", outcome: .allowed)
            return results.isEmpty ? make(.noResults, note: "Aucun résultat pour « \(query) » autour de « \(zone) ».", area: zone) : make(.done, results, area: zone)
        } catch {
            await trust.accessLog.record(Self.searchSource, operation: "places.search", target: "« \(query) »", outcome: .failed, detail: error.localizedDescription)
            return make(.failed, note: error.localizedDescription, area: zone)
        }
    }

    public func rerunSearch(_ id: String) async throws {
        var s = try load()
        guard let old = s.searches[id] else { throw MindError.invalid("Recherche introuvable.") }
        var new = await runSearch(id: id, missionID: old.missionID, request: old.basis, query: old.query, area: old.area, when: old.when)
        new.hidden = false
        s.searches[id] = new
        try save(s); publish()
    }

    public func hideSearch(_ id: String) throws {
        var s = try load()
        guard var search = s.searches[id] else { throw MindError.invalid("Recherche introuvable.") }
        search.hidden = true; s.searches[id] = search
        try save(s); publish()
    }

    // MARK: Actions de l'utilisateur

    /// Envoie le mail. **Exige la confirmation explicite de l'utilisateur** (bouton « Envoyer »). Jamais rejoué.
    public func send(_ id: String, confirmedByUser: Bool) async throws {
        guard confirmedByUser else { throw MindError.notAllowed("Un envoi exige le clic de l'utilisateur sur « Envoyer ».") }
        var s = try load()
        guard var draft = s.drafts[id] else { throw MindError.invalid("Brouillon introuvable.") }
        guard draft.canSend, let to = draft.recipientEmail else {
            throw MindError.notAllowed(draft.status == .sent ? "Ce mail a déjà été envoyé." : "Envoi impossible : vérifiez le destinataire, l'objet et le texte.")
        }
        draft.status = .sending; draft.updatedAt = clock(); s.drafts[id] = draft
        try save(s)   // l'intention est notée AVANT l'envoi : une interruption ne provoque jamais un second envoi
        do { try await sender.send(to: to, subject: draft.subject, body: draft.body) }
        catch {
            draft.status = .failed; draft.note = error.localizedDescription; draft.updatedAt = clock()
            s.drafts[id] = draft; try? save(s); publish()
            throw error
        }
        draft.status = .sent; draft.note = nil; draft.updatedAt = clock(); s.drafts[id] = draft
        state = s; try? save(s)
        await trust.accessLog.record(SourceID("mind"), operation: "mail.send", target: Self.domain(of: to), outcome: .allowed, detail: "envoi confirmé par l'utilisateur")
        publish()
    }

    public func redo(_ id: String) async throws {
        var s = try load()
        guard var draft = s.drafts[id], [.ready, .needsModel, .failed, .cancelled].contains(draft.status) else { throw MindError.invalid("Ce brouillon ne peut pas être refait.") }
        var topic = draft.basis
        if case .writeMessage(_, let t) = IntentClassifier.classify(draft.basis) { topic = t }
        let made = await generate(request: draft.basis, recipientName: draft.recipientName, recipientEmail: draft.recipientEmail, topic: topic)
        draft.subject = made.subject; draft.body = made.body; draft.generatedBy = made.by; draft.note = made.note
        draft.status = made.usedModel ? .ready : .needsModel; draft.version += 1; draft.updatedAt = clock()
        s.drafts[id] = draft
        try save(s); publish()
    }

    public func cancel(_ id: String) throws {
        var s = try load()
        guard var draft = s.drafts[id], ![.sending, .sent].contains(draft.status) else { throw MindError.invalid("Ce brouillon ne peut plus être annulé.") }
        draft.status = .cancelled; draft.updatedAt = clock(); s.drafts[id] = draft
        try save(s); publish()
    }

    /// L'utilisateur corrige destinataire, objet ou texte ; un brouillon relu par lui est considéré prêt.
    public func edit(_ id: String, to email: String?, subject: String, body: String) throws {
        var s = try load()
        guard var draft = s.drafts[id], ![.sending, .sent].contains(draft.status) else { throw MindError.invalid("Ce brouillon ne peut plus être modifié.") }
        draft.recipientEmail = email?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        draft.subject = String(subject.prefix(140)); draft.body = String(body.prefix(4_000))
        if draft.status == .needsModel || draft.status == .failed || draft.status == .cancelled { draft.status = .ready }
        draft.note = MailDraft.isValidAddress(draft.recipientEmail) ? nil : "Adresse du destinataire à préciser."
        draft.updatedAt = clock(); s.drafts[id] = draft
        try save(s); publish()
    }

    // MARK: Reprise et données

    /// Un envoi « en cours » à la relance : GHOST ne le rejoue pas, il demande de vérifier dans Mail.
    public func recoverInterrupted() {
        guard var s = try? load(), s.drafts.values.contains(where: { $0.status == .sending }) else { return }
        for (id, var d) in s.drafts where d.status == .sending {
            d.status = .failed
            d.note = "Envoi interrompu : vérifiez le dossier Envoyés de Mail avant de réessayer. GHOST ne renvoie jamais seul."
            s.drafts[id] = d
        }
        try? save(s); publish()
    }

    public func deleteMemory() async throws {
        try save(MindState()); publish()
    }

    /// Retire les brouillons dont la mission a disparu (source révoquée sans conservation).
    public func sourceWasRevoked(_ source: SourceID, retainHistory: Bool) async throws {
        guard !retainHistory else { return }
        let alive = Set(try await brain.snapshot().missions.keys)
        var s = try load()
        let orphans = s.drafts.filter { !alive.contains($0.value.missionID) }.map(\.key)
        let orphanSearches = s.searches.filter { !alive.contains($0.value.missionID) }.map(\.key)
        let orphanCreations = s.creations.filter { !alive.contains($0.value.missionID) }.map(\.key)
        guard !orphans.isEmpty || !orphanSearches.isEmpty || !orphanCreations.isEmpty else { return }
        for id in orphanCreations { s.creations[id] = nil }   // les fichiers déjà créés restent dans le dossier de l'utilisateur
        for id in orphans { s.drafts[id] = nil }
        for id in orphanSearches { s.searches[id] = nil }
        s.handled = s.handled.filter { alive.contains($0.key) }
        try save(s); publish()
    }

    // MARK: Stockage

    static func domain(of email: String) -> String { email.split(separator: "@").last.map(String.init) ?? "?" }

    private func load() throws -> MindState {
        if let state { return state }
        var loaded = MindState()
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            guard let data = try? Data(contentsOf: url), let value = try? decoder.decode(MindState.self, from: data), value.schemaVersion == 1 else {
                throw MindError.storage("Fichier des brouillons illisible ou d'une autre version ; il est conservé tel quel.")
            }
            loaded = value
        }
        state = loaded
        return loaded
    }
    private func save(_ value: MindState) throws {
        if let url {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = .sortedKeys
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(value).write(to: url, options: .atomic)
            } catch { throw MindError.storage("Écriture des brouillons impossible : \(error.localizedDescription)") }
        }
        state = value
    }
    private func publish() { if let s = try? load() { continuation.yield(.state(s)) } }
    private func report(_ error: any Error) { continuation.yield(.issue(error.localizedDescription)) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
