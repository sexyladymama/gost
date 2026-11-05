import SwiftUI
import GhostKit
import GhostPerception

/// Fenêtre principale de GHOST PERCEPTION : ce que GHOST a détecté, pourquoi,
/// et le contrôle complet des sources et des données.
struct PerceptionWindow: View {
    enum Section: String, CaseIterable, Identifiable {
        case missions, agenda, activity, events, memory, issues, sources, accessLog, privacy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .events: return "Événements"
            case .missions: return "Missions"
            case .agenda: return "Agenda"
            case .activity: return "Activité"
            case .memory: return "Mémoire"
            case .issues: return "Anomalies"
            case .sources: return "Sources"
            case .accessLog: return "Journal d'accès"
            case .privacy: return "Confidentialité"
            }
        }
        var symbol: String {
            switch self {
            case .events: return "tray.full"
            case .missions: return "scope"
            case .agenda: return "calendar"
            case .activity: return "play.circle"
            case .memory: return "brain"
            case .issues: return "exclamationmark.triangle"
            case .sources: return "antenna.radiowaves.left.and.right"
            case .accessLog: return "list.bullet.rectangle"
            case .privacy: return "hand.raised"
            }
        }
    }

    let stateManager: GhostStateManager
    let perception: PerceptionController
    @State private var section: Section? = .missions
    @State private var showOnboarding = false
    @AppStorage(GhostAppearance.storageKey) private var appearanceRaw = GhostAppearance.dark.rawValue

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                GhostWordmark(size: 24, subtitle: "perception · mémoire · cerveau")
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch section ?? .missions {
            case .events: EventsView(center: perception.center)
            case .missions: MissionsView(perception: perception)
            case .agenda: AgendaView(perception: perception)
            case .activity: AutonomyView(perception: perception)
            case .memory: ContextView(perception: perception)
            case .issues: IssuesView(center: perception.center)
            case .sources: SourcesView(perception: perception)
            case .accessLog: AccessLogView(center: perception.center)
            case .privacy: PrivacyView(stateManager: stateManager, perception: perception)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                GhostActivityIndicator(state: stateManager.state, engineState: perception.center.engineState)
            }
            ToolbarItem { GhostAppearanceToggle() }
            ToolbarItem {
                Button {
                    perception.center.refreshNow()
                } label: {
                    Label("Collecter maintenant", systemImage: "arrow.clockwise")
                }
                .disabled(stateManager.state != .active)
                .help("Interroge immédiatement les sources actives (sans effet en pause)")
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .scrollContentBackground(.hidden)
        .background(GhostBackdrop())
        .ghostAppearance(GhostAppearance(rawValue: appearanceRaw) ?? .dark)
        .sheet(isPresented: $showOnboarding) { OnboardingView(perception: perception) }
        .task {
            showOnboarding = !perception.onboardingDone
            await perception.calendar.reload()
        }
    }

    private func badge(for item: Section) -> Int {
        switch item {
        case .missions: return perception.brain.missions.filter { [.proposed, .needsClarification].contains($0.state) }.count
        case .agenda: return perception.calendar.entries.filter { $0.status == .suggested }.count
        case .events: return perception.center.unseenImportant.count
        case .issues: return perception.center.issues.count
        default: return 0
        }
    }
}

