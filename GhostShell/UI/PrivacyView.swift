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
            Section("Sources, actions et confidentialité") {
                guarantee("eye", "Il ne lit que les sources que vous avez explicitement autorisées.")
                guarantee("envelope.badge.shield.half.filled", "Gmail : lecture seule. Les brouillons peuvent être rédigés localement ; un envoi par Mail exige votre clic sur « Envoyer ».")
                guarantee("folder.badge.questionmark", "Le dossier surveillé par Perception est limité aux métadonnées. Le scénario Excel demande séparément la lecture du contenu CSV/TSV et la création des résultats dans un dossier de sortie autorisé.")
                guarantee("network.slash", "Avec votre autorisation, Gmail contacte Google, les recherches contactent Apple Plans ou DuckDuckGo et le modèle externe contacte Anthropic. Le modèle Apple et l’OCR travaillent sur le Mac.")
                guarantee("rectangle.dashed.badge.record", "Après consentement, GHOST capture la fenêtre de l’application au premier plan pour y lire les demandes et rendez-vous. Les images ne sont pas enregistrées ; les extraits utiles restent dans la mémoire locale. Aucune frappe clavier n’est enregistrée.")
                guarantee("scope", "Selon vos autorisations, GHOST prépare des brouillons, cherche en ligne, crée des fichiers dans le dossier choisi et ajoute des rendez-vous à l’agenda. Pause suspend les nouveaux traitements. Un envoi déjà engagé ne peut pas être rappelé.")
                guarantee("key", "Les jetons Google sont stockés dans le Trousseau macOS.")
                guarantee("list.bullet.rectangle", "La perception journalise ses accès. Les exécutions et les ajouts à l’agenda conservent aussi leur historique local.")
            }

            Section("Perception") {
                LabeledContent("État", value: "\(stateManager.state.displayName) — \(perception.center.engineState.label)")
                if stateManager.state == .stopped {
                    Button("Démarrer la perception") { try? stateManager.start() }
                } else {
                    Button("Arrêter complètement la perception", role: .destructive) { stateManager.stop() }
                }
            }

            Section("Données collectées et livrables") {
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
            Text("Les événements, la mémoire, les missions, les brouillons et les registres d’activité seront effacés de GHOST. Les fichiers créés et les rendez-vous déjà ajoutés resteront dans vos dossiers et votre agenda. Les autorisations restent en place ; révoquez-les dans « Sources ».")
        }
    }

    private func guarantee(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
    }
}
