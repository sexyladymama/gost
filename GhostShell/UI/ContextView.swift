import SwiftUI
import GhostKit
import GhostPerception
import GhostContext

/// « Mémoire » — ce que GHOST comprend du contexte, avec preuves et corrections.
///
/// Chaque information indique son statut (confirmé, hypothèse, inconnu), d'où
/// elle vient et pourquoi. Rien n'est exécuté : la mémoire ne fait que comprendre.
struct ContextView: View {
    let perception: PerceptionController
    @State private var domain: MemoryDomain = .project
    @State private var query = ""
    @State private var results: [ContextNode] = []
    @State private var selection: String?
    @State private var showAdd = false

    private var center: ContextCenter { perception.context }

    private var visible: [ContextNode] {
        let base = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? center.graph.entities(in: domain)
            : results
        return base.filter { $0.domain == domain }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = center.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.08))
            }
            ScopeClassifier(perception: perception)
            Divider()
            Picker("Catégorie", selection: $domain) {
                ForEach(MemoryDomain.allCases, id: \.self) { item in
                    Text("\(item.label) (\(center.graph.entities(in: item).count))").tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            HSplitView {
                list.frame(minWidth: 280, idealWidth: 340)
                detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $query, prompt: "Rechercher dans la mémoire locale")
        .task(id: "\(query)|\(center.graph.nodes.count)") {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
            results = await center.search(query, domain: nil, scope: nil)
        }
        .toolbar {
            ToolbarItem {
                Button { showAdd = true } label: { Label("Ajouter une information", systemImage: "plus") }
                    .help("Ajouter une préférence, une décision ou un projet que vous confirmez vous-même")
            }
            ToolbarItem {
                Button { Task { await perception.refreshContext() } } label: {
                    Label("Reconstruire depuis les événements", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Rejoue les événements autorisés ; les corrections sont conservées")
            }
        }
        .sheet(isPresented: $showAdd) { AddMemorySheet(center: center, projects: center.graph.entities(in: .project)) }
    }

    @ViewBuilder private var list: some View {
        if visible.isEmpty {
            ContentUnavailableView(query.isEmpty ? "Rien dans « \(domain.label) »" : "Aucun résultat",
                                   systemImage: "brain",
                                   description: Text("La mémoire se construit uniquement à partir des sources que vous autorisez et de ce que vous ajoutez."))
        } else {
            List(visible, selection: $selection) { node in
                ContextRow(node: node).tag(node.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let node = center.graph.nodes[id] {
            ContextDetail(node: node, perception: perception, selection: $selection).id(id)
        } else {
            ContentUnavailableView("Sélectionnez une information", systemImage: "sidebar.left",
                                   description: Text("Le détail indique d'où elle vient et si elle est confirmée."))
        }
    }
}

// MARK: - Classement des sources

struct ScopeClassifier: View {
    let perception: PerceptionController
    private var graph: ContextSnapshot { perception.context.graph }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Contexte de chaque source").font(.headline)
            Text("Le personnel et le professionnel ne sont jamais mélangés. Une source non classée reste isolée.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                if perception.emailMode != .none { picker("E-mail", id: perception.gmailID) }
                if perception.folderURL != nil { picker("Dossier", id: perception.folderID) }
                if perception.screenEnabled { picker("Écran", id: perception.screenID) }
                if perception.emailMode == .none && perception.folderURL == nil {
                    Text("Aucune source autorisée.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func picker(_ title: String, id: SourceID) -> some View {
        Picker(title, selection: Binding(
            get: { graph.scopes[id.rawValue] ?? .unclassified },
            set: { scope in Task { await perception.setContextScope(scope, source: id) } })) {
            ForEach(ContextScope.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}

// MARK: - Liste

struct ContextRow: View {
    let node: ContextNode
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: node.kind.symbol).foregroundStyle(node.status.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(node.kind.label)
                    Text("· " + node.status.label)
                    Text("· " + node.scope.label)
                    if node.isSimulated { Text("· simulation") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Détail

struct ContextDetail: View {
    let node: ContextNode
    let perception: PerceptionController
    @Binding var selection: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmDelete = false

    private var center: ContextCenter { perception.context }
    private var graph: ContextSnapshot { center.graph }

    private var relations: [ContextRelation] {
        graph.relations.values.filter { $0.from == node.id || $0.to == node.id }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if node.kind == .project, let summary = ContextRetrieval.summary(projectID: node.id, graph: graph) {
                    ProjectSummaryView(summary: summary, graph: graph)
                }
                if node.kind == .taskCandidate { taskControls }
                if let note = node.properties["ambiguity"] {
                    Label(note, systemImage: "questionmark.diamond").foregroundStyle(.orange)
                }
                properties
                relationsSection
                provenance
                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Supprimer cette information ?", isPresented: $confirmDelete) {
            Button("Supprimer (ne reviendra pas)", role: .destructive) {
                let id = node.id
                selection = nil
                Task { await center.perform { try await $0.deleteNode(id) } }
            }
        } message: {
            Text("Les informations qui n'existent que grâce à celle-ci sont supprimées aussi.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(node.kind.label).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text(node.status.label).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(node.status.color.opacity(0.2), in: Capsule())
                Text(node.scope.label).font(.caption).foregroundStyle(.secondary)
                if node.isSimulated { SimulationBadge() }
            }
            if editing {
                TextField("Texte", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Enregistrer") {
                        let id = node.id, text = draft
                        editing = false
                        Task { await center.perform { try await $0.correctNode(id, title: text) } }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Annuler") { editing = false }
                }
            } else {
                Text(node.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            }
            HStack {
                ProgressView(value: node.confidence).frame(width: 120)
                Text("Confiance \(Int((node.confidence * 100).rounded())) %").monospacedDigit()
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var taskControls: some View {
        let status = node.properties["processingStatus"] ?? "pending"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Demande candidate").font(.headline)
            Picker("Statut", selection: Binding(get: { status }, set: { value in
                let id = node.id
                Task { await center.perform { try await $0.setTaskStatus(id, status: value) } }
            })) {
                Text("À examiner").tag("pending")
                Text("Examinée").tag("reviewed")
                Text("Écartée").tag("dismissed")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            Text("GHOST ne l'exécute pas : il l'enregistre seulement comme contexte.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var properties: some View {
        let hidden: Set<String> = ["eventID", "sourceID", "userEdited", "matchingName", "ambiguity", "processingStatus"]
        let shown = node.properties.filter { !hidden.contains($0.key) && !$0.value.isEmpty }.sorted { $0.key < $1.key }
        return Group {
            if !shown.isEmpty || node.occurredAt != nil {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    if let date = node.occurredAt {
                        row("Date", date.formatted(date: .complete, time: .shortened))
                    }
                    ForEach(shown, id: \.key) { row($0.key, $0.value) }
                }
            }
        }
    }

    private var relationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Liens").font(.headline)
            if relations.isEmpty { Text("Aucun lien connu.").foregroundStyle(.secondary) }
            ForEach(relations) { relation in
                let otherID = relation.from == node.id ? relation.to : relation.from
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(graph.nodes[otherID]?.title ?? "—").lineLimit(2)
                        Text("\(relation.kind.rawValue.replacingOccurrences(of: "_", with: " ").lowercased()) · \(relation.status.label)")
                            .font(.caption).foregroundStyle(relation.status.color)
                    }
                    Spacer()
                    if relation.status != .confirmed {
                        Button("Confirmer") {
                            let id = relation.id
                            Task { await center.perform { try await $0.confirmRelation(id) } }
                        }
                    }
                    Button("Rejeter", role: .destructive) {
                        let id = relation.id
                        Task { await center.perform { try await $0.rejectRelation(id) } }
                    }
                }
            }
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pourquoi GHOST le sait").font(.headline)
            ForEach(Array(node.provenance.enumerated()), id: \.offset) { _, proof in
                VStack(alignment: .leading, spacing: 2) {
                    Text(proof.explanation)
                    Text(proof.isUserProvided ? "Vous · \(proof.recordedAt.formatted())"
                         : "\(proof.sourceID?.rawValue ?? "—") · \(proof.recordedAt.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Une information répétée n'est jamais promue en fait : seule votre confirmation la rend certaine.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            if node.status != .confirmed {
                Button("Confirmer") {
                    let id = node.id, title = node.title
                    Task { await center.perform { try await $0.correctNode(id, title: title, status: .confirmed) } }
                }
            }
            Button("Corriger le texte") { draft = node.title; editing = true }
            Button("Supprimer", role: .destructive) { confirmDelete = true }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

struct ProjectSummaryView: View {
    let summary: ContextProjectSummary
    let graph: ContextSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Synthèse du projet").font(.headline)
            Text("\(summary.events.count) événement(s) · \(summary.documents.count) document(s) · \(summary.people.count) personne(s) · \(summary.tasks.count) demande(s)")
                .foregroundStyle(.secondary)
            if let deadline = summary.latestDeadline, let date = deadline.occurredAt {
                Label("Dernière échéance : \(date.formatted(date: .complete, time: .shortened))", systemImage: "clock")
            }
            if !summary.ambiguities.isEmpty {
                ForEach(summary.ambiguities, id: \.self) { Label($0, systemImage: "questionmark.diamond").foregroundStyle(.orange) }
            }
            if !summary.missingInformation.isEmpty {
                Text("Ce que GHOST ne sait pas").font(.subheadline.weight(.semibold))
                ForEach(summary.missingInformation, id: \.self) { Label($0, systemImage: "circle.dashed").foregroundStyle(.secondary) }
            }
            let timeline = ContextRetrieval.timeline(projectID: summary.project.id, graph: graph)
            if !timeline.isEmpty {
                Text("Chronologie").font(.subheadline.weight(.semibold))
                ForEach(timeline.prefix(20)) { item in
                    HStack(alignment: .top) {
                        Text((item.occurredAt ?? item.createdAt).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(item.title).lineLimit(2)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Ajout manuel

struct AddMemorySheet: View {
    let center: ContextCenter
    let projects: [ContextNode]
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ContextEntityKind = .preference
    @State private var scope: ContextScope = .professional
    @State private var text = ""
    @State private var projectID: String = ""

    private let kinds: [ContextEntityKind] = [.preference, .decision, .project, .person, .organization]

    var body: some View {
        Form {
            Picker("Type", selection: $kind) { ForEach(kinds, id: \.self) { Text($0.label).tag($0) } }
            Picker("Contexte", selection: $scope) {
                Text("Personnel").tag(ContextScope.personal)
                Text("Professionnel").tag(ContextScope.professional)
            }
            if kind == .decision {
                Picker("Projet", selection: $projectID) {
                    Text("Aucun").tag("")
                    ForEach(projects.filter { $0.scope == scope }) { Text($0.title).tag($0.id) }
                }
            }
            TextField("Information", text: $text, axis: .vertical).lineLimit(3...6)
            Text("Ce que vous ajoutez ici est considéré comme confirmé et reste dans le contexte choisi.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Ajouter") {
                    let (k, s, t, p) = (kind, scope, text, projectID.isEmpty ? nil : projectID)
                    Task { await center.perform { _ = try await $0.remember(kind: k, text: t, scope: s, projectID: p) } }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }
}

// MARK: - Apparence

extension KnowledgeStatus {
    var color: Color {
        switch self {
        case .confirmed: return .green
        case .hypothesis: return .orange
        case .unknown: return .gray
        }
    }
}

extension ContextEntityKind {
    var symbol: String {
        switch self {
        case .person: return "person"
        case .organization: return "building.2"
        case .project: return "folder"
        case .event: return "calendar"
        case .document: return "doc"
        case .conversation: return "bubble.left.and.bubble.right"
        case .taskCandidate: return "checklist"
        case .deadline: return "clock"
        case .decision: return "checkmark.seal"
        case .preference: return "slider.horizontal.3"
        }
    }
}
