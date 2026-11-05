import AppKit
import GhostKit

/// Gère le cycle de vie de l'application.
///
/// - Au lancement : démarre GHOST (STOPPED → ACTIVE) puis réactive les
///   sources que l'utilisateur avait autorisées.
/// - À la fermeture, quelle qu'en soit l'origine (bouton « Quitter », ⌘Q,
///   déconnexion de session…) : arrête GHOST proprement (→ STOPPED),
///   ce qui suspend toute collecte.
@MainActor
final class GhostAppDelegate: NSObject, NSApplicationDelegate {

    /// Moteur de perception et configuration des sources.
    let perception: PerceptionController
    /// Source de vérité unique de l'état, partagée avec l'interface.
    /// Le moteur de perception est branché via `GhostCoreInterface`.
    let stateManager: GhostStateManager
    let windows = PerceptionWindowController()
    private var hotKey: GhostHotKey?

    override init() {
        perception = PerceptionController()
        stateManager = GhostStateManager(core: perception.makeCore())
        super.init()
    }

    /// Une seule copie de GHOST à la fois : deux copies écrivent dans les mêmes fichiers (autorisations, missions, agenda)
    /// et s'écrasent mutuellement. (Ignoré pendant les tests automatisés.)
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "GHOST est déjà ouvert"
        alert.informativeText = "Deux copies de GHOST écrivent dans les mêmes fichiers et effacent mutuellement leurs autorisations. Quitter l'autre copie et continuer ici ?"
        alert.addButton(withTitle: "Quitter l'autre copie")
        alert.addButton(withTitle: "Quitter celle-ci")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }
        others.forEach { $0.terminate() }
        for _ in 0..<30 where others.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try stateManager.start()
        } catch {
            assertionFailure("Impossible de démarrer GHOST : \(error)")
        }
        Task { await perception.restoreSources() }
        // ⌃⌥⌘G : pause / reprise immédiate, depuis n'importe quelle application.
        hotKey = GhostHotKey { [weak self] in
            guard let self else { return }
            if self.stateManager.state == .stopped { try? self.stateManager.start() }
            else if self.stateManager.canTogglePause { try? self.stateManager.togglePause() }
        }
        // Premier lancement : l'écran de consentement s'ouvre ; GHOST ne regarde rien tant que l'utilisateur n'a pas accepté.
        if !perception.onboardingDone { windows.show(stateManager: stateManager, perception: perception) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateManager.stop()
    }
}
