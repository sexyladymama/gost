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
            if let error = perception.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("Ce que fait GHOST PERCEPTION") {
                guarantee("eye", "Il ne lit que les sources que vous avez explicitement autorisées.")
                guarantee("envelope.badge.shield.half.filled", "E-mail : lecture seule. Aucune réponse, aucun envoi, aucune modification.")
                guarantee("folder.badge.questionmark", "Dossier : métadonnées uniquement, dans le seul dossier choisi. Aucune lecture de contenu, modification ou suppression.")
                guarantee("network.slash", "Aucune donnée n'est envoyée à un service tiers. Seules les API Google nécessaires à Gmail sont joignables, et uniquement si vous avez connecté Gmail.")
                guarantee("rectangle.dashed.badge.record", "Aucune capture d'écran, aucune frappe clavier, aucune observation de vos applications.")
                guarantee("scope", "Le cerveau propose des missions mais n'exécute rien : aucun envoi, aucune modification de fichier, aucune action sans votre validation.")
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
                Button("Supprimer les données, la mémoire et les missions…", role: .destructive) { confirmDeletion = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Supprimer les données et la mémoire ?", isPresented: $confirmDeletion) {
            Button("Supprimer événements, mémoire et missions", role: .destructive) {
                Task { await perception.deleteCollectedData(includingAccessLog: false) }
            }
            Button("Supprimer événements, mémoire et journal", role: .destructive) {
                Task { await perception.deleteCollectedData(includingAccessLog: true) }
            }
        } message: {
            Text("Les événements, les états des sources et toute la mémoire de contexte (préférences explicites incluses) seront effacés de ce Mac. Les autorisations restent en place ; révoquez-les dans « Sources ».")
        }
    }

    private func guarantee(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
    }
}
