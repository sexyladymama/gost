import XCTest
@testable import GhostPerception

/// Réponses HTTP Gmail simulées (aucune connexion réelle).
enum GmailFixtures {
    static func base64URL(_ text: String) -> String { Data(text.utf8).base64URLEncoded }

    static let messageJSON = """
    {"id":"18c1","threadId":"t1","internalDate":"\(Int(referenceDate.timeIntervalSince1970 * 1000))",
     "labelIds":["INBOX"],"snippet":"Peux-tu…",
     "payload":{"mimeType":"multipart/alternative","headers":[
        {"name":"From","value":"\\"Dupont, Marie\\" <Marie.Dupont@acme.example>"},
        {"name":"To","value":"moi@gmail.com"},
        {"name":"Subject","value":"Résultats du mois"},
        {"name":"X-Secret-Header","value":"ne doit pas être conservé"},
        {"name":"Received","value":"from mx.example"}],
      "parts":[
        {"mimeType":"text/html","body":{"data":"\(base64URL("<p>HTML ignoré</p>"))"}},
        {"mimeType":"text/plain","body":{"data":"\(base64URL("Peux-tu me préparer un fichier Excel avec les résultats du mois pour demain matin ?"))"}},
        {"mimeType":"application/pdf","body":{"attachmentId":"att1"}}]}}
    """

