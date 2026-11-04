import Foundation

/// Message de démonstration du simulateur.
public struct SimulatedEmail: Sendable, Hashable {
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var body: String
    public var isBulk: Bool
    public var isReply: Bool

    public init(from: String, to: [String], cc: [String] = [], subject: String, body: String,
                isBulk: Bool = false, isReply: Bool = false) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.isBulk = isBulk
        self.isReply = isReply
    }
}

/// Boîte e-mail **simulée**, utilisée lorsqu'aucun compte Gmail n'est configuré.
///
/// Les messages « arrivent » un par un, à chaque collecte, avec la date de
/// leur livraison. Tous les événements qui en sont issus sont marqués
/// `isSimulated` et affichés comme tels dans l'interface.
public final class SimulatedMailProvider: MailProvider, @unchecked Sendable {
    public let displayName = "Boîte de test"
    public let isSimulated = true

    private let address: String
    private var pending: [SimulatedEmail]
    private let perFetch: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

    public init(address: String = SimulatedMailProvider.defaultAddress,
                emails: [SimulatedEmail] = SimulatedMailProvider.scenario(),
                deliveredPerFetch: Int = 1,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.address = address
        self.pending = emails
        self.perFetch = deliveredPerFetch
        self.clock = clock
    }

    public static let defaultAddress = "moi@ghost.test"

    /// Ajoute un message à la file d'arrivée.
    public func deliver(_ email: SimulatedEmail) { lock.withLock { pending.append(email) } }

    public var remainingCount: Int { lock.withLock { pending.count } }

    public func accountAddress() async throws -> String? { address }

    public func fetchMessages(after date: Date) async throws -> [EmailMessage] {
        let now = clock()
        return lock.withLock {
            let batch = pending.prefix(perFetch)
            pending.removeFirst(batch.count)
            return batch.map { email in
                // Identifiant stable d'un lancement à l'autre (dédoublonnage).
                EmailMessage(id: "sim-" + StableHash.fnv1a(email.from + "|" + email.subject + "|" + email.body),
                                    threadID: nil, from: email.from, to: email.to, cc: email.cc,
                                    subject: email.subject, date: max(now, date.addingTimeInterval(1)),
                                    bodyText: email.body, isBulk: email.isBulk, isReply: email.isReply)
            }
        }
    }

    public func revokeAccess() async throws {}

    /// Scénario réaliste couvrant les principales catégories.
    public static func scenario(user: String = defaultAddress) -> [SimulatedEmail] {
        [
            SimulatedEmail(
                from: "Marie Dupont <marie.dupont@acme.example>", to: [user],
                subject: "Résultats du mois",
                body: """
                Bonjour,

                Peux-tu me préparer un fichier Excel avec les résultats du mois pour demain matin ?

                Merci beaucoup,
                Marie
                """),
            SimulatedEmail(
                from: "La Lettre Tech <newsletter@lettre-tech.example>", to: [user],
                subject: "Les nouveautés de la semaine",
                body: """
                Découvrez notre sélection d'articles de la semaine.
                Profitez de -20 % sur l'abonnement jusqu'au 30 novembre.
                Pour vous désabonner, cliquez ici.
                """, isBulk: true),
            SimulatedEmail(
                from: "Paul Martin <paul.martin@fournisseur.example>", to: [user],
                subject: "Relance : contrat fournisseur",
                body: """
                Bonjour,

                Je me permets de revenir vers toi : as-tu pu relire le contrat ?
                J'en aurais besoin avant vendredi.

                Paul
                """),
            SimulatedEmail(
                from: "Julie Bernard <julie.bernard@acme.example>", to: [user],
                subject: "Point projet",
                body: "Est-ce que tu serais disponible jeudi à 14h pour faire un point sur le projet ?"),
            SimulatedEmail(
                from: "Thomas Leroy <thomas.leroy@acme.example>", to: [user], cc: ["equipe@acme.example"],
                subject: "Réunion d'équipe déplacée",
                body: "Pour info, la réunion d'équipe est déplacée à lundi 10h, même salle."),
            SimulatedEmail(
                from: "Sarah Cohen <sarah.cohen@partner.example>", to: [user],
                subject: "Re: Déjeuner",
                body: """
                Merci pour hier, c'était un vrai plaisir !

                Le 3 nov. 2026 à 18:02, moi@ghost.test a écrit :
                > On se retrouve à 12h30 ?
                """, isReply: true),
            SimulatedEmail(
                from: "John Smith <john.smith@client.example>", to: [user],
                subject: "Q3 report",
                body: "Hi, could you send me the Q3 sales report by Friday? Thanks, John")
        ]
    }
}
