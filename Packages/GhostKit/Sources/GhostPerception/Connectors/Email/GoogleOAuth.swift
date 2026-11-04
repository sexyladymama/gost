import Foundation

/// Jeton OAuth 2.0 stocké dans le ``SecretStore``.
public struct OAuthToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// Demande d'autorisation en cours (flux « Authorization Code + PKCE »).
public struct OAuthAuthorizationRequest: Sendable, Equatable {
    /// URL à ouvrir dans la fenêtre d'authentification du système.
    public var url: URL
    public var state: String
    public var codeVerifier: String
    public var redirectURI: String
    /// Schéma d'URL de retour, à passer à `ASWebAuthenticationSession`.
    public var callbackScheme: String
}

/// Client OAuth 2.0 Google pour application native (RFC 8252 + PKCE).
///
/// Utilise un identifiant client de type « iOS » (aussi valable pour macOS),
/// qui n'a pas de secret client et accepte une redirection vers le schéma
/// `com.googleusercontent.apps.<id>`.
///
/// Portée demandée : `gmail.readonly` uniquement. Le jeton obtenu ne permet
/// **ni d'envoyer, ni de modifier, ni de supprimer** de message.
public struct GoogleOAuthClient: Sendable {
    public static let gmailReadOnlyScope = "https://www.googleapis.com/auth/gmail.readonly"
    public static let tokenHost = "oauth2.googleapis.com"

    public let clientID: String
    private let http: HTTPClient
    private let purpose: SourceID
    private let clock: @Sendable () -> Date

    public init(clientID: String, http: HTTPClient, purpose: SourceID,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
        self.purpose = purpose
        self.clock = clock
    }

    /// `com.googleusercontent.apps.<id>` pour `<id>.apps.googleusercontent.com`.
    public static func callbackScheme(for clientID: String) throws -> String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), clientID.count > suffix.count else {
            throw PerceptionError.misconfigured("identifiant client OAuth Google invalide (attendu : …\(suffix))")
        }
        return "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
    }

    /// Prépare l'URL d'autorisation, avec un vérificateur PKCE et un `state` aléatoires.
    public func makeAuthorizationRequest() throws -> OAuthAuthorizationRequest {
        let scheme = try Self.callbackScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let state = Self.randomURLSafeString(byteCount: 24)
        let challenge = Digest.sha256(Data(verifier.utf8)).base64URLEncoded
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.gmailReadOnlyScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return OAuthAuthorizationRequest(url: components.url!, state: state, codeVerifier: verifier,
                                         redirectURI: redirectURI, callbackScheme: scheme)
    }

    /// Extrait le code d'autorisation de l'URL de retour, en vérifiant `state`.
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw PerceptionError.authenticationFailed("autorisation refusée (\(error))") }
        guard value("state") == expectedState else {
            throw PerceptionError.authenticationFailed("paramètre state invalide")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw PerceptionError.authenticationFailed("code d'autorisation absent")
        }
        return code
    }

    /// Échange le code contre un jeton.
    public func exchange(code: String, request: OAuthAuthorizationRequest) async throws -> OAuthToken {
        try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "code_verifier": request.codeVerifier,
            "redirect_uri": request.redirectURI,
            "grant_type": "authorization_code"
        ], previousRefreshToken: nil)
    }

    /// Renouvelle un jeton expiré.
    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else {
            throw PerceptionError.authorizationRequired(source: purpose)
        }
        return try await tokenRequest([
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token"
        ], previousRefreshToken: refreshToken)
    }

    /// Révoque le jeton chez Google.
    public func revoke(_ token: OAuthToken) async throws {
        let value = token.refreshToken ?? token.accessToken
        let request = HTTPRequest(method: "POST", url: URL(string: "https://\(Self.tokenHost)/revoke")!,
                                  headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                  body: Data(Self.formEncode(["token": value]).utf8), purpose: purpose)
        let response = try await http.send(request)
        // 400 = jeton déjà invalide : l'objectif (jeton inutilisable) est atteint.
        guard (200..<300).contains(response.status) || response.status == 400 else {
            throw PerceptionError.connectionFailed("révocation impossible (HTTP \(response.status))")
        }
    }

    private func tokenRequest(_ form: [String: String], previousRefreshToken: String?) async throws -> OAuthToken {
        let request = HTTPRequest(method: "POST", url: URL(string: "https://\(Self.tokenHost)/token")!,
                                  headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                  body: Data(Self.formEncode(form).utf8), purpose: purpose)
        let response = try await http.send(request)
        if response.status == 400 || response.status == 401 {
            throw PerceptionError.authorizationRequired(source: purpose)
        }
        guard (200..<300).contains(response.status) else {
            throw PerceptionError.connectionFailed("serveur OAuth (HTTP \(response.status))")
        }
        struct Payload: Decodable {
            let access_token: String
            let expires_in: Double?
            let refresh_token: String?
            let scope: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            throw PerceptionError.invalidResponse("jeton OAuth illisible")
        }
        return OAuthToken(accessToken: payload.access_token,
                          refreshToken: payload.refresh_token ?? previousRefreshToken,
                          expiresAt: clock().addingTimeInterval(payload.expires_in ?? 3_600),
                          scope: payload.scope)
    }

    static func formEncode(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator() // CSPRNG du système
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncoded
    }
}

/// Fournit un jeton d'accès valide, en le renouvelant si nécessaire.
/// Les jetons ne quittent jamais le ``SecretStore`` autrement qu'en mémoire.
public actor OAuthTokenProvider {
    private let client: GoogleOAuthClient
    private let store: SecretStore
    private let key: String
    private let clock: @Sendable () -> Date

    public init(client: GoogleOAuthClient, store: SecretStore, key: String = "gmail.oauth",
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.key = key
        self.clock = clock
    }

    public func hasToken() -> Bool { (try? store.load(key)).flatMap { $0 } != nil }

    /// Enregistre un jeton obtenu à l'issue du flux d'autorisation.
    public func save(_ token: OAuthToken) throws {
        try store.save(try JSONEncoder().encode(token), for: key)
    }

    /// Jeton d'accès valide (renouvelé s'il expire dans moins d'une minute).
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let data = try store.load(key),
              let token = try? JSONDecoder().decode(OAuthToken.self, from: data) else {
            throw PerceptionError.authorizationRequired(source: SourceID("gmail"))
        }
        if !forceRefresh, token.expiresAt.timeIntervalSince(clock()) > 60 { return token.accessToken }
        let renewed = try await client.refresh(token)
        try save(renewed)
        return renewed.accessToken
    }

    /// Révoque le jeton chez Google puis l'efface localement (même si la
    /// révocation distante échoue, le jeton local est supprimé).
    public func revoke() async throws {
        defer { try? store.delete(key) }
        guard let data = try store.load(key),
              let token = try? JSONDecoder().decode(OAuthToken.self, from: data) else { return }
        try await client.revoke(token)
    }
}
