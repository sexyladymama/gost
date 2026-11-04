import Foundation

/// Fournisseur Gmail réel, via l'API REST Gmail v1 en lecture seule.
///
/// Données récupérées : identifiants, date, en-têtes `From`, `To`, `Cc`,
/// `Subject`, `List-Unsubscribe`, `Precedence`, `In-Reply-To`, et la partie
/// `text/plain` du message tronquée à ``bodyLimit`` caractères. Les pièces
/// jointes et les autres en-têtes ne sont pas conservés.
public struct GmailMailProvider: MailProvider {
    public static let apiHost = "gmail.googleapis.com"
    static let keptHeaders: Set<String> = ["from", "to", "cc", "subject", "list-unsubscribe",
                                           "precedence", "in-reply-to", "auto-submitted"]

    public let displayName = "Gmail"
    public let isSimulated = false

    private let http: HTTPClient
    private let tokens: OAuthTokenProvider
    private let purpose: SourceID
    private let maxResults: Int
    private let bodyLimit: Int

    public init(http: HTTPClient, tokens: OAuthTokenProvider, purpose: SourceID,
                maxResults: Int = 25, bodyLimit: Int = 8_000) {
        self.http = http
        self.tokens = tokens
        self.purpose = purpose
        self.maxResults = maxResults
        self.bodyLimit = bodyLimit
    }

    public func accountAddress() async throws -> String? {
        struct Profile: Decodable { let emailAddress: String }
        let data = try await get(path: "/gmail/v1/users/me/profile", query: [])
        return try decode(Profile.self, data).emailAddress
    }

    public func fetchMessages(after date: Date) async throws -> [EmailMessage] {
        struct List: Decodable {
            struct Ref: Decodable { let id: String }
            let messages: [Ref]?
        }
        // `after:` accepte un horodatage en secondes. On retire une seconde
        // de marge ; le dédoublonnage élimine les messages déjà vus.
        let seconds = Int(date.timeIntervalSince1970) - 1
        let list = try decode(List.self, try await get(path: "/gmail/v1/users/me/messages", query: [
            URLQueryItem(name: "q", value: "in:inbox after:\(seconds)"),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]))
        var messages: [EmailMessage] = []
        for ref in list.messages ?? [] {
            let data = try await get(path: "/gmail/v1/users/me/messages/\(ref.id)",
                                     query: [URLQueryItem(name: "format", value: "full")])
            if let message = try parseMessage(data), message.date > date {
                messages.append(message)
            }
        }
        return messages.sorted { $0.date < $1.date }
    }

    public func revokeAccess() async throws {
        try await tokens.revoke()
    }

    // MARK: - Analyse

    struct GmailMessage: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
        struct Part: Decodable {
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let threadId: String?
        let internalDate: String?
        let payload: Part?
    }

    func parseMessage(_ data: Data) throws -> EmailMessage? {
        let raw = try decode(GmailMessage.self, data)
        guard let payload = raw.payload else { return nil }
        var headers: [String: String] = [:]
        for header in payload.headers ?? [] where Self.keptHeaders.contains(header.name.lowercased()) {
            headers[header.name.lowercased()] = header.value
        }
        let millis = Double(raw.internalDate ?? "") ?? 0
        let body = Self.plainText(in: payload).map { String($0.prefix(bodyLimit)) } ?? ""
        let precedence = headers["precedence"]?.lowercased() ?? ""
        return EmailMessage(
            id: raw.id,
            threadID: raw.threadId,
            from: headers["from"] ?? "",
            to: AddressParser.splitList(headers["to"] ?? ""),
            cc: AddressParser.splitList(headers["cc"] ?? ""),
            subject: headers["subject"] ?? "",
            date: Date(timeIntervalSince1970: millis / 1_000),
            bodyText: body,
            isBulk: headers["list-unsubscribe"] != nil || ["bulk", "list", "junk"].contains(precedence)
                || (headers["auto-submitted"].map { $0.lowercased() != "no" } ?? false),
            isReply: headers["in-reply-to"] != nil)
    }

    static func plainText(in part: GmailMessage.Part) -> String? {
        if part.mimeType == "text/plain", let encoded = part.body?.data,
           let data = Data(base64URLEncoded: encoded) {
            return String(decoding: data, as: UTF8.self)
        }
        for child in part.parts ?? [] {
            if let text = plainText(in: child) { return text }
        }
        return nil
    }

    // MARK: - HTTP

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PerceptionError.invalidResponse("URL invalide") }

        var response = try await send(url: url, token: try await tokens.accessToken())
        if response.status == 401 {
            // Jeton expiré ou révoqué côté serveur : un seul renouvellement.
            response = try await send(url: url, token: try await tokens.accessToken(forceRefresh: true))
        }
        switch response.status {
        case 200..<300: return response.body
        case 401, 403: throw PerceptionError.authenticationFailed("accès Gmail refusé (HTTP \(response.status))")
        case 429: throw PerceptionError.rateLimited
        default: throw PerceptionError.connectionFailed("API Gmail (HTTP \(response.status))")
        }
    }

    private func send(url: URL, token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(url: url, headers: ["Authorization": "Bearer \(token)",
                                                            "Accept": "application/json"],
                                        purpose: purpose))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw PerceptionError.invalidResponse("JSON Gmail illisible")
        }
    }
}

/// Analyse d'adresses e-mail (`Nom <adresse>`).
public enum AddressParser {
    public static func parse(_ value: String) -> (name: String?, email: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (name.isEmpty ? nil : name, email.isEmpty ? nil : email.lowercased())
        }
        return (nil, trimmed.contains("@") ? trimmed.lowercased() : nil)
    }

    /// Découpe une liste d'adresses en respectant les virgules entre guillemets.
    public static func splitList(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
