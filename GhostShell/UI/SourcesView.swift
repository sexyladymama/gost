import SwiftUI
import GhostPerception

/// Autorisation, activation et révocation des sources de perception.
struct SourcesView: View {
    let perception: PerceptionController
    @State private var confirmEmailRevocation = false
    @State private var confirmFolderRevocation = false

    var body: some View {
        @Bindable var perception = perception
        Form {
            if let error = perception.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }

            Section {
                Toggle("GHOST peut chercher en ligne (lieux avec Apple Plans, web avec DuckDuckGo)", isOn: Binding(get: { perception.searchEnabled },
                                                                                               set: { value in Task { await perception.setSearchEnabled(value) } }))
                TextField("Mon quartier ou ma ville (pour « chez nous »)", text: $perception.homeArea).textFieldStyle(.roundedBorder)
                Text("Seules la question (« club de boxe ») et la zone (« Courbevoie ») sont envoyées à Apple Plans ; pour le web, seule la question est envoyée à DuckDuckGo. Votre adresse reste sur ce Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Recherche")
            }

            Section {
                HStack {
                    Text(perception.outputFolderName.map { "Dossier : \($0)" } ?? "Aucun dossier choisi").foregroundStyle(perception.outputFolderName == nil ? .orange : .primary)
                    Spacer()
                    Button(perception.outputFolderName == nil ? "Choisir un dossier…" : "Changer…") { Task { await perception.chooseOutputFolder() } }
                }
                Text("GHOST y range les logos et documents qu'il crée à votre demande. Il n'écrase jamais un fichier existant.").font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Création")
            }

            Section {
                Toggle("GHOST regarde mon écran", isOn: Binding(get: { perception.screenEnabled },
                                                                  set: { value in Task { await perception.setScreenObservation(value) } }))
                if perception.screenEnabled {
                    if perception.screenPermission {
                        Label("Autorisation macOS « Enregistrement de l'écran » accordée.", systemImage: "checkmark.shield").foregroundStyle(.green)
                    } else {
                        Label("macOS n'a pas encore autorisé GHOST à enregistrer l'écran : accordez-le dans Réglages Système, puis quittez et relancez GHOST.",
                              systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                        Button("Ouvrir les réglages de confidentialité") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    TextField("Applications à ne jamais lire (séparées par des virgules)", text: $perception.excludedApps)
                        .textFieldStyle(.roundedBorder)
                    Text("Toujours ignorés : gestionnaires de mots de passe, sites de banque et de paiement, navigation privée, la fenêtre de GHOST, écran verrouillé. Seul le texte utile (une demande, un rendez-vous) est conservé, jamais d'image. ⌃⌥⌘G met GHOST en pause.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Écran")
            }

            Section {
                if let status = perception.status(of: perception.gmailID) {
                    SourceStatusRow(status: status, center: perception.center)
                }
                switch perception.emailMode {
                case .none:
                    Text("Aucune boîte e-mail n'est autorisée. GHOST ne lit aucun e-mail.")
                        .foregroundStyle(.secondary)
                    Button("Utiliser la boîte de test (simulation)") {
                        Task { await perception.useSimulatedMailbox() }
                    }
                case .simulation:
                    Label("Mode simulation : les e-mails sont fictifs et générés localement. Aucun accès réseau.",
                          systemImage: "testtube.2")
                        .foregroundStyle(.orange)
                case .gmail:
                    LabeledContent("Compte Gmail", value: perception.gmailAccount ?? "—")
                    Text("Accès en lecture seule (gmail.readonly). GHOST ne peut ni envoyer, ni modifier, ni supprimer d'e-mail.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if perception.emailMode != .none {
                    Button("Révoquer l'accès e-mail…", role: .destructive) { confirmEmailRevocation = true }
                }
            } header: {
                Text("E-mail")
            }

            Section {
                TextField("Identifiant client OAuth (type iOS)", text: $perception.googleClientID,
                          prompt: Text("1234-abcd.apps.googleusercontent.com"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                HStack {
                    Button(perception.emailMode == .gmail ? "Reconnecter Gmail…" : "Connecter Gmail…") {
                        Task { await perception.connectGmail() }
                    }
                    .disabled(perception.googleClientID.trimmingCharacters(in: .whitespaces).isEmpty || perception.isConnecting)
                    if perception.isConnecting { ProgressView().controlSize(.small) }
                }
                Text("Nécessite un projet Google Cloud avec l'API Gmail activée et un identifiant client de type « iOS » (identifiant de lot app.ghost.shell). Voir le README.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Compte Gmail réel")
            }

            Section {
                if let status = perception.status(of: perception.folderID) {
                    SourceStatusRow(status: status, center: perception.center)
                }
                if let url = perception.folderURL {
                    LabeledContent("Dossier autorisé") {
                        Text(url.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    HStack {
                        Button("Changer de dossier…") { Task { await perception.chooseFolder() } }
                        Button("Révoquer l'accès…", role: .destructive) { confirmFolderRevocation = true }
                    }
                } else {
                    Text("Aucun dossier n'est autorisé. GHOST n'accède à aucun fichier.")
                        .foregroundStyle(.secondary)
                    Button("Choisir un dossier…") { Task { await perception.chooseFolder() } }
                }
                Text("Seules les métadonnées (nom, type, taille, dates) des fichiers de ce dossier sont observées. Le contenu n'est jamais lu ; rien n'est modifié ni supprimé.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Dossier local")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Révoquer l'accès e-mail ?", isPresented: $confirmEmailRevocation) {
            Button("Révoquer et effacer les données dérivées", role: .destructive) {
                Task { await perception.removeEmailSource(deleteData: true) }
            }
            Button("Révoquer, conserver l'historique") {
                Task { await perception.removeEmailSource(deleteData: false, retainContext: true) }
            }
        } message: {
            Text("GHOST cessera de lire cette boîte. L'effacement retire ses événements, sa mémoire et les missions qui en dépendent. La conservation garde cet historique. Pour Gmail, le jeton est révoqué auprès de Google et effacé du Trousseau.")
        }
        .confirmationDialog("Révoquer l'accès au dossier ?", isPresented: $confirmFolderRevocation) {
            Button("Révoquer et effacer les données dérivées", role: .destructive) {
                Task { await perception.removeFolderSource(deleteData: true) }
            }
            Button("Révoquer, conserver l'historique") {
                Task { await perception.removeFolderSource(deleteData: false, retainContext: true) }
            }
        } message: {
            Text("L'effacement retire les événements, la mémoire et les missions dépendant de ce dossier. La conservation garde cet historique. Aucun document du dossier n'est supprimé.")
        }
    }
}

/// État d'une source avec son interrupteur d'activation.
struct SourceStatusRow: View {
    let status: SourceStatus
    let center: PerceptionCenter

    var body: some View {
        Toggle(isOn: Binding(get: { status.isEnabled },
                             set: { center.setSourceEnabled(status.id, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.descriptor.displayName).font(.headline)
                    if status.descriptor.isSimulated { SimulationBadge() }
                }
                HStack(spacing: 6) {
                    Circle().fill(status.health.color).frame(width: 7, height: 7)
                    Text(status.health.label)
                    if let last = status.lastSuccess {
                        Text("· dernière collecte \(last.formatted(date: .omitted, time: .standard))")
                    }
                    Text("· \(status.detectedCount) événement(s)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = status.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .toggleStyle(.switch)
    }
}
