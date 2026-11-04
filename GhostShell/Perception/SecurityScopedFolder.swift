import Foundation

/// Accès à un dossier choisi par l'utilisateur dans le bac à sable macOS,
/// via un signet de sécurité en **lecture seule**.
///
/// Sans ce signet, l'application n'a accès à aucun fichier de l'utilisateur.
final class SecurityScopedFolder {
    let url: URL
    let isStale: Bool
    private var isAccessing: Bool

    init(bookmark: Data) throws {
        var stale = false
        url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                      relativeTo: nil, bookmarkDataIsStale: &stale)
        isStale = stale
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit { stop() }
}
