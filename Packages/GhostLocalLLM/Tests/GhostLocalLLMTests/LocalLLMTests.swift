import XCTest
import CryptoKit
import GhostBrain
import GhostCore
import GhostMind
import GhostContext
import GhostPerception
@testable import GhostLocalLLM

// MARK: - Sans modèle : grammaire et téléchargement (faux serveur)

final class AgentGrammarTests: XCTestCase {
    func testToolNamesAreReadFromThePromptAndConstrainTheGrammar() {
        let system = "Outils disponibles :\n- search_memory(query, kind?) : chercher\n- create_document(text) : créer\nautre ligne"
        XCTAssertEqual(AgentGrammar.toolNames(in: system), ["search_memory", "create_document"])
        let g = AgentGrammar.gbnf(tools: ["search_memory", "create_document"])
        XCTAssertTrue(g.contains(#""\"search_memory\"" | "\"create_document\"""#))
        XCTAssertEqual(AgentGrammar.actions(in: "x\nActions autorisées maintenant : tool_call, blocked.\ny"), ["tool_call", "blocked"])
        XCTAssertFalse(AgentGrammar.gbnf(tools: [], actions: ["tool_call"]).contains("create_plan"))
        XCTAssertTrue(g.contains("tool_call") && g.contains("final_response") && !g.contains("run_shell"))
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payloads: [String: Data] = [:]
    nonisolated(unsafe) static var ranges: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.lastPathComponent
        guard let data = Self.payloads[name] else { client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self); return }
        var body = data, code = 200
        if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst(6).dropLast()) { Self.ranges.append(range); body = data.dropFirst(start); code = 206 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LocalModelStoreTests: XCTestCase {
    private func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private func make(_ payload: Data, claimedHash: String? = nil) -> (LocalModelStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-store-\(UUID())")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        StubProtocol.payloads = ["fake.gguf": payload]; StubProtocol.ranges = []
        let file = LocalModelFile(name: "fake.gguf", size: Int64(payload.count), sha256: claimedHash ?? hash(payload))
        return (LocalModelStore(baseDirectory: dir, files: [file], baseURL: URL(string: "https://stub.example/")!, session: URLSession(configuration: config)), dir)
    }

    func testDownloadVerifiesAndMarksTheModelInstalled() async throws {
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let (store, dir) = make(payload); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(store.isInstalled)
        let seen = ProgressBox()
        try await store.download { seen.add($0) }
        XCTAssertTrue(store.isInstalled); XCTAssertEqual(seen.last, 1, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.modelPath)), payload)
    }
    func testInterruptedDownloadResumesWithARangeRequest() async throws {
        let payload = Data((0..<2_000_000).map { UInt8($0 % 199) })
        let (store, dir) = make(payload); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try payload.prefix(750_000).write(to: store.directory.appendingPathComponent("fake.gguf.part"))
        try await store.download { _ in }
        XCTAssertEqual(StubProtocol.ranges, ["bytes=750000-"]); XCTAssertTrue(store.isInstalled)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.modelPath)), payload)
    }
    func testAWrongFingerprintDeletesTheFileAndNeverInstalls() async throws {
        let payload = Data(repeating: 7, count: 100_000)
        let (store, dir) = make(payload, claimedHash: String(repeating: "0", count: 64)); defer { try? FileManager.default.removeItem(at: dir) }
        do { try await store.download { _ in }; XCTFail("fichier inattendu accepté") } catch { XCTAssertTrue(error.localizedDescription.contains("Empreinte")) }
        XCTAssertFalse(store.isInstalled); XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelPath))
    }
    func testPinnedModelFilesAreTheDocumentedOnes() {
        XCTAssertEqual(LocalModelStore.files.count, 2); XCTAssertEqual(LocalModelStore.totalBytes, 4_683_073_632)
        XCTAssertEqual(LocalModelStore.revision.count, 40)
    }
}
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0.0
    func add(_ x: Double) { lock.withLock { v = x } }
    var last: Double { lock.withLock { v } }
}

