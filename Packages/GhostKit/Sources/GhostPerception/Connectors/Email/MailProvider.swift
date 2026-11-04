import Foundation

/// Fournisseur de messages (Gmail réel, simulateur…).
///
/// Contrat : **lecture seule**. Aucun fournisseur n'expose d'envoi, de
/// suppression ou de modification de messages.
public protocol MailProvider: Sendable {
    /// Nom affichable du fournisseur.
    var displayName: String { get }
    /// `true` si le fournisseur est un simulateur.
    var isSimulated: Bool { get }
    /// Adresse du compte surveillé, si connue.
    func accountAddress() async throws -> String?
    /// Messages reçus après `date` (exclue), du plus ancien au plus récent.
    func fetchMessages(after date: Date) async throws -> [EmailMessage]
    /// Révoque l'accès au compte (jeton OAuth) si applicable.
    func revokeAccess() async throws
}