    static let responder: @Sendable (HTTPRequest) throws -> HTTPResponse = { request in
        switch request.url.path {
        case "/gmail/v1/users/me/profile":
            return HTTPResponse(status: 200, body: Data(#"{"emailAddress":"moi@gmail.com"}"#.utf8))
        case "/gmail/v1/users/me/messages":
            return HTTPResponse(status: 200, body: Data(#"{"messages":[{"id":"18c1","threadId":"t1"}]}"#.utf8))
        case "/gmail/v1/users/me/messages/18c1":
            return HTTPResponse(status: 200, body: Data(messageJSON.utf8))
        default:
            return HTTPResponse(status: 404, body: Data())
        }
    }
}

/// Intégration Gmail testée contre des réponses simulées : construction des
/// requêtes, minimisation des données, OAuth/PKCE, renouvellement de jeton.
final class GmailIntegrationTests: XCTestCase {

    func testGmailRequestsAreReadOnlyAndMinimal() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        let network = RecordingHTTPClient(responder: GmailFixtures.responder)
        let provider = try await makeGmailProvider(http: network, trust: trust)
        let after = referenceDate.addingTimeInterval(-600)
        let messages = try await provider.fetchMessages(after: after)

        let list = try XCTUnwrap(network.recorded.first { $0.url.path == "/gmail/v1/users/me/messages" })
        let query = URLComponents(url: list.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "in:inbox after:\(Int(after.timeIntervalSince1970) - 1)")
        XCTAssertEqual(list.headers["Authorization"], "Bearer access-1")

        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.id, "18c1")
        XCTAssertEqual(message.from, "\"Dupont, Marie\" <Marie.Dupont@acme.example>")
        XCTAssertEqual(message.to, ["moi@gmail.com"])
        XCTAssertEqual(message.bodyText, "Peux-tu me préparer un fichier Excel avec les résultats du mois pour demain matin ?")
        XCTAssertEqual(message.date, referenceDate)
        XCTAssertFalse(message.isBulk)
    }

    func testGmailMessageGoesThroughFullPipeline() async throws {
        let (engine, trust, _, _) = makeEngine()
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        let provider = try await makeGmailProvider(http: RecordingHTTPClient(responder: GmailFixtures.responder), trust: trust)
        let source = EmailSource(provider: provider, trust: trust, stateStore: InMemorySourceStateStore(),
                                 startDate: referenceDate.addingTimeInterval(-600))
        await engine.register(source)
        await engine.start()
        let report = await engine.runCycle(force: true)
        let event = try XCTUnwrap(report.newEvents.first)
        XCTAssertEqual(event.kind, .task)
        XCTAssertEqual(event.people.first?.name, "Dupont, Marie")
        XCTAssertEqual(event.people.first?.email, "marie.dupont@acme.example")
        XCTAssertTrue(event.isMissionCandidate)
        XCTAssertFalse(event.source.isSimulated)
        await engine.stop()
    }

    func testBulkHeadersMarkMessageAsAutomated() throws {
        let provider = GmailMailProvider(http: RecordingHTTPClient(),
                                         tokens: OAuthTokenProvider(client: GoogleOAuthClient(clientID: "x.apps.googleusercontent.com",
                                                                                              http: RecordingHTTPClient(), purpose: SourceID("gmail")),
                                                                    store: InMemorySecretStore()),
                                         purpose: SourceID("gmail"))
        let json = """
        {"id":"n1","internalDate":"0","payload":{"mimeType":"text/plain","headers":[
          {"name":"From","value":"news@x.example"},{"name":"List-Unsubscribe","value":"<mailto:u@x.example>"}],
          "body":{"data":"\(GmailFixtures.base64URL("Bonjour"))"}}}
        """
        let message = try XCTUnwrap(provider.parseMessage(Data(json.utf8)))
        XCTAssertTrue(message.isBulk)
        XCTAssertEqual(message.bodyText, "Bonjour")
    }

    func testExpiredTokenIsRefreshedThroughTheTokenEndpoint() async throws {
        let clock = TestClock()
        let trust = TrustEngine(accessLog: AccessLog())
        await trust.grant(PerceptionSystem.gmailSourceID, permission: .readMail, scope: "moi@gmail.com")
        let network = RecordingHTTPClient { request in
            if request.url.host == GoogleOAuthClient.tokenHost {
                return HTTPResponse(status: 200, body: Data(#"{"access_token":"access-2","expires_in":3600}"#.utf8))
            }
            return try GmailFixtures.responder(request)
        }
        let guarded = GuardedHTTPClient(base: network, rules: PerceptionSystem.egressRules, trust: trust)
        let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com", http: guarded,
                                       purpose: PerceptionSystem.gmailSourceID, clock: clock.function)
        let secrets = InMemorySecretStore()
        let tokens = OAuthTokenProvider(client: client, store: secrets, clock: clock.function)
        try await tokens.save(OAuthToken(accessToken: "access-1", refreshToken: "refresh-1",
                                         expiresAt: clock.now.addingTimeInterval(30), scope: nil))
        let provider = GmailMailProvider(http: guarded, tokens: tokens, purpose: PerceptionSystem.gmailSourceID)
        _ = try await provider.accountAddress()

        let refresh = try XCTUnwrap(network.recorded.first)
        XCTAssertEqual(refresh.url.absoluteString, "https://oauth2.googleapis.com/token")
        let form = String(decoding: refresh.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=refresh-1"))
        XCTAssertEqual(network.recorded.last?.headers["Authorization"], "Bearer access-2")
        // Le jeton de rafraîchissement est conservé.
        let saved = try JSONDecoder().decode(OAuthToken.self, from: try XCTUnwrap(secrets.load("gmail.oauth")))
        XCTAssertEqual(saved.refreshToken, "refresh-1")
    }

    func testAuthorizationRequestUsesPKCEAndReadOnlyScope() throws {
        let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com", http: RecordingHTTPClient(),
                                       purpose: SourceID("gmail"))
        let request = try client.makeAuthorizationRequest()
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.url.host, "accounts.google.com")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/gmail.readonly")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], Digest.sha256(Data(request.codeVerifier.utf8)).base64URLEncoded)
        XCTAssertEqual(items["state"], request.state)
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(request.callbackScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertGreaterThanOrEqual(request.codeVerifier.count, 43) // RFC 7636
        XCTAssertNotEqual(try client.makeAuthorizationRequest().state, request.state)
        XCTAssertThrowsError(try GoogleOAuthClient.callbackScheme(for: "pas-un-identifiant"))
    }

    func testCallbackIsValidatedAgainstState() throws {
        let ok = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=abc&state=s1")!
        XCTAssertEqual(try GoogleOAuthClient.authorizationCode(from: ok, expectedState: "s1"), "abc")
        XCTAssertThrowsError(try GoogleOAuthClient.authorizationCode(from: ok, expectedState: "autre"))
        let denied = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?error=access_denied&state=s1")!
        XCTAssertThrowsError(try GoogleOAuthClient.authorizationCode(from: denied, expectedState: "s1"))
    }

    func testRevocationDeletesLocalTokenEvenIfRemoteFails() async throws {
        let trust = TrustEngine(accessLog: AccessLog())
        let network = RecordingHTTPClient { _ in throw PerceptionError.connectionFailed("hors ligne") }
        let guarded = GuardedHTTPClient(base: network, rules: PerceptionSystem.egressRules, trust: trust)
        let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com", http: guarded, purpose: PerceptionSystem.gmailSourceID)
        let secrets = InMemorySecretStore()
        let tokens = OAuthTokenProvider(client: client, store: secrets)
        try await tokens.save(OAuthToken(accessToken: "a", refreshToken: "r", expiresAt: Date(), scope: nil))
        await XCTAssertThrowsAsync(try await tokens.revoke())
        XCTAssertNil(try secrets.load("gmail.oauth"))
        XCTAssertEqual(network.recorded.first?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
    }

    func testSHA256MatchesNISTVectors() {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(Digest.portableSHA256(Data(input.utf8)).map { String(format: "%02x", $0) }.joined(), expected)
            XCTAssertEqual(Digest.sha256(Data(input.utf8)).map { String(format: "%02x", $0) }.joined(), expected)
        }
        // Vecteur de l'annexe B de la RFC 7636 (PKCE).
        XCTAssertEqual(Digest.sha256(Data("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".utf8)).base64URLEncoded,
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAddressParsing() {
        XCTAssertEqual(AddressParser.splitList(#""Dupont, Marie" <m@a.fr>, paul@b.fr"#), [#""Dupont, Marie" <m@a.fr>"#, "paul@b.fr"])
        let parsed = AddressParser.parse("Paul <Paul@B.fr>")
        XCTAssertEqual(parsed.name, "Paul")
        XCTAssertEqual(parsed.email, "paul@b.fr")
    }
}
