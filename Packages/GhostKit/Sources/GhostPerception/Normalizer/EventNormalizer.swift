import Foundation

/// Convertit les observations brutes de toutes les sources en un format commun
/// (``NormalizedObservation``).
///
/// Pour les e-mails : extraction des personnes, nettoyage du texte (citations
/// de messages précédents et signatures retirées), détection des envois
/// automatisés.
public struct EventNormalizer: Sendable {
    /// Taille maximale du texte transmis au moteur de compréhension.
    public var textLimit: Int

    public init(textLimit: Int = 4_000) {
        self.textLimit = textLimit
    }

    public func normalize(_ raw: RawObservation, from source: EventSource) -> NormalizedObservation {
        switch raw {
        case let .email(message, account):
            return normalize(message, account: account, source: source)
        case let .screen(snapshot):
            var metadata = snapshot.metadata
            metadata["origin"] = "screen"
            metadata["app"] = snapshot.app
            if let title = snapshot.windowTitle { metadata["window"] = title }
            return NormalizedObservation(
                source: source,
                externalID: snapshot.contentKey,
                version: "1",
                occurredAt: snapshot.capturedAt,
                title: snapshot.windowTitle?.isEmpty == false ? snapshot.windowTitle! : snapshot.app,
                text: String(snapshot.text.prefix(textLimit)),
                people: [],
                content: .message,
                isAutomated: false,
                isReply: false,
                userIsDirectRecipient: nil,
                metadata: metadata)
        case let .file(change):
            return NormalizedObservation(
                source: source,
                externalID: change.relativePath,
                version: "\(change.kind.rawValue)-\(Int(change.metadata.modifiedAt.timeIntervalSince1970))-\(change.metadata.size)",
                occurredAt: change.metadata.modifiedAt,
                title: change.metadata.name,
                text: "",
                people: [],
                content: .file(change),
                isAutomated: false,
                isReply: false,
                userIsDirectRecipient: nil,
                metadata: [
                    "path": change.relativePath,
                    "category": change.metadata.category.rawValue,
                    "extension": change.metadata.fileExtension.lowercased(),
                    "size": String(change.metadata.size),
                    "change": change.kind.rawValue
                ])
        }
    }

    private func normalize(_ message: EmailMessage, account: String?, source: EventSource) -> NormalizedObservation {
        let sender = AddressParser.parse(message.from)
        var people = [Person(name: sender.name, email: sender.email, role: .sender)]
        people += message.to.map { AddressParser.parse($0) }.map { Person(name: $0.name, email: $0.email, role: .recipient) }
        people += message.cc.map { AddressParser.parse($0) }.map { Person(name: $0.name, email: $0.email, role: .copied) }

        let account = account?.lowercased()
        let directRecipient: Bool? = account.map { address in
            people.contains { $0.role == .recipient && $0.email == address }
        }
        let senderAddress = sender.email ?? ""
        let automatedSender = ["no-reply", "noreply", "ne-pas-repondre", "notification", "newsletter", "mailer-daemon"]
            .contains { senderAddress.contains($0) }

        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let isReply = message.isReply || subject.range(of: #"^(re|ré|tr|fwd?)\s*:"#,
                                                        options: [.regularExpression, .caseInsensitive]) != nil
        return NormalizedObservation(
            source: source,
            externalID: message.id,
            version: "1",
            occurredAt: message.date,
            title: subject.isEmpty ? "(sans objet)" : subject,
            text: String(Self.cleanBody(message.bodyText).prefix(textLimit)),
            people: people,
            content: .message,
            isAutomated: message.isBulk || automatedSender,
            isReply: isReply,
            userIsDirectRecipient: directRecipient,
            metadata: message.threadID.map { ["thread": $0] } ?? [:])
    }

    /// Retire les citations (« > … », « Le … a écrit : »), les signatures
    /// (« -- ») et normalise les espaces.
    static func cleanBody(_ body: String) -> String {
        var kept: [String] = []
        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "--" || line == "-- " { break }
            if line.hasPrefix(">") { continue }
            if line.range(of: #"^(le|on)\s.+(a écrit|wrote)\s*:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { break }
            if line.range(of: #"^-{2,}\s*(original message|message d'origine)"#, options: [.regularExpression, .caseInsensitive]) != nil { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