/// Indique toujours clairement si GHOST est actif.
struct GhostActivityIndicator: View {
    let state: GhostState
    let engineState: EngineState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            Text("GHOST \(state.displayName)")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            Text("· \(engineState.label)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Événements

struct EventsView: View {
    let center: PerceptionCenter
    @State private var selection: GhostEvent.ID?
    @State private var showAll = false

    private var visible: [GhostEvent] { showAll ? center.events : center.importantEvents }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Affichage", selection: $showAll) {
                    Text("Importants").tag(false)
                    Text("Tous (\(center.events.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                if visible.isEmpty {
                    ContentUnavailableView("Aucun événement",
                                           systemImage: "tray",
                                           description: Text(center.sources.isEmpty
                                                             ? "Autorisez une source dans « Sources » pour que GHOST commence à percevoir."
                                                             : "GHOST n'a encore rien détecté de notable."))
                } else {
                    List(visible, selection: $selection) { event in
                        EventRow(event: event, isUnseen: center.unseenImportant.contains(event.id))
                            .tag(event.id)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 360)

            Group {
                if let id = selection, let event = center.events.first(where: { $0.id == id }) {
                    EventDetailView(event: event)
                        .onAppear { center.markSeen(id) }
                        .id(id)
                } else {
                    ContentUnavailableView("Sélectionnez un événement", systemImage: "sidebar.left",
                                           description: Text("Le détail indique pourquoi GHOST l'a détecté."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EventRow: View {
    let event: GhostEvent
    let isUnseen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.kind.symbolName)
                .foregroundStyle(event.kind.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(event.source.displayName)
                    if let deadline = event.deadline {
                        Label(deadline.date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    }
                    if event.isMissionCandidate { Text("· mission possible") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isUnseen {
                Circle().fill(.blue).frame(width: 7, height: 7).accessibilityLabel("Non consulté")
            }
        }
        .padding(.vertical, 2)
    }
}

struct EventDetailView: View {
    let event: GhostEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    EventKindBadge(kind: event.kind)
                    ForEach(event.tags.sorted().filter { $0 != event.kind }, id: \.self) { tag in
                        EventKindBadge(kind: tag)
                    }
                    if event.source.isSimulated { SimulationBadge() }
                }
                Text(event.summary).font(.title3.weight(.semibold)).textSelection(.enabled)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Source", event.source.displayName)
                    row("Titre", event.title)
                    row("Détecté le", event.detectedAt.formatted(date: .complete, time: .shortened))
                    row(event.source.kind == .email ? "Reçu le" : "Modifié le",
                        event.occurredAt.formatted(date: .complete, time: .shortened))
                    if !event.people.isEmpty {
                        row("Personnes", event.people.map { person in
                            let role = person.role == .sender ? "expéditeur" : person.role == .copied ? "copie" : "destinataire"
                            return "\(person.displayName) (\(role))"
                        }.joined(separator: "\n"))
                    }
                    if let action = event.expectedAction { row("Action attendue", action) }
                    if let output = event.expectedOutput { row("Résultat attendu", output) }
                    if !event.requiredInformation.isEmpty {
                        row("Informations nécessaires", event.requiredInformation.joined(separator: "\n"))
                    }
                    if let deadline = event.deadline {
                        row("Échéance", "\(deadline.date.formatted(date: .complete, time: .shortened))\n« \(deadline.text) »")
                    }
                    GridRow {
                        Text("Confiance").foregroundStyle(.secondary)
                        HStack {
                            ProgressView(value: event.confidence).frame(width: 120)
                            Text("\(Int((event.confidence * 100).rounded())) %").monospacedDigit()
                        }
                    }
                    row("Mission possible", event.isMissionCandidate
                        ? "Oui — signalée aux futurs moteurs. Aucune action n'est exécutée."
                        : "Non")
                    ForEach(event.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                        row(item.key, item.value)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pourquoi GHOST l'a détecté").font(.headline)
                    ForEach(Array(event.evidence.enumerated()), id: \.offset) { _, evidence in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(evidence.explanation)
                            if let excerpt = evidence.excerpt {
                                Text("« \(excerpt) »").font(.callout).italic().foregroundStyle(.secondary)
                            }
                            Text(evidence.rule).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    Text("Interprétation par règles explicites (pas d'IA). Le contenu intégral de la source n'est pas conservé.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Anomalies

struct IssuesView: View {
    let center: PerceptionCenter

    var body: some View {
        Group {
            if center.issues.isEmpty {
                ContentUnavailableView("Aucune anomalie", systemImage: "checkmark.seal",
                                       description: Text("Les erreurs de connexion ou d'accès apparaîtront ici."))
            } else {
                List(center.issues) { issue in
                    HStack(alignment: .top) {
                        Image(systemName: issue.kind == .access ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.kind == .access ? .red : .orange)
                        VStack(alignment: .leading) {
                            Text(issue.message)
                            Text("\(issue.sourceID.rawValue) · \(issue.date.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .toolbar {
            Button("Effacer") { center.dismissIssues() }.disabled(center.issues.isEmpty)
        }
    }
}

// MARK: - Journal d'accès

struct AccessLogView: View {
    let center: PerceptionCenter

    var body: some View {
        Table(center.accessRecords) {
            TableColumn("Date") { Text($0.date.formatted(date: .numeric, time: .standard)).monospacedDigit() }
                .width(min: 140, ideal: 160)
            TableColumn("Source") { Text($0.sourceID.rawValue) }.width(min: 60, ideal: 70)
            TableColumn("Opération") { Text($0.operation).font(.body.monospaced()) }.width(min: 120, ideal: 140)
            TableColumn("Cible") { Text($0.target).lineLimit(1).truncationMode(.middle).help($0.target) }
            TableColumn("Résultat") { record in
                Text(record.outcome == .allowed ? "autorisé" : record.outcome == .denied ? "refusé" : "échec")
                    .foregroundStyle(record.outcome == .allowed ? Color.primary : record.outcome == .denied ? .red : .orange)
                    .help(record.detail ?? "")
            }
            .width(min: 70, ideal: 80)
        }
        .task { await center.reloadAccessLog() }
        .toolbar {
            Button {
                Task { await center.reloadAccessLog() }
            } label: {
                Label("Actualiser le journal", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}
