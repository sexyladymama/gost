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

    override init() {
        perception = PerceptionController()
        stateManager = GhostStateManager(core: perception.makeCore())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try stateManager.start()
        } catch {
            assertionFailure("Impossible de démarrer GHOST : \(error)")
        }
        Task { await perception.restoreSources() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateManager.stop()
    }
}
