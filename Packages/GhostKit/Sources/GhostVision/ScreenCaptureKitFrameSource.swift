import Foundation
import CoreGraphics
#if canImport(ScreenCaptureKit) && canImport(AppKit)
import ScreenCaptureKit
import AppKit

/// Capture de la **fenêtre au premier plan** (jamais le bureau entier, jamais les fenêtres en arrière-plan : un gestionnaire de
/// mots de passe visible à côté ne peut donc pas être lu). Ne capture rien si : permission « Enregistrement de l'écran » absente,
/// écran verrouillé ou éteint, ou si c'est GHOST lui-même qui est au premier plan. Ne demande jamais la permission : c'est
/// l'utilisateur qui l'accorde dans Réglages Système.
public final class ScreenCaptureKitFrameSource: FrameSource {
    private let maxDimension: Double
    private let ownBundleID: String
    public let diagnostics: ScreenDiagnostics

    public init(maxDimension: Double = 2400, ownBundleID: String = "app.ghost.shell", diagnostics: ScreenDiagnostics = ScreenDiagnostics()) {
        self.diagnostics = diagnostics; self.maxDimension = maxDimension; self.ownBundleID = ownBundleID
    }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func isScreenUnavailable() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    public func capture() async throws -> CapturedFrame? {
        guard CGPreflightScreenCaptureAccess() else { diagnostics.set("macOS refuse la capture : GHOST n'est pas autorisé dans « Enregistrement de l'écran » (ou il faut quitter et relancer GHOST)."); return nil }
        guard !Self.isScreenUnavailable() else { diagnostics.set("Écran verrouillé ou éteint : rien n'est lu."); return nil }
        guard let front = NSWorkspace.shared.frontmostApplication else { diagnostics.set("Aucune application au premier plan."); return nil }
        guard front.bundleIdentifier != ownBundleID else { diagnostics.set("GHOST est au premier plan : il ne lit jamais sa propre fenêtre. Passez dans l'application à lire."); return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == front.processIdentifier && $0.isOnScreen && $0.windowLayer == 0
                    && $0.frame.width >= 200 && $0.frame.height >= 150
            }
            guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                diagnostics.set("« \(front.localizedName ?? "Application") » est au premier plan mais aucune de ses fenêtres n'est lisible (\(content.windows.count) fenêtres visibles au total).")
                return nil
            }
            let configuration = SCStreamConfiguration()
            let scale = min(2.0, maxDimension / max(window.frame.width, window.frame.height))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                   configuration: configuration)
            return CapturedFrame(image: image, context: ScreenContext(app: front.localizedName ?? "Application",
                                                                      bundleID: front.bundleIdentifier, windowTitle: window.title))
        } catch {
            diagnostics.set("Échec de la capture : \(error.localizedDescription)")
            throw VisionError.captureFailed(error.localizedDescription)
        }
    }
}
#endif
