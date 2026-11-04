import SwiftUI
import GhostKit
import GhostPerception

/// Garanties de confidentialité et contrôle des données collectées.
struct PrivacyView: View {
    let stateManager: GhostStateManager
    let perception: PerceptionController
    @State private var confirmDeletion = false

    var body: some View {
        Form {
            Section("Ce que fait GHOST PERCEPTION") {
                guarantee("eye", "Il ne lit que les sources que vous avez explicitement autorisées.")
                guarantee("envelope.badge.shield.half.filled", "E-mail : lecture seule. Aucune réponse, aucun envoi, aucune modification.")
                guarantee("folder.badge.questionmark", "Dossier : métadonnées uniquement, dans le seul dossier choisi. Aucune lecture de contenu, modification ou suppression.")
                guarantee("network.slash", "Aucune donnée n'est envoyée à un service tiers. Seules les API Google nécessaires à Gmail sont joignables, et uniquement si vous avez connecté Gmail.")
                guarantee("rectangle.dashed.badge.record", "Aucune capture d'écran, aucune frappe clavier, aucune observation de vos applications.")
                guarantee("key", "Les jetons Google sont stockés dans le Trousseau macOS.")
                guarantee("list.bullet.rectangle", "Chaque accès à une source est inscrit dans le journal d'accès.")
            }

            Section("Perception") {
                LabeledContent("État", value: "\(stateManager.state.displayName) — \(perception.center.engineState.label)")
                if stateManager.state == .stopped {
                    Button("Démarrer la perception") { try? stateManager.start() }
                } else {
                    Button("Arrêter complètement la perception", role: .destructive) { stateManager.stop() }
                }
            }

            Section("Données collectées") {
                LabeledContent("Événements enregistrés", value: "\(perception.center.events.count)")
                LabeledContent("Emplacement") {
                    Text(perception.system.profile.directory.path)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                Button("Supprimer les données collectées…", role: .destructive) { confirmDeletion = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Supprimer les données collectées ?", isPresented: $confirmDeletion) {
            Button("Supprimer les événements", role: .destructive) {
                Task { await perception.deleteCollectedData(includingAccessLog: false) }
            }
            Button("Supprimer les événements et le journal d'accès", role: .destructive) {
                Task { await perception.deleteCollectedData(includingAccessLog: true) }
            }
        } message: {
            Text("Les événements détectés et l'état des sources seront effacés de ce Mac. Les autorisations restent en place ; révoquez-les dans « Sources ».")
        }
    }

    private func guarantee(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
    }
}
