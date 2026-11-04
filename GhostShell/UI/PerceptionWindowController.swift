import AppKit
import SwiftUI
import GhostKit

/// Gère la fenêtre « GHOST — Perception », ouverte uniquement à la demande
/// de l'utilisateur (l'application n'a pas de fenêtre au lancement).
@MainActor
final class PerceptionWindowController {
    private var window: NSWindow?

    func show(stateManager: GhostStateManager, perception: PerceptionController) {
        if window == nil {
            let controller = NSHostingController(rootView: PerceptionWindow(stateManager: stateManager,
                                                                            perception: perception))
            controller.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "GHOST — Perception"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = GhostTheme.backgroundNS
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 980, height: 620))
            window.center()
            window.setFrameAutosaveName("GhostPerceptionWindow")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
