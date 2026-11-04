import AppKit
import GhostKit

/// Gère le cycle de vie de l'application.
///
/// - Au lancement : démarre GHOST (STOPPED → ACTIVE).
/// - À la fermeture, quelle qu'en soit l'origine (bouton « Quitter », ⌘Q,
///   déconnexion de session…) : arrête GHOST proprement (→ STOPPED),
///   ce qui laisse au moteur l'occasion de libérer ses ressources.
@MainActor
final class GhostAppDelegate: NSObject, NSApplicationDelegate {

    /// Source de vérité unique de l'état, partagée avec l'interface.
    let stateManager = GhostStateManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try stateManager.start()
        } catch {
            assertionFailure("Impossible de démarrer GHOST : \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateManager.stop()
    }
}
