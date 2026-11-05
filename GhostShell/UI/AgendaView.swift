import SwiftUI
import GhostVision

/// Rendez-vous repérés à l'écran : ce que GHOST a ajouté à l'agenda (annulable), ce qu'il propose, et pourquoi.
struct AgendaView: View {
    let perception: PerceptionController
    private var center: CalendarCenter { perception.calendar }
    private var shown: [CalendarEntry] { center.entries.sorted { $0.start < $1.start } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = center.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(10) }
            banner
            if shown.isEmpty {
                ContentUnavailableView("Aucun rendez-vous repéré", systemImage: "calendar",
                                       description: Text("Quand un message vu à l'écran annonce un rendez-vous (« dîner le 10 novembre à 21h »), il apparaît ici."))
            } else {
                List(shown) { EntryRow(entry: $0, perception: perception) }
            }
        }
        .task { await perception.refreshScreenPermission() }
    }

    @ViewBuilder private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: center.authorization == .authorized ? "checkmark.shield" : "exclamationmark.shield")
                .foregroundStyle(center.authorization == .authorized ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(center.authorization == .authorized
                     ? (perception.calendarAutoAdd ? "Ajout direct activé : GHOST ajoute les rendez-vous sûrs et vous laisse annuler."
                                                   : "Accès à l'agenda accordé. L'ajout direct est désactivé : GHOST propose seulement.")
                     : "GHOST n'a pas encore accès à votre agenda : il ne peut que proposer.")
                    .font(.callout)
                Text("GHOST ne supprime que les événements qu'il a lui-même ajoutés.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if center.authorization != .authorized {
                Button("Autoriser l'accès") { Task { await center.requestAccess() } }.buttonStyle(GhostButtonStyle(prominent: true))
            }
            Toggle("Ajout direct", isOn: Binding(get: { perception.calendarAutoAdd },
                                                  set: { value in Task { await perception.setCalendarAutoAdd(value) } }))
                .toggleStyle(.switch)
        }
        .padding(12)
    }
}

private struct EntryRow: View {
    let entry: CalendarEntry
    let perception: PerceptionController
    @State private var chosen: Date

    init(entry: CalendarEntry, perception: PerceptionController) {
        self.entry = entry; self.perception = perception; _chosen = State(initialValue: entry.start)
    }

    private var statusText: (String, Color) {
        switch entry.status {
        case .added: return ("Ajouté à l'agenda", .green)
        case .suggested: return ("Suggestion", .orange)
        case .alreadyPresent: return ("Déjà dans l'agenda", .secondary)
        case .dismissed: return ("Ignoré", .secondary)
        case .undone: return ("Ajout annulé", .secondary)
        case .failed: return ("Échec", .red)
        case .pending: return ("En cours", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title).font(.headline)
                Spacer()
                Chip(text: statusText.0, color: statusText.1)
            }
            Text(entry.start.formatted(date: .complete, time: entry.hasExplicitTime ? .shortened : .omitted) + (entry.hasExplicitTime ? "" : " — heure à préciser"))
                .font(.callout)
            Text("Vu dans \(entry.sourceApp) : « \(entry.excerpt) »").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let reason = entry.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if entry.status == .added {
                    Button("Annuler l'ajout") { run { try await $0.undo(entry.id) } }.buttonStyle(GhostButtonStyle(destructive: true))
                }
                if [.suggested, .failed].contains(entry.status) {
                    if !entry.hasExplicitTime { DatePicker("", selection: $chosen).labelsHidden() }
                    Button("Ajouter à l'agenda") { run { try await $0.accept(entry.id, start: entry.hasExplicitTime ? nil : chosen) } }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                    Button("Ignorer") { run { try await $0.dismiss(entry.id) } }.buttonStyle(GhostButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func run(_ action: @escaping @Sendable (CalendarAgent) async throws -> Void) {
        Task { await perception.calendar.perform(action) }
    }
}
