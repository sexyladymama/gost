import SwiftUI
import GhostMind

/// Brouillons rédigés par GHOST à partir de ce qu'il a vu. Rien ne part sans le clic sur « Envoyer ».
struct DraftsView: View {
    let perception: PerceptionController
    private var center: MindCenter { perception.mind }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = center.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(10) }
            modelBanner
            if center.drafts.isEmpty {
                ContentUnavailableView("Aucun brouillon", systemImage: "envelope",
                                       description: Text("Quand un message vous demande d'écrire à quelqu'un (« écris un mail à Paul pour décaler jeudi »), GHOST rédige le mail et le présente ici."))
            } else {
                ScrollView {
                    VStack(spacing: 14) { ForEach(center.drafts) { DraftCard(draft: $0, perception: perception) } }.padding(14)
                }
            }
        }
        .task { await center.reload() }
    }

    @ViewBuilder private var modelBanner: some View {
        HStack(spacing: 10) {
            switch center.modelAvailability {
            case .available:
                Image(systemName: "sparkles").foregroundStyle(.green)
                Text("GHOST rédige avec « \(center.modelName ?? "") ». Rien n'est envoyé sans votre clic.").font(.callout)
            case .unavailable(let reason):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GHOST ne peut pas encore rédiger lui-même : \(reason)").font(.callout)
                    Text("En attendant, il prépare des brouillons simplifiés que vous pouvez corriger.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Ouvrir les réglages") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }.buttonStyle(GhostButtonStyle(prominent: true))
                Button("Revérifier") { Task { await center.reload() } }.buttonStyle(GhostButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct DraftCard: View {
    let draft: MailDraft
    let perception: PerceptionController
    @State private var to: String
    @State private var subject: String
    @State private var bodyText: String

    init(draft: MailDraft, perception: PerceptionController) {
        self.draft = draft; self.perception = perception
        _to = State(initialValue: draft.recipientEmail ?? ""); _subject = State(initialValue: draft.subject); _bodyText = State(initialValue: draft.body)
    }

    private var editable: Bool { ![.sending, .sent].contains(draft.status) }
    private var status: (String, Color) {
        switch draft.status {
        case .ready: return ("Prêt à envoyer", .green); case .needsModel: return ("Brouillon simplifié", .orange)
        case .sending: return ("Envoi…", .secondary); case .sent: return ("Envoyé", .secondary)
        case .cancelled: return ("Annulé", .secondary); case .failed: return ("À vérifier", .red)
        }
    }
    private var validTarget: Bool { MailDraft.isValidAddress(to.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.recipientName.map { "Pour \($0)" } ?? "Nouveau mail").font(.headline)
                Spacer()
                Chip(text: status.0, color: status.1)
            }
            Text("D'après : « \(draft.basis) » · \(draft.generatedBy)" + (draft.version > 1 ? " · version \(draft.version)" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let note = draft.note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
            TextField("Adresse du destinataire", text: $to).textFieldStyle(.roundedBorder).disabled(!editable)
            TextField("Objet", text: $subject).textFieldStyle(.roundedBorder).disabled(!editable)
            TextEditor(text: $bodyText).font(.body).frame(minHeight: 130).scrollContentBackground(.hidden)
                .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).disabled(!editable)
            if editable {
                HStack {
                    Button("Envoyer" + (validTarget ? " à \(to.trimmingCharacters(in: .whitespaces))" : "")) { send() }
                        .buttonStyle(GhostButtonStyle(prominent: true)).disabled(!validTarget || subject.isEmpty || bodyText.isEmpty)
                    Button("Refaire") { run { try await $0.redo(draft.id) } }.buttonStyle(GhostButtonStyle())
                    Button("Annuler", role: .destructive) { run { try await $0.cancel(draft.id) } }.buttonStyle(GhostButtonStyle(destructive: true))
                    Spacer()
                    if hasChanges { Text("modifié").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(14)
        .ghostGlass(cornerRadius: 14)
        .onChange(of: draft.version) { _, _ in to = draft.recipientEmail ?? ""; subject = draft.subject; bodyText = draft.body }
    }

    private var hasChanges: Bool { subject != draft.subject || bodyText != draft.body || to != (draft.recipientEmail ?? "") }

    /// Le clic sur « Envoyer » EST la confirmation de l'utilisateur : c'est le seul endroit où elle est donnée.
    private func send() {
        let (id, address, subject, text) = (draft.id, to.trimmingCharacters(in: .whitespaces), subject, bodyText)
        run { engine in
            try await engine.edit(id, to: address, subject: subject, body: text)
            try await engine.send(id, confirmedByUser: true)
        }
    }
    private func run(_ action: @escaping @Sendable (MindEngine) async throws -> Void) {
        Task { await perception.mind.perform(action) }
    }
}
