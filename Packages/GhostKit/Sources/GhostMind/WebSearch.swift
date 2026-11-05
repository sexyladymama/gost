import Foundation

/// Recherche web générale. Seule la question est transmise au service (jamais le contexte de l'utilisateur).
public protocol WebSearcher: Sendable {
    func search(query: String) async throws -> [PlaceResult]
}

/// DuckDuckGo (page « html »), sans clé ni compte. La page de résultats n'est pas une API : si DuckDuckGo la modifie,
/// l'analyse renvoie une erreur claire plutôt que des résultats inventés.
public struct DuckDuckGoSearcher: WebSearcher {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let fetch: Fetch
    public var maxResults: Int

    public init(maxResults: Int = 6, fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.maxResults = maxResults; self.fetch = fetch
    }

    public func search(query: String) async throws -> [PlaceResult] {
        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "fr-fr")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MindError.invalid("Le service de recherche a répondu \(http.statusCode).")
        }
        guard let html = String(data: data, encoding: .utf8) else { throw MindError.invalid("Réponse de recherche illisible.") }
        return try Self.parse(html: html, limit: maxResults)
    }

    /// Extrait titre, adresse et extrait de chaque résultat. Les publicités sont écartées.
    static func parse(html: String, limit: Int) throws -> [PlaceResult] {
        let blocks = html.components(separatedBy: "class=\"result results_links").dropFirst()
        var out: [PlaceResult] = []
        for block in blocks {
            if block.contains("result--ad") || block.contains("y.js?") { continue }
            guard let href = firstMatch(#"class="result__a"[^>]*href="([^"]+)""#, in: block),
                  let title = firstMatch(#"class="result__a"[^>]*>(.*?)</a>"#, in: block),
                  let link = resolve(decode(href)) else { continue }
            let snippet = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block) ?? ""
            let cleanTitle = plain(title)
            guard !cleanTitle.isEmpty else { continue }
            out.append(PlaceResult(id: link.absoluteString, name: cleanTitle, address: plain(snippet), url: link.absoluteString, latitude: 0, longitude: 0))
            if out.count >= limit { break }
        }
        if out.isEmpty, blocks.isEmpty, !html.contains("no-results") {
            throw MindError.invalid("La page de résultats n'a pas le format attendu (ou le service a refusé la requête).")
        }
        return out
    }

    /// Les liens passent parfois par une redirection `duckduckgo.com/l/?uddg=…` : on retrouve la vraie destination.
    static func resolve(_ href: String) -> URL? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard var url = URL(string: absolute), let host = url.host else { return nil }
        if host.hasSuffix("duckduckgo.com") {
            guard (url.path == "/l" || url.path.hasPrefix("/l/")), let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let real = URL(string: target) else { return nil }
            url = real
        }
        guard url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func plain(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decode(noTags).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
