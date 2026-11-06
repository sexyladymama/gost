import Foundation
import GhostPerception
import GhostContext
import GhostAutonomy
import GhostMind
#if canImport(AppKit)
import AppKit
#endif

/// Dossier autorisé par l'utilisateur : GHOST y lit des fichiers texte et y crée ses résultats, sans jamais écraser.
public protocol CoreDocumentStore: Sendable {
    var isConfigured: Bool { get }
    func list() throws -> [String]
    func read(_ name: String) throws -> Data
    func write(_ data: Data, preferredName: String) throws -> String
}

/// Lecture et écriture dans le seul dossier choisi (même dossier que « Création »), sans suivre de lien ni sortir du dossier.
public struct FolderDocumentStore: CoreDocumentStore {
    private let writer: FolderOutputWriter
    public static let maxBytes = 200_000
    public static let allowedExtensions: Set<String> = ["md", "txt", "csv", "tsv", "rtf", "svg"]
    public init(writer: FolderOutputWriter) { self.writer = writer }
    public var isConfigured: Bool { writer.folderURL != nil }

    public func list() throws -> [String] {
        guard let folder = writer.folderURL else { throw CoreError.unavailable("Aucun dossier autorisé : choisissez-le dans Sources ▸ Création.") }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return names.filter { Self.allowedExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
            .filter { (try? read($0, limit: 1)) != nil }.sorted().prefix(60).map { $0 }
    }

    public func read(_ name: String) throws -> Data { try read(name, limit: Self.maxBytes) }

    private func read(_ name: String, limit: Int) throws -> Data {
        guard let folder = writer.folderURL else { throw CoreError.unavailable("Aucun dossier autorisé.") }
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != "..", !name.hasPrefix(".") else { throw CoreError.invalid("Nom de fichier interdit.") }
        let fd = open(folder.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CoreError.invalid("Fichier introuvable : \(name).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CoreError.invalid("Ce n'est pas un fichier ordinaire.") }
        guard info.st_size <= Self.maxBytes else { throw CoreError.invalid("Fichier trop volumineux (\(Self.maxBytes / 1000) Ko maximum).") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < limit {
            let n = Darwin.read(fd, &buffer, min(buffer.count, limit - data.count))
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    public func write(_ data: Data, preferredName: String) throws -> String {
        try writer.write(data, preferredName: preferredName).lastPathComponent
    }
}

/// Résultat d'un outil : toujours une **donnée** pour le modèle, jamais une consigne.
struct ToolOutcome: Sendable {
    var status: String
    var content: String
    var artifact: AgentArtifact?
    var sources: [AgentEvidence] = []
}

/// Les outils réels de GHOST Core. Chaque appel est exécuté ici, après validation et autorisation par le coordinateur.
struct CoreToolbox: Sendable {
    var context: ContextEngine
    var mind: MindEngine?
    var trust: TrustEngine
    var web: WebSearcher?
    var places: PlaceSearcher?
    var documents: CoreDocumentStore?
    var clock: @Sendable () -> Date

    static func line(_ node: ContextNode) -> String {
        "[\(node.kind.rawValue) · \(node.status.label) · \(Int(node.confidence * 100)) %] \(node.title.prefix(160))"
    }
    func evidence(_ node: ContextNode, kind: String) -> AgentEvidence {
        AgentEvidence(id: node.id, kind: kind, text: String(node.title.prefix(300)), status: node.status, confidence: node.confidence,
                      updatedAt: node.updatedAt, sourceIDs: [node.id], userConfirmed: node.properties["userEdited"] == "true")
    }

    private func memory(_ query: String, session: AgentSession, kinds: Set<ContextEntityKind>?) async throws -> [ContextNode] {
        // Jamais de mélange des contextes : seuls les nœuds de l'espace de la mission sont lus.
        try await context.search(query).filter { $0.namespace == session.namespace && (kinds?.contains($0.kind) ?? true) }.prefix(8).map { $0 }
    }

    func run(_ call: AgentToolCall, session: AgentSession) async throws -> ToolOutcome {
        let args = call.arguments
        switch call.tool {
        case .searchMemory, .findConversations, .inspectProject, .retrieveDeadlines:
            let kinds: Set<ContextEntityKind>? = call.tool == .findConversations ? [.conversation, .event] : call.tool == .inspectProject ? [.project] : call.tool == .retrieveDeadlines ? [.deadline, .taskCandidate] : nil
            var nodes = try await memory(args["query"] ?? "", session: session, kinds: kinds)
            if let wanted = args["kind"] { nodes = nodes.filter { $0.kind.rawValue.localizedCaseInsensitiveContains(wanted) } }
            var lines = nodes.map(Self.line)
            if call.tool == .inspectProject, let project = nodes.first, let summary = try await context.projectSummary(project.id) {
                let extra = (summary.people + summary.documents + summary.deadlines + summary.decisions).prefix(8).map(Self.line)
                lines += extra
            }
            return ToolOutcome(status: lines.isEmpty ? "empty" : "ok",
                               content: lines.isEmpty ? "Aucune information correspondante dans la mémoire autorisée." : lines.joined(separator: "\n"),
                               sources: nodes.map { evidence($0, kind: call.tool.rawValue) })
        case .listDocuments:
            guard let documents, documents.isConfigured else { return ToolOutcome(status: "unavailable", content: "Aucun dossier autorisé : l'utilisateur doit le choisir dans Sources ▸ Création.") }
            let names = try documents.list()
            return ToolOutcome(status: names.isEmpty ? "empty" : "ok", content: names.isEmpty ? "Le dossier autorisé ne contient aucun fichier texte lisible." : names.joined(separator: "\n"))
        case .readDocument:
            guard let documents, documents.isConfigured else { return ToolOutcome(status: "unavailable", content: "Aucun dossier autorisé.") }
            let name = args["fileName"] ?? ""
            let data = try documents.read(name)
            guard let text = String(data: data, encoding: .utf8) else { throw CoreError.invalid("Le fichier n'est pas du texte UTF-8.") }
            let hash = ExecutionIdentity.hash(data)
            let proof = AgentEvidence(id: "doc:" + name, kind: "document", text: "Fichier « \(name) » lu (empreinte \(hash.prefix(12)))", status: .confirmed, confidence: 1,
                                      updatedAt: clock(), sourceIDs: ["doc:" + name], userConfirmed: false)
            return ToolOutcome(status: "ok", content: String(text.prefix(6_000)) + (text.count > 6_000 ? "\n[… document tronqué]" : ""), sources: [proof])
        case .createDocument:
            guard let documents, documents.isConfigured else { return ToolOutcome(status: "unavailable", content: "Aucun dossier de sortie autorisé : choisissez-le dans Sources ▸ Création.") }
            var text = args["text"] ?? ""
            let known = session.evidence.filter { $0.kind == "document" || $0.kind == "search_memory" || $0.kind == "web" }.prefix(12)
            if !known.isEmpty { text += "\n\n---\nSources consultées par GHOST :\n" + known.map { "- \($0.text)" }.joined(separator: "\n") }
            let data = Data(text.utf8)
            guard data.count <= 120_000 else { throw CoreError.invalid("Document trop volumineux.") }
            let title = text.split(separator: "\n").first(where: { $0.hasPrefix("#") }).map { $0.drop(while: { $0 == "#" || $0 == " " }).replacingOccurrences(of: "*", with: "") } ?? "Résultat GHOST"
            let name = try documents.write(data, preferredName: String(title.prefix(60)) + ".md")
            let back = try documents.read(name)   // relecture réelle avant d'annoncer quoi que ce soit
            guard back == data else { throw CoreError.invalid("La relecture du fichier créé ne correspond pas : résultat non validé.") }
            let hash = ExecutionIdentity.hash(back)
            return ToolOutcome(status: "ok", content: "Document « \(name) » créé et relu (\(back.count) octets, empreinte \(hash.prefix(12))).",
                               artifact: AgentArtifact(fileName: name, hash: hash, verified: true))
        case .verifyArtifact:
            guard let documents, documents.isConfigured else { return ToolOutcome(status: "unavailable", content: "Aucun dossier autorisé.") }
            let name = args["fileName"] ?? ""
            guard let known = session.receipts.compactMap(\.artifact).first(where: { $0.fileName == name }) else {
                throw CoreError.invalid("Seuls les résultats créés par cette session peuvent être vérifiés.")
            }
            let ok = ExecutionIdentity.hash(try documents.read(name)) == known.hash
            return ToolOutcome(status: ok ? "ok" : "failed", content: ok ? "Fichier « \(name) » identique à celui créé." : "Le fichier « \(name) » a changé depuis sa création.",
                               artifact: AgentArtifact(fileName: name, hash: known.hash, verified: ok))
        case .draftEmail:
            guard let mind else { return ToolOutcome(status: "unavailable", content: "Le moteur de rédaction n'est pas disponible.") }
            let instruction = args["instruction"] ?? ""
            let draft = try await mind.prepareDraft(missionID: session.missionID, key: session.id + "|" + call.fingerprint, namespace: session.namespace,
                                                    request: instruction, recipient: args["recipient"], topic: instruction)
            return ToolOutcome(status: draft.status == .ready ? "ok" : "needs_model",
                               content: "Brouillon \(draft.id) \(draft.status == .ready ? "prêt" : "simplifié") — à : \(draft.recipientEmail ?? draft.recipientName ?? "à préciser") — objet : \(draft.subject)\n\(draft.body.prefix(1_200))\nJAMAIS envoyé : l'envoi exige l'accord de l'utilisateur (outil send_draft).")
        case .sendDraft:
            guard let mind else { return ToolOutcome(status: "unavailable", content: "Le moteur de rédaction n'est pas disponible.") }
            try await mind.send(args["draftID"] ?? "", confirmedByUser: true)   // appelé uniquement après l'approbation liée à l'empreinte exacte
            return ToolOutcome(status: "ok", content: "Mail envoyé avec l'accord de l'utilisateur.")
        case .searchWeb:
            guard await trust.isAuthorized(MindEngine.searchSource, .searchOnline) else { return ToolOutcome(status: "denied", content: "La recherche en ligne n'est pas autorisée (Sources ▸ Recherche).") }
            guard let web else { return ToolOutcome(status: "unavailable", content: "Aucun service de recherche web.") }
            let results = try await web.search(query: args["query"] ?? "")
            await trust.accessLog.record(MindEngine.searchSource, operation: "core.web.search", target: "« \(String((args["query"] ?? "").prefix(60))) »", outcome: .allowed)
            let proofs = results.prefix(6).map { AgentEvidence(id: $0.url ?? $0.id, kind: "web", text: "\($0.name) — \($0.url ?? "")", status: .hypothesis, confidence: 0.5, updatedAt: clock(), sourceIDs: [$0.url ?? $0.id], userConfirmed: false) }
            return ToolOutcome(status: results.isEmpty ? "empty" : "ok", content: results.isEmpty ? "Aucun résultat." : results.prefix(6).map { "• \($0.name) — \($0.address.prefix(200)) — \($0.url ?? "")" }.joined(separator: "\n"), sources: Array(proofs))
        case .searchPlaces:
            guard await trust.isAuthorized(MindEngine.searchSource, .searchOnline) else { return ToolOutcome(status: "denied", content: "La recherche en ligne n'est pas autorisée (Sources ▸ Recherche).") }
            guard let places else { return ToolOutcome(status: "unavailable", content: "Aucun service de lieux.") }
            let results = try await places.search(query: args["query"] ?? "", area: args["area"] ?? "")
            await trust.accessLog.record(MindEngine.searchSource, operation: "core.places.search", target: "« \(String((args["query"] ?? "").prefix(60))) » autour de « \(String((args["area"] ?? "").prefix(60))) »", outcome: .allowed)
            return ToolOutcome(status: results.isEmpty ? "empty" : "ok", content: results.isEmpty ? "Aucun lieu trouvé." : results.prefix(6).map { "• \($0.name) — \($0.address) (\(Int($0.distanceMeters ?? 0)) m)" }.joined(separator: "\n"))
        case .createVisual:
            #if canImport(AppKit)
            guard let documents, documents.isConfigured else { return ToolOutcome(status: "unavailable", content: "Aucun dossier de sortie autorisé.") }
            let svg = args["svg"] ?? ""
            if let problem = SVGGuard.problem(svg) { return ToolOutcome(status: "rejected", content: "SVG refusé : \(problem)") }
            let rendered = SVGGuard.render(svg)
            guard let png = rendered.png else { return ToolOutcome(status: "rejected", content: "SVG inutilisable : \(rendered.problem ?? "rendu vide").") }
            let svgName = try documents.write(Data(svg.utf8), preferredName: "Visuel GHOST.svg")
            _ = try documents.write(png, preferredName: (svgName as NSString).deletingPathExtension + ".png")
            let hash = ExecutionIdentity.hash(try documents.read(svgName))
            return ToolOutcome(status: "ok", content: "Visuel « \(svgName) » créé, validé et rendu en PNG.", artifact: AgentArtifact(fileName: svgName, hash: hash, verified: true))
            #else
            return ToolOutcome(status: "unavailable", content: "Rendu indisponible sur cette plateforme.")
            #endif
        case .rememberPreference:
            let text = (args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = PreferencePolicy.problem(text) { return ToolOutcome(status: "rejected", content: "Préférence refusée : \(problem)") }
            let proposal = AgentEvidence(id: "pref:" + ExecutionIdentity.hash(Data(text.utf8)).prefix(16), kind: "preference_proposal", text: text, status: .hypothesis, confidence: 0.6,
                                         updatedAt: clock(), sourceIDs: [], userConfirmed: false)
            return ToolOutcome(status: "proposed", content: "Proposition enregistrée : elle ne sera mémorisée que si l'utilisateur la confirme.", sources: [proposal])
        case .createSpreadsheet, .createPresentation:
            throw CoreError.unavailable("Outil indisponible.")
        }
    }
}

/// Validation déterministe des propositions de mémoire : le modèle propose, cette règle décide si la proposition peut même être soumise.
enum PreferencePolicy {
    static let sensitive = ["santé", "maladie", "religion", "politique", "orientation", "ethnie", "origine ethnique", "syndicat", "sexuel", "médical", "salaire", "mot de passe", "iban", "carte bancaire"]
    static func problem(_ text: String) -> String? {
        guard (4...400).contains(text.count) else { return "texte de 4 à 400 caractères requis." }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if sensitive.contains(where: { folded.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))) }) {
            return "information sensible : GHOST ne la déduit ni ne la mémorise."
        }
        return nil
    }
}