// MARK: - Avec le vrai modèle (téléchargé dans le dossier de GHOST) : GHOST_LIVE=1

final class LiveLocalModelTests: XCTestCase {
    private func installedStore() throws -> LocalModelStore {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/app.ghost.shell/Data/Library/Application Support/GHOST")
        let store = LocalModelStore(baseDirectory: base)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GHOST_LIVE"] == "1", "GHOST_LIVE=1 requis")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: store.modelPath), "modèle non téléchargé")
        if !store.isInstalled { try store.verify() }
        return store
    }

    func testRealModelAnswersAndRespectsTheDecisionGrammar() async throws {
        let provider = LocalOpenModelProvider(store: try installedStore())
        let system = "Tu es un agent. Réponds par UN objet JSON.\nOutils disponibles :\n- search_memory(query) : chercher dans la mémoire\n- create_document(text) : créer un document"
        let started = Date()
        let response = try await provider.complete(ModelRequest(task: .agentStep, system: system, user: "{\"objectif\":\"Retrouve ce que l'on sait sur Atelier Lune\"}", maxOutputTokens: 300))
        print("LOCAL décision en \(String(format: "%.1f", Date().timeIntervalSince(started))) s : \(response.text) | jetons \(response.usage)")
        let decision = try AgentDecisionProbe.parse(response.text)
        XCTAssertTrue(["tool_call", "create_plan"].contains(decision), decision); XCTAssertFalse(response.isSimulated); XCTAssertEqual(response.provider, "ghost-local")
        let text = try await provider.complete(ModelRequest(task: .generate, system: "Tu réponds en français, en une phrase.", user: "Quelle est la capitale de la France ?", maxOutputTokens: 60))
        print("LOCAL texte : \(text.text)")
        XCTAssertTrue(text.text.contains("Paris"))
    }

    func testPromptSpeedWithACoreSizedPrompt() async throws {
        let provider = LocalOpenModelProvider(store: try installedStore())
        let filler = (1...60).map { "- outil_\($0)(query) : description d'un outil de démonstration pour mesurer la lecture d'un long prompt par le modèle." }.joined(separator: "\n")
        let system = "Tu es un agent. Réponds par UN objet JSON.\nActions autorisées maintenant : tool_call, final_response.\nOutils disponibles :\n- search_memory(query) : chercher\n\(filler)"
        for round in 1...3 {
            let started = Date()
            let r = try await provider.complete(ModelRequest(task: .agentStep, system: system, user: "{\"objectif\":\"Retrouve ce que l'on sait sur Atelier Lune (essai \(round))\"}", maxOutputTokens: 200))
            print("SPEED essai \(round) : \(String(format: "%.1f", Date().timeIntervalSince(started))) s, entrée \(r.usage.inputTokens) jetons, sortie \(r.usage.outputTokens) : \(r.text.prefix(120))")
        }
    }

    /// Isole la lenteur : lecture d'un long prompt SANS grammaire, puis AVEC.
    func testEngineLongPromptWithAndWithoutGrammar() throws {
        let store = try installedStore()
        let engine = try LocalLlamaEngine(modelPath: store.modelPath, contextSize: 4096)
        let filler = (1...40).map { "- outil_\($0)(query) : description d'un outil de démonstration." }.joined(separator: "\n")
        let prompt = LocalLlamaEngine.chatPrompt(system: "Tu es un agent. Réponds par un objet JSON {\"action\":\"tool_call\"}.\n" + filler, user: "Objectif : retrouver Atelier Lune.")
        var t = Date()
        let plain = try engine.generate(prompt: prompt, grammar: nil, maxTokens: 20, temperature: 0)
        print("ENGINE sans grammaire : \(String(format: "%.1f", Date().timeIntervalSince(t))) s, prompt \(plain.promptTokens), sortie \(plain.outputTokens)")
        t = Date()
        let g = AgentGrammar.gbnf(tools: ["search_memory", "outil_1"], actions: ["tool_call", "final_response"])
        let guided = try engine.generate(prompt: prompt, grammar: g, maxTokens: 60, temperature: 0.1)
        print("ENGINE avec grammaire : \(String(format: "%.1f", Date().timeIntervalSince(t))) s, sortie \(guided.outputTokens) : \(guided.text.prefix(100))")
    }

