import AppKit
import Observation
import GhostKit
import GhostPerception

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
    }

    @ObservationIgnored let system: PerceptionSystem
    @ObservationIgnored let center: PerceptionCenter

    private(set) var emailMode: EmailMode
    private(set) var gmailAccount: String?
    private(set) var folderURL: URL?
    private(set) var isConnecting = false
    var lastError: String?
    var googleClientID: String {
        didSet { defaults.set(googleClientID, forKey: Keys.clientID) }
    }

    @ObservationIgnored private let defaults: UserDefaults
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
        defaults = persistent ? .standard : UserDefaults(suiteName: "ghost.preview") ?? .standard
        secrets = persistent ? KeychainSecretStore(profileID: profile.id) : InMemorySecretStore()
        emailMode = EmailMode(rawValue: defaults.string(forKey: Keys.emailMode) ?? "") ?? .none
        googleClientID = defaults.string(forKey: Keys.clientID) ?? ""
        gmailAccount = defaults.string(forKey: Keys.account)
    }

    var gmailID: SourceID { PerceptionSystem.gmailSourceID }
    var folderID: SourceID { PerceptionSystem.folderSourceID }

    func status(of id: SourceID) -> SourceStatus? {
        center.sources.first { $0.id == id }
    }

    // MARK: - Restauration au lancement

    /// Réenregistre les sources autorisées lors d'une session précédente.
    func restoreSources() async {
        switch emailMode {
        case .simulation:
            await registerEmailSource(provider: SimulatedMailProvider())
        case .gmail:
            await registerEmailSource(provider: makeGmailProvider(clientID: googleClientID))
        case .none:
            break
        }
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
    func removeEmailSource(deleteData: Bool) async {
        guard emailMode != .none else { return }
        await center.revoke(gmailID, deleteData: deleteData)
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
        let source = EmailSource(id: gmailID, provider: provider, trust: system.trust,
                                 stateStore: system.sourceState, startDate: Date(),
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
    func removeFolderSource(deleteData: Bool) async {
        guard folderURL != nil || defaults.data(forKey: Keys.folderBookmark) != nil else { return }
        await center.revoke(folderID, deleteData: deleteData)
        folderAccess?.stop()
        folderAccess = nil
        folderURL = nil
        defaults.removeObject(forKey: Keys.folderBookmark)
    }

    // MARK: - Données

    func deleteCollectedData(includingAccessLog: Bool) async {
        do {
            try await center.deleteCollectedData(includingAccessLog: includingAccessLog)
        } catch {
            lastError = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
