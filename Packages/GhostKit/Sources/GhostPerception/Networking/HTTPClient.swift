import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Requête HTTP minimale, indépendante de `URLSession` (testable).
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Source au nom de laquelle la requête est émise (contrôle d'égress).
    public var purpose: SourceID

    public init(method: String = "GET", url: URL, headers: [String: String] = [:],
                body: Data? = nil, purpose: SourceID) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.purpose = purpose
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Client HTTP abstrait.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Implémentation réelle basée sur `URLSession` (pas de cache, pas de cookies).
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(status: status, body: data)
        } catch {
            throw PerceptionError.connectionFailed(error.localizedDescription)
        }
    }
}

/// Règle d'égress : hôte autorisé, éventuellement conditionné à une
/// autorisation accordée à une source.
public struct EgressRule: Sendable, Hashable {
    public var host: String
    /// Sources pouvant contacter cet hôte.
    public var allowedPurposes: Set<SourceID>
    /// Si non `nil`, la source doit détenir cette permission dans le
    /// ``TrustEngine`` au moment de la requête.
    public var requiredPermission: Permission?

    public init(host: String, allowedPurposes: Set<SourceID>, requiredPermission: Permission?) {
        self.host = host
        self.allowedPurposes = allowedPurposes
        self.requiredPermission = requiredPermission
    }
}

/// Client HTTP qui **bloque toute requête non explicitement autorisée**.
///
/// C'est le seul chemin réseau du moteur de perception. Une requête vers un
/// hôte absent de la liste, ou émise par une source sans autorisation, est
/// refusée avant d'atteindre le réseau, et le refus est journalisé.
public struct GuardedHTTPClient: HTTPClient {
    private let base: HTTPClient
    private let rules: [EgressRule]
    private let trust: TrustEngine

    public init(base: HTTPClient, rules: [EgressRule], trust: TrustEngine) {
        self.base = base
        self.rules = rules
        self.trust = trust
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host?.lowercased() ?? ""
        let log = trust.accessLog
        guard request.url.scheme?.lowercased() == "https",
              let rule = rules.first(where: { $0.host == host }),
              rule.allowedPurposes.contains(request.purpose) else {
            await log.record(request.purpose, operation: "network.request", target: host.isEmpty ? request.url.absoluteString : host,
                             outcome: .denied, detail: "destination non autorisée")
            throw PerceptionError.egressDenied(host: host.isEmpty ? request.url.absoluteString : host)
        }
        if let permission = rule.requiredPermission,
           !(await trust.isAuthorized(request.purpose, permission)) {
            await log.record(request.purpose, operation: "network.request", target: host,
                             outcome: .denied, detail: "source non autorisée")
            throw PerceptionError.notAuthorized(source: request.purpose, resource: host)
        }
        do {
            let response = try await base.send(request)
            await log.record(request.purpose, operation: "network.request", target: host,
                             outcome: .allowed, detail: "\(request.method) \(request.url.path) → \(response.status)")
            return response
        } catch {
            await log.record(request.purpose, operation: "network.request", target: host,
                             outcome: .failed, detail: error.localizedDescription)
            throw error
        }
    }
}
