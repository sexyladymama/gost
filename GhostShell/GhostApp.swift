import SwiftUI

/// Point d'entrée de GHOST SHELL.
///
/// L'application n'a pas de fenêtre principale ni d'icône dans le Dock
/// (`LSUIElement = YES`) : elle vit uniquement dans la barre de menus.
@main
struct GhostApp: App {

    /// Le délégué possède le gestionnaire d'état et gère le cycle de vie
    /// (démarrage au lancement, arrêt propre à la fermeture).
    @NSApplicationDelegateAdaptor(GhostAppDelegate.self) private var appDelegate

    var body: some Scene {
        GhostMenuBar(stateManager: appDelegate.stateManager)
    }
}