    func testRealModelRunsTheBriefingScenarioThroughGhostCore() async throws {
        let store = try installedStore()
        let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "fr_FR"); return c }()
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10))!
        let trust = TrustEngine(accessLog: AccessLog(), clock: { now })
        await trust.grant(SourceID("gmail"), permission: .readMail, scope: "test")
        let profile = GhostProfile(id: "live-local", baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ghost-live-local-\(UUID())"))
        let context = ContextEngine(profile: profile, trust: trust, persistent: false)
        let brain = BrainEngine(profile: profile, context: context, trust: trust, gateway: nil, persistent: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-live-local-docs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Atelier Lune : budget trimestre 12 400 €, deux relances en attente. Contact : Claire Dubois.".utf8).write(to: folder.appendingPathComponent("notes-atelier-lune.md"))
        let source = EventSource(id: SourceID("gmail"), kind: .email, displayName: "Gmail")
        let mail = EmailMessage(id: "m1", from: "Claire Dubois <claire@atelier-lune.example>", to: ["moi@ghost.test"], subject: "Atelier Lune — réunion de demain", date: now,
                                bodyText: "Bonjour, je confirme notre réunion de demain pour le budget de l'Atelier Lune. Pouvez-vous préparer les chiffres du trimestre ?")
        try await context.setScope(.professional, for: SourceID("gmail"))
        try await context.ingest([UnderstandingEngine(deadlines: DeadlineExtractor(calendar: cal)).interpret(EventNormalizer().normalize(.email(mail, account: "moi@ghost.test"), from: source), detectedAt: now)])
        let gateway = ModelGateway(providers: [LocalOpenModelProvider(store: store)], policy: GatewayPolicy(timeout: 150))
        var limits = AgentLimits(); limits.maxSeconds = 420
        let core = CoreCoordinator(profile: profile, brain: brain, context: context, trust: trust, gateway: gateway, mind: nil,
                                   documents: FolderDocumentStore(writer: FolderOutputWriter(folder: folder)), limits: limits, persistent: false, clock: { now })
        let id = try await core.submit(objective: "Prépare un briefing pour ma réunion de demain avec l'Atelier Lune : retrouve ce que l'on sait d'eux, lis mes notes et crée le document.", scope: .professional)
        await core.wait(id)
        let found = try await core.session(id)
        let s = try XCTUnwrap(found)
        print("LOCAL-CORE phase=\(s.phase) itérations=\(s.iterations) outils=\(s.receipts.map { $0.call.tool.rawValue + ":" + $0.status }) simulé=\(s.isSimulated) modèle=\(s.provider ?? "-")/\(s.model ?? "-")")
        print("LOCAL-CORE erreur=\(s.error ?? "-") question=\(s.clarification ?? "-")\nLOCAL-CORE réponse=\(s.answer ?? "-")")
        for h in s.history { print("LOCAL-CORE journal: \(h.message.prefix(220))") }
        print("LOCAL-CORE fichiers=\((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f != "notes-atelier-lune.md" {
            print("LOCAL-CORE document \(f):\n\((try? String(contentsOf: folder.appendingPathComponent(f), encoding: .utf8)) ?? "")")
        }
        XCTAssertFalse(s.isSimulated)
    }
}

/// Lecture minimale d'une décision pour le test (le vrai décodage strict est celui de GHOST CORE).
enum AgentDecisionProbe {
    static func parse(_ text: String) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let action = object["action"] as? String else { throw LocalLLMError.tokenization }
        return action
    }
}
