import AppKit
import AuthenticationServices
import GhostPerception

/// Ouvre la fenêtre d'authentification Google du système
/// (`ASWebAuthenticationSession`) et renvoie l'URL de retour.
///
/// GHOST ne voit jamais le mot de passe Google : l'utilisateur s'authentifie
/// directement auprès de Google, dans une session éphémère.
@MainActor
final class GmailAuthorizer: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    static func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let authorizer = GmailAuthorizer()
        return try await authorizer.run(url: url, callbackScheme: callbackScheme)
    }

    private func run(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            var resumed = false
            let finish: (Result<URL, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    finish(.success(callback))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.failure(PerceptionError.authenticationFailed("connexion annulée")))
                } else {
                    finish(.failure(error ?? PerceptionError.authenticationFailed("aucune réponse")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            NSApp.activate(ignoringOtherApps: true)
            if !session.start() {
                finish(.failure(PerceptionError.misconfigured("impossible d'ouvrir la fenêtre d'authentification")))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
