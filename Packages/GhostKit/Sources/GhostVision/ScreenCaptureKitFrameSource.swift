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
    private let policy: PrivacyPolicy
    public let diagnostics: ScreenDiagnostics

    public init(maxDimension: Double = 2400, ownBundleID: String = "app.ghost.shell", diagnostics: ScreenDiagnostics = ScreenDiagnostics(), policy: PrivacyPolicy = PrivacyPolicy()) {
        self.policy = policy
        self.diagnostics = diagnostics; self.maxDimension = maxDimension; self.ownBundleID = ownBundleID
    }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func isScreenUnavailable() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// CoreGraphics renvoie l'ordre de superposition, du premier plan vers l'arrière.
    /// Ne jamais remplacer une petite fenêtre de premier plan par une grande fenêtre du même navigateur.
    static func frontWindowID(in windows: [[String: Any]], processID: pid_t) -> CGWindowID? {
        windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID
            && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            .flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    public func capture() async throws -> CapturedFrame? {
        guard CGPreflightScreenCaptureAccess() else { diagnostics.set("macOS refuse la capture : GHOST n'est pas autorisé dans « Enregistrement de l'écran » (ou il faut quitter et relancer GHOST)."); return nil }
        guard !Self.isScreenUnavailable() else { diagnostics.set("Écran verrouillé ou éteint : rien n'est lu."); return nil }
        guard let front = NSWorkspace.shared.frontmostApplication else { diagnostics.set("Aucune application au premier plan."); return nil }
        guard front.bundleIdentifier != ownBundleID else { diagnostics.set("GHOST est au premier plan : il ne lit jamais sa propre fenêtre. Passez dans l'application à lire."); return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier,
                  let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let frontID = Self.frontWindowID(in: ordered, processID: front.processIdentifier),
                  let window = content.windows.first(where: { $0.windowID == frontID && $0.owningApplication?.processID == front.processIdentifier && $0.isOnScreen && $0.windowLayer == 0 }),
                  window.frame.width >= 200, window.frame.height >= 150 else {
                diagnostics.set("Fenêtre au premier plan indisponible ou trop petite : aucune autre fenêtre n'est lue.")
                return nil
            }
            let context = ScreenContext(app: front.localizedName ?? "Application", bundleID: front.bundleIdentifier, windowTitle: window.title)
            if case .skip(let reason) = policy.decide(context) { diagnostics.set("Fenêtre ignorée avant capture : \(reason)."); return nil }
            try Task.checkCancellation()
            let configuration = SCStreamConfiguration()
            let scale = min(2.0, maxDimension / max(window.frame.width, window.frame.height))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                   configuration: configuration)
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier, !Self.isScreenUnavailable() else { return nil }
            return CapturedFrame(image: image, context: context)
        } catch {
            diagnostics.set("Échec de la capture : \(error.localizedDescription)")
            throw VisionError.captureFailed(error.localizedDescription)
        }
    }
}
#endif
