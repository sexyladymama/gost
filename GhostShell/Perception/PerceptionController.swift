import AppKit
import Observation
import GhostKit
import GhostPerception
import GhostContext
import GhostBrain
import GhostAutonomy
import GhostVision
import GhostMind
import CoreGraphics

/// Configure et pilote les sources de perception depuis l'interface.
///
/// Toute source nécessite une action explicite de l'utilisateur :
/// - « Utiliser la boîte de test » (simulation, aucun accès réseau) ;
/// - « Connecter Gmail » (OAuth Google, portée `gmail.readonly`) ;
/// - « Choisir un dossier » (sélecteur macOS, accès en lecture seule).
///
/// Les réglages non secrets sont conservés dans `UserDefaults` ; les jetons
/// OAuth dans le Trousseau ; les autorisations dans le profil de l'utilisateur.
@MainActor
@Observable
final class PerceptionController {
    enum EmailMode: String {
        case none, simulation, gmail
    }

    private enum Keys {
        static let emailMode = "perception.email.mode"
        static let clientID = "perception.gmail.clientID"
        static let account = "perception.gmail.account"
        static let folderBookmark = "perception.folder.bookmark"
        static let externalModel = "brain.externalModel.enabled"
        static let screenEnabled = "vision.screen.enabled"
        static let calendarAutoAdd = "vision.calendar.autoAdd"
        static let onboardingDone = "vision.onboarding.done"
        static let excludedApps = "vision.excludedApps"
        static let searchEnabled = "mind.search.enabled"
        static let homeArea = "mind.homeArea"
        static let outputBookmark = "mind.output.bookmark"
    }

    @ObservationIgnored let system: PerceptionSystem
    @ObservationIgnored let center: PerceptionCenter
    let context: ContextCenter
    let brain: BrainCenter
    let execution: ExecutionCenter
    let calendar: CalendarCenter
    let mind: MindCenter
    @ObservationIgnored let calendarWriter: CalendarWriter
    @ObservationIgnored private let outputWriter = FolderOutputWriter()
    @ObservationIgnored private var outputAccess: SecurityScopedFolder?
    /// Nom du dossier où GHOST range ses créations (choisi par l'utilisateur).
    private(set) var outputFolderName: String?
    @ObservationIgnored private var executionAccess: [String: [SecurityScopedFolder]] = [:]
    @ObservationIgnored private let gateway: ModelGateway

    private(set) var emailMode: EmailMode
    private(set) var gmailAccount: String?
    private(set) var folderURL: URL?
    private(set) var isConnecting = false
    /// Modèle externe : désactivé par défaut ; ne reçoit que des données masquées.
    private(set) var externalModelEnabled = false
    private(set) var hasModelKey = false
    /// Observation de l'écran (choix de l'utilisateur, consentement donné à l'installation).
    private(set) var screenEnabled = false
    /// Permission « Enregistrement de l'écran » de macOS (accordée par l'utilisateur dans Réglages Système, jamais par GHOST).
    private(set) var screenPermission = false
    private(set) var calendarAutoAdd = false
    private(set) var onboardingDone = false
    /// Applications supplémentaires à ne jamais lire (séparées par des virgules).
    var excludedApps: String { didSet { defaults.set(excludedApps, forKey: Keys.excludedApps) } }
    /// Recherche en ligne (lieux, avec Apple Plans) autorisée par l'utilisateur.
    private(set) var searchEnabled = false
    /// Quartier ou ville de l'utilisateur : sert pour « chez nous ». Reste sur ce Mac.
    var homeArea: String { didSet { defaults.set(homeArea, forKey: Keys.homeArea) } }
    var lastError: String?
    var googleClientID: String {
        didSet { defaults.set(googleClientID, forKey: Keys.clientID) }
    }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private var folderAccess: SecurityScopedFolder?

    /// - Parameter persistent: `false` pour les aperçus SwiftUI (aucune écriture).
    init(persistent: Bool = true) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let profile = GhostProfile.current(baseDirectory: base.appendingPathComponent("GHOST", isDirectory: true))
        system = PerceptionSystem(profile: profile, persistent: persistent)
        center = system.makeCenter()
        context = ContextCenter(engine: ContextEngine(profile: profile, trust: system.trust, persistent: persistent))
        defaults = persistent ? .standard : UserDefaults(suiteName: "ghost.preview") ?? .standard
        secrets = persistent ? KeychainSecretStore(profileID: profile.id) : InMemorySecretStore()
        gateway = ModelGateway(providers: [AnthropicProvider(http: system.http, secrets: secrets)], policy: GatewayPolicy(enabled: false),
                               usageURL: persistent ? profile.directory.appendingPathComponent("model-usage.json") : nil)
        brain = BrainCenter(engine: BrainEngine(profile: profile, context: context.engine, trust: system.trust,
                                                gateway: gateway, persistent: persistent))
        execution = ExecutionCenter(engine: ExecutionEngine(profile: profile, brain: brain.engine, persistent: persistent), profileID: profile.id)
        let writer = EventKitCalendarWriter()
        calendarWriter = writer
        calendar = CalendarCenter(agent: CalendarAgent(writer: writer, trust: system.trust,
                                                       ledgerURL: persistent ? profile.directory.appendingPathComponent("calendar-actions.json") : nil),
                                  writer: writer)
        // Intelligence qui rédige : le modèle intégré à macOS d'abord (sur le Mac), le modèle externe seulement s'il est activé.
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        mind = MindCenter(engine: MindEngine(profile: profile, brain: brain.engine, context: context.engine, trust: system.trust,
                                             models: [OnDeviceLanguageModel(), GatewayLanguageModel(gateway: gateway)],
                                             sender: AppleMailSender(), userName: firstName,
                                             searcher: MapKitPlaceSearcher(), webSearcher: DuckDuckGoSearcher(), output: outputWriter,
                                             homeArea: { [defaults] in defaults.string(forKey: "mind.homeArea") },
                                             persistent: persistent))
        screenEnabled = defaults.bool(forKey: Keys.screenEnabled)
        calendarAutoAdd = defaults.bool(forKey: Keys.calendarAutoAdd)
        onboardingDone = defaults.bool(forKey: Keys.onboardingDone)
        excludedApps = defaults.string(forKey: Keys.excludedApps) ?? ""
        searchEnabled = defaults.bool(forKey: Keys.searchEnabled)
        homeArea = defaults.string(forKey: Keys.homeArea) ?? ""
        screenPermission = ScreenCaptureKitFrameSource.hasPermission
        externalModelEnabled = defaults.bool(forKey: Keys.externalModel)
        hasModelKey = ((try? secrets.load(AnthropicProvider.secretKey)) ?? nil) != nil
        emailMode = EmailMode(rawValue: defaults.string(forKey: Keys.emailMode) ?? "") ?? .none
        googleClientID = defaults.string(forKey: Keys.clientID) ?? ""
        gmailAccount = defaults.string(forKey: Keys.account)
    }

    var screenID: SourceID { SourceID("screen") }
    var gmailID: SourceID { PerceptionSystem.gmailSourceID }
    var folderID: SourceID { PerceptionSystem.folderSourceID }

    func status(of id: SourceID) -> SourceStatus? {
        center.sources.first { $0.id == id }
    }

    // MARK: - Restauration au lancement

    /// Réenregistre les sources autorisées lors d'une session précédente.
    func restoreSources() async {
        defer { Task { await self.initializeContext() } }
        await reconcileConsent()
        switch emailMode {
        case .simulation:
            await registerEmailSource(provider: SimulatedMailProvider())
        case .gmail:
            await registerEmailSource(provider: makeGmailProvider(clientID: googleClientID))
        case .none:
            break
        }
        if screenEnabled { await registerScreenSource() }
        restoreOutputFolder()
        if let bookmark = defaults.data(forKey: Keys.folderBookmark) {
            do {
                let access = try SecurityScopedFolder(bookmark: bookmark)
                if access.isStale, let renewed = try? access.url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(renewed, forKey: Keys.folderBookmark)
                }
                await activateFolder(access)
            } catch {
                lastError = "Le dossier autorisé n'est plus accessible : \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Dossier de création

    private func restoreOutputFolder() {
        guard let bookmark = defaults.data(forKey: Keys.outputBookmark) else { return }
        do {
            let access = try SecurityScopedFolder(bookmark: bookmark)
            outputAccess = access; outputWriter.setFolder(access.url); outputFolderName = access.url.lastPathComponent
        } catch { lastError = "Le dossier de création n'est plus accessible : \(error.localizedDescription). Choisissez-le à nouveau." }
    }

    /// L'utilisateur choisit le dossier où GHOST range ce qu'il crée (le seul où GHOST écrit les logos et documents).
    func chooseOutputFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "GHOST y rangera les logos et documents qu'il crée à votre demande. Il n'écrase jamais un fichier existant."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let access = try SecurityScopedFolder(bookmark: bookmark)
            outputAccess?.stop()
            outputAccess = access; outputWriter.setFolder(access.url); outputFolderName = access.url.lastPathComponent
            defaults.set(bookmark, forKey: Keys.outputBookmark)
        } catch { lastError = Self.describe(error) }
    }

    // MARK: - Écran et agenda

    /// Le consentement est noté deux fois (réglage et autorisation). S'ils divergent — par exemple parce qu'une autre copie de GHOST
    /// a écrasé le fichier des autorisations —, GHOST **n'invente pas** d'autorisation : il désactive la fonction et le dit,
    /// au lieu de réessayer et d'échouer en boucle.
    private func reconcileConsent() async {
        var lost: [String] = []
        if screenEnabled, !(await system.trust.isAuthorized(screenID, .observeScreen)) {
            screenEnabled = false; defaults.set(false, forKey: Keys.screenEnabled); lost.append("de lire l'écran")
        }
        if calendarAutoAdd, !(await system.trust.isAuthorized(CalendarAgent.sourceID, .writeCalendar)) {
            calendarAutoAdd = false; defaults.set(false, forKey: Keys.calendarAutoAdd); lost.append("d'ajouter à l'agenda")
        }
        if searchEnabled, !(await system.trust.isAuthorized(MindEngine.searchSource, .searchOnline)) {
            searchEnabled = false; defaults.set(false, forKey: Keys.searchEnabled); lost.append("de chercher en ligne")
        }
        if !lost.isEmpty {
            lastError = "L'autorisation " + lost.joined(separator: " et ") + " n'était plus enregistrée (une autre copie de GHOST a probablement écrasé le fichier des autorisations). Réactivez-la dans Sources ▸ Écran et Agenda."
        }
    }

    private func registerScreenSource() async {
        let extras = Set(excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let source = ScreenSource(frames: ScreenCaptureKitFrameSource(), recognizer: VisionTextRecognizer(),
                                  policy: PrivacyPolicy(extraExcludedApps: extras), trust: system.trust)
        await center.register(source)
    }

    func refreshScreenPermission() async {
        screenPermission = ScreenCaptureKitFrameSource.hasPermission
        await calendar.reload()
    }

    /// Active ou coupe l'observation de l'écran. L'autorisation macOS est demandée au système : seul l'utilisateur peut l'accorder.
    func setScreenObservation(_ enabled: Bool) async {
        lastError = nil
        if enabled {
            await system.trust.grant(screenID, permission: .observeScreen, scope: "écran")
            if !ScreenCaptureKitFrameSource.hasPermission { _ = CGRequestScreenCaptureAccess() }
            screenPermission = ScreenCaptureKitFrameSource.hasPermission
            screenEnabled = true
            defaults.set(true, forKey: Keys.screenEnabled)
            await registerScreenSource()
        } else {
            screenEnabled = false
            defaults.set(false, forKey: Keys.screenEnabled)
            await center.revoke(screenID, deleteData: false, retainContext: true)
        }
    }

    /// Autorise (ou retire) l'ajout automatique à l'agenda. L'accès complet à l'agenda reste soumis à macOS.
    func setCalendarAutoAdd(_ enabled: Bool) async {
        if enabled {
            await calendar.requestAccess()
            await system.trust.grant(CalendarAgent.sourceID, permission: .writeCalendar, scope: "agenda")
        } else {
            await system.trust.revoke(CalendarAgent.sourceID)
        }
        calendarAutoAdd = enabled
        defaults.set(enabled, forKey: Keys.calendarAutoAdd)
    }

    /// Autorise (ou retire) la recherche en ligne. Seuls la question et la zone sont transmis à Apple Plans.
    func setSearchEnabled(_ enabled: Bool) async {
        if enabled { await system.trust.grant(MindEngine.searchSource, permission: .searchOnline, scope: "Apple Plans") }
        else { await system.trust.revoke(MindEngine.searchSource) }
        searchEnabled = enabled
        defaults.set(enabled, forKey: Keys.searchEnabled)
    }

    /// Fin de l'écran de consentement : le choix de l'utilisateur, tel quel.
    func completeOnboarding(screen: Bool, calendarAutoAdd: Bool, search: Bool = false) async {
        onboardingDone = true
        defaults.set(true, forKey: Keys.onboardingDone)
        if screen { await setScreenObservation(true) }
        if calendarAutoAdd { await setCalendarAutoAdd(true) }
        if search { await setSearchEnabled(true) }
    }

    // MARK: - E-mail

    /// Active la boîte de test simulée (aucun accès réseau).
    func useSimulatedMailbox() async {
        lastError = nil
        await removeEmailSource(deleteData: false)
        await system.trust.grant(gmailID, permission: .readMail, scope: "simulation")
        setEmailMode(.simulation)
        await registerEmailSource(provider: SimulatedMailProvider())
    }

    /// Connecte un compte Gmail réel via OAuth (fenêtre d'authentification Google).
    func connectGmail() async {
        lastError = nil
        isConnecting = true
        defer { isConnecting = false }
        let clientID = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let client = GoogleOAuthClient(clientID: clientID, http: system.http, purpose: gmailID)
            let request = try client.makeAuthorizationRequest()
            let callback = try await GmailAuthorizer.authorize(url: request.url, callbackScheme: request.callbackScheme)
            let code = try GoogleOAuthClient.authorizationCode(from: callback, expectedState: request.state)
            let token = try await client.exchange(code: code, request: request)

            await removeEmailSource(deleteData: false) // remplace la simulation ou l'ancien compte
            try await OAuthTokenProvider(client: client, store: secrets).save(token)
            await system.trust.grant(gmailID, permission: .readMail, scope: "gmail")
            let provider = makeGmailProvider(clientID: clientID)
            let account = try await provider.accountAddress()
            gmailAccount = account
            defaults.set(account, forKey: Keys.account)
            await system.trust.grant(gmailID, permission: .readMail, scope: account ?? "gmail")
            setEmailMode(.gmail)
            await registerEmailSource(provider: provider)
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Révoque la source e-mail (et le jeton Google le cas échéant).
    func removeEmailSource(deleteData: Bool, retainContext: Bool = false) async {
        guard emailMode != .none else { return }
        await center.revoke(gmailID, deleteData: deleteData, retainContext: retainContext)
        if emailMode == .gmail { try? secrets.delete("gmail.oauth") }
        gmailAccount = nil
        defaults.removeObject(forKey: Keys.account)
        setEmailMode(.none)
    }

    private func makeGmailProvider(clientID: String) -> GmailMailProvider {
        let client = GoogleOAuthClient(clientID: clientID, http: system.http, purpose: gmailID)
        return GmailMailProvider(http: system.http, tokens: OAuthTokenProvider(client: client, store: secrets),
                                 purpose: gmailID)
    }

    private func registerEmailSource(provider: MailProvider) async {
        // Une panne avant le premier événement ne doit pas déplacer la borne
        // de départ au prochain lancement et faire perdre les e-mails intermédiaires.
        let grant = await system.trust.grant(for: gmailID)
        let source = EmailSource(id: gmailID, provider: provider, trust: system.trust,
                                 stateStore: system.sourceState, startDate: grant?.grantedAt ?? Date(),
                                 pollInterval: provider.isSimulated ? 20 : 60)
        await center.register(source)
    }

    private func setEmailMode(_ mode: EmailMode) {
        emailMode = mode
        defaults.set(mode.rawValue, forKey: Keys.emailMode)
    }

    // MARK: - Dossier

    /// Ouvre le sélecteur de dossier ; seul le dossier choisi sera observé.
    func chooseFolder() async {
        lastError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Autoriser ce dossier"
        panel.message = "GHOST observera uniquement les noms, types, tailles et dates des fichiers de ce dossier. Il ne lira, ne modifiera et ne supprimera aucun fichier."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            await removeFolderSource(deleteData: false)
            defaults.set(bookmark, forKey: Keys.folderBookmark)
            let access = try SecurityScopedFolder(bookmark: bookmark)
            await system.trust.grant(folderID, permission: .watchFolder, scope: access.url.path)
            await activateFolder(access)
        } catch {
            lastError = Self.describe(error)
        }
    }

    private func activateFolder(_ access: SecurityScopedFolder) async {
        folderAccess = access
        folderURL = access.url
        // L'autorisation enregistrée doit correspondre au dossier résolu
        // (le dossier peut avoir été renommé ou déplacé depuis le choix).
        if await system.trust.grant(for: folderID)?.scope != access.url.path {
            await system.trust.grant(folderID, permission: .watchFolder, scope: access.url.path)
        }
        await center.register(FolderSource(id: folderID, root: access.url, trust: system.trust,
                                           stateStore: system.sourceState))
    }

    /// Révoque l'accès au dossier.
    func removeFolderSource(deleteData: Bool, retainContext: Bool = false) async {
        guard folderURL != nil || defaults.data(forKey: Keys.folderBookmark) != nil else { return }
        await center.revoke(folderID, deleteData: deleteData, retainContext: retainContext)
        folderAccess?.stop()
        folderAccess = nil
        folderURL = nil
        defaults.removeObject(forKey: Keys.folderBookmark)
    }

    // MARK: - Données

    private func initializeContext() async {
        do {
            try await context.engine.reconcilePermissions()
            try await center.attachConsumer(context.engine)
            await context.reload()
        } catch { await context.engine.report(error); await context.reload() }
        // Le Brain démarre après le contexte : il analyse des événements déjà enrichis.
        do {
            try await brain.engine.reconcilePermissions()
            await restoreModelSetting()
            try await center.attachConsumer(brain.engine)
        } catch { await brain.engine.report(error) }
        await brain.reload()
        // GHOST comprend la demande et prépare le travail (brouillons de mail) ; il n'envoie jamais seul.
        do {
            await mind.engine.recoverInterrupted()
            try await center.attachConsumer(mind.engine)
        } catch { lastError = error.localizedDescription }
        await mind.reload()
        // L'agent d'agenda reçoit les mêmes événements ; son registre persistant évite tout doublon au rejeu.
        do {
            await calendar.agent.recoverPending()
            try await center.attachConsumer(calendar.agent)
        } catch { lastError = error.localizedDescription }
        await calendar.reload()
        do {
            try await execution.engine.recover()
            try await center.attachConsumer(execution.engine)
        } catch { lastError = error.localizedDescription }
        await execution.reload()
    }

    func refreshContext() async {
        do { try await center.replayEvents(to: context.engine) }
        catch { await context.engine.report(error) }
        await context.reload()
    }

    func setContextScope(_ scope: ContextScope, source: SourceID) async {
        do {
            try await context.engine.setScope(scope, for: source)
            try await center.replayEvents(to: context.engine)
        } catch { await context.engine.report(error) }
        await context.reload()
    }

    // MARK: - Cerveau

    /// Cœur branché sur l'état de GHOST : en pause ou à l'arrêt, le Brain ne traite plus rien ;
    /// à la reprise, il rattrape les événements non analysés (sans doublon).
    func makeCore() -> GhostCoreInterface {
        BrainAwareCore(base: center, onActive: { [weak self] active in
            guard let self else { return }
            await self.brain.engine.setActive(active)
            await self.execution.engine.setGlobalPaused(!active)
            if active { Task { await self.catchUpBrain() } }
        })
    }

    func prepareExecution(_ missionID: String, sensitive: Bool) async {
        do {
            let id = try await execution.engine.prepare(missionID: missionID, declaredSensitive: sensitive)
            try await chooseExecutionFolders(id)
            try await execution.engine.start(id)
        } catch { lastError = error.localizedDescription }
        await execution.reload()
    }

    func chooseExecutionFolders(_ id: String) async throws {
        func choose(_ message: String) throws -> URL {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.message = message; panel.prompt = "Autoriser"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { throw ExecutionError.cancelled }
            return url
        }
        let input = try choose("Lecture du CONTENU autorisée pour cette exécution uniquement. Le dossier doit contenir des CSV/TSV avec produit,quantite,prix_unitaire. Aucun accès n'est déduit de la permission de perception.")
        let output = try choose("Choisissez un dossier de SORTIE distinct : GHOST pourra y créer de nouveaux livrables. Aucun fichier existant ne sera remplacé.")
        let inputBookmark = try input.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let outputBookmark = try output.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let inputAccess = try SecurityScopedFolder(bookmark: inputBookmark), outputAccess = try SecurityScopedFolder(bookmark: outputBookmark)
        try await execution.engine.authorize(id, input: inputAccess.url.resolvingSymlinksInPath(), output: outputAccess.url.resolvingSymlinksInPath(), allowReadContents: true, allowCreate: true)
        executionAccess[id] = [inputAccess, outputAccess]
        defaults.set(inputBookmark, forKey: "autonomy.\(id).input")
        defaults.set(outputBookmark, forKey: "autonomy.\(id).output")
    }

    func resumeExecution(_ id: String) async {
        do {
            // La reprise exige une nouvelle confirmation des deux dossiers.
            try await chooseExecutionFolders(id)
            try await execution.engine.start(id)
        } catch { lastError = error.localizedDescription }
        await execution.reload()
    }

    func revokeExecution(_ id: String) async {
        await execution.engine.trust.revoke(id)
        await execution.perform { try await $0.pause(id) }
        executionAccess[id] = nil
        defaults.removeObject(forKey: "autonomy.\(id).input"); defaults.removeObject(forKey: "autonomy.\(id).output")
    }

    func catchUpBrain() async {
        do { try await center.replayEvents(to: brain.engine) }
        catch { await brain.engine.report(error) }
        await brain.reload()
    }

    private func restoreModelSetting() async {
        let granted = await system.trust.isAuthorized(PerceptionSystem.brainSourceID, .callExternalModel)
        let enabled = externalModelEnabled && granted && hasModelKey
        externalModelEnabled = enabled
        await gateway.setPolicy(GatewayPolicy(enabled: enabled))
    }

    /// Active ou coupe l'envoi de données **masquées** à un modèle externe (Anthropic).
    func setExternalModel(enabled: Bool) async {
        if enabled {
            guard hasModelKey else { lastError = "Enregistrez d'abord une clé API."; return }
            await system.trust.grant(PerceptionSystem.brainSourceID, permission: .callExternalModel, scope: "anthropic")
        } else {
            await system.trust.revoke(PerceptionSystem.brainSourceID)
        }
        externalModelEnabled = enabled
        defaults.set(enabled, forKey: Keys.externalModel)
        await gateway.setPolicy(GatewayPolicy(enabled: enabled))
    }

    func saveModelKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do { try secrets.save(Data(clean.utf8), for: AnthropicProvider.secretKey); hasModelKey = true }
        catch { lastError = Self.describe(error) }
    }

    func removeModelKey() async {
        try? secrets.delete(AnthropicProvider.secretKey)
        hasModelKey = false
        await setExternalModel(enabled: false)
    }

    func modelCallCount() async -> Int { await gateway.callLog.count }

    func deleteCollectedData(includingAccessLog: Bool) async {
        lastError = nil
        do {
            try await center.deleteCollectedData(includingAccessLog: includingAccessLog)
            executionAccess.removeAll()
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("autonomy.") { defaults.removeObject(forKey: key) }
        } catch {
            lastError = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}


/// Enveloppe `GhostCoreInterface` : relaie au moteur de perception et informe le Brain des changements d'état.
@MainActor
final class BrainAwareCore: GhostCoreInterface {
    private let base: GhostCoreInterface
    private let onActive: @MainActor (Bool) async -> Void
    private var transition: Task<Void, Never>?
    var name: String { base.name + " + Brain" }

    init(base: GhostCoreInterface, onActive: @escaping @MainActor (Bool) async -> Void) {
        self.base = base; self.onActive = onActive
    }
    private func change(_ active: Bool) {
        let previous = transition
        transition = Task { await previous?.value; await onActive(active) }
    }
    func start() { base.start(); change(true) }
    func pause() { change(false); base.pause() }
    func resume() { base.resume(); change(true) }
    func stop() { change(false); base.stop() }
}
