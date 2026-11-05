import SwiftUI
import GhostKit
import GhostPerception
import GhostBrain

/// « Missions » — ce que GHOST a décidé de suivre, pourquoi, et comment il s'y prendrait.
///
/// GHOST BRAIN **propose** : rien n'est exécuté. READY signifie « plan précis, prérequis
/// identifiés », jamais « autorisation d'agir ».
struct MissionsView: View {
    let perception: PerceptionController
    @State private var filter: Filter = .open
    @State private var selection: String?
    @State private var showSettings = false

    private var center: BrainCenter { perception.brain }

    enum Filter: String, CaseIterable, Identifiable {
        case open, clarify, proposed, blocked, ready, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .open: return "Ouvertes"; case .clarify: return "À clarifier"; case .proposed: return "Proposées"
            case .blocked: return "Bloquées"; case .ready: return "Prêtes"; case .done: return "Terminées"
            }
        }
        func matches(_ m: Mission) -> Bool {
            switch self {
            case .open: return m.isOpen
            case .clarify: return m.state == .needsClarification
            case .proposed: return m.state == .proposed
            case .blocked: return m.state == .blocked
            case .ready: return m.state == .ready || m.state == .inProgress
            case .done: return m.state.isTerminal
            }
        }
    }

    private var visible: [Mission] { center.missions.filter { filter.matches($0) } }

    var body: some View {
        VStack(spacing: 0) {
            if let error = center.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.red.opacity(0.08))
            }
            safetyBanner
            Picker("Filtre", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text("\(f.title) (\(center.missions.filter { f.matches($0) }.count))").tag(f)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            HSplitView {
                list.frame(minWidth: 300, idealWidth: 360)
                detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showSettings = true } label: { Label("Réglages du cerveau", systemImage: "slider.horizontal.3") }
                    .help("Modèle externe, limites, journal technique")
            }
            ToolbarItem {
                Button { Task { await perception.catchUpBrain() } } label: { Label("Analyser à nouveau", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Analyse les événements non encore traités (aucun doublon)")
            }
        }
        .sheet(isPresented: $showSettings) { BrainSettingsSheet(perception: perception) }
        .task { await center.reload() }
    }

    private var safetyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
            Text("GHOST planifie. Dans Activité, une mission Excel confirmée peut être exécutée localement après autorisation des dossiers. Aucun envoi externe n'est automatique.")
                .font(.callout)
            Spacer()
        }
        .foregroundStyle(GhostTheme.dim)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var list: some View {
        if visible.isEmpty && center.watches.isEmpty {
            ContentUnavailableView(filter == .open ? "Aucune mission ouverte" : "Rien dans « \(filter.title) »", systemImage: "scope",
                                   description: Text("GHOST crée une mission seulement lorsqu'une demande claire le justifie — et sait ne rien faire."))
        } else {
            List(selection: $selection) {
                ForEach(visible) { MissionRow(mission: $0, handledIn: perception.mind.handledIn($0.id)).tag($0.id) }
                if filter == .open && !center.watches.isEmpty {
                    Section("À surveiller (pas encore une mission)") {
                        ForEach(center.watches) { watch in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(watch.summary).lineLimit(2)
                                Text(watch.clarificationQuestion).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let mission = center.state.missions[id] {
            MissionDetail(mission: mission, perception: perception, selection: $selection).id(id)
        } else {
            ContentUnavailableView("Sélectionnez une mission", systemImage: "sidebar.left",
                                   description: Text("Vous verrez pourquoi GHOST l'a créée, son plan et ce qui manque."))
        }
    }
}

// MARK: - Ligne

struct MissionRow: View {
    let mission: Mission
    var handledIn: String?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(mission.effectivePriority.color).frame(width: 9, height: 9).padding(.top, 5)
                .accessibilityLabel("Priorité \(mission.effectivePriority.label)")
            VStack(alignment: .leading, spacing: 3) {
                Text(mission.title).lineLimit(2)
                HStack(spacing: 6) {
                    if let handledIn { Text("Pris en charge par GHOST · \(handledIn)").foregroundStyle(.green) }
                    else { Text(mission.state.label).foregroundStyle(mission.state.color) }
                    if let d = mission.deadline { Label(d.formatted(date: .abbreviated, time: .shortened), systemImage: "clock") }
                    else if mission.deadlineConflict { Label("échéance contradictoire", systemImage: "exclamationmark.triangle") }
                    if mission.isSimulated { Text("· simulation") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Détail

struct MissionDetail: View {
    let mission: Mission
    let perception: PerceptionController
    @Binding var selection: String?
    @State private var sheet: Sheet?
    @State private var confirmCancel = false
    @State private var text = ""

    enum Sheet: Identifiable { case goal, note
        var id: Int { hashValue }
    }

    private var center: BrainCenter { perception.brain }
    private var decisions: [DecisionRecord] { center.decisions(for: mission.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let place = perception.mind.handledIn(mission.id) {
                    Label("GHOST s'en est occupé : voir « \(place) ». Les étapes ci-dessous sont le plan générique du Brain ; elles ne bloquent pas ce travail.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.green)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).ghostGlass(cornerRadius: 12)
                }
                honesty
                if mission.isOpen { actions }
                whyCreated
                goal
                if mission.deadlineConflict { conflict }
                priority
                plan
                permissions
                evidence
                history
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $sheet) { which in
            VStack(alignment: .leading, spacing: 12) {
                Text(which == .goal ? "Corriger l'objectif" : "Ajouter une précision").font(.headline)
                TextField(which == .goal ? "Résultat attendu" : "Précision", text: $text, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Annuler") { sheet = nil }
                    Button("Enregistrer") {
                        let id = mission.id, value = text, kind = which
                        sheet = nil
                        Task { await center.perform { engine in
                            if kind == .goal { try await engine.correctGoal(id, to: value) } else { try await engine.addNote(id, text: value) }
                        } }
                    }
                    .keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(width: 440)
        }
        .confirmationDialog("Annuler cette mission ?", isPresented: $confirmCancel) {
            Button("Annuler la mission", role: .destructive) {
                let id = mission.id
                Task { await center.perform { try await $0.cancel(id) } }
            }
        } message: { Text("Elle reste consultable avec tout son historique.") }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Chip(text: mission.state.label, color: mission.state.color)
                Chip(text: "Priorité \(mission.effectivePriority.label)" + (mission.userPriority != nil ? " (vous)" : ""), color: mission.effectivePriority.color)
                if mission.isSimulated { SimulationBadge() }
            }
            Text(mission.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 14) {
                if let d = mission.deadline { Label(d.formatted(date: .complete, time: .shortened), systemImage: "clock") }
                Label("Confiance \(Int(mission.confidence * 100)) %", systemImage: "gauge.medium")
                Label(mission.originSourceName, systemImage: "tray")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var honesty: some View {
        Text(UncertaintyEngineText.statement(mission))
            .font(.callout)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .ghostGlass(cornerRadius: 12)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if mission.verdict != .confirmed {
                Button("Confirmer") { run { try await $0.confirm(mission.id) } }.buttonStyle(GhostButtonStyle(prominent: true))
            }
            Button("Incorrecte") { run { try await $0.reject(mission.id, reason: "") } }.buttonStyle(GhostButtonStyle())
            Button("Corriger l'objectif") { text = mission.goal.expectedResult; sheet = .goal }.buttonStyle(GhostButtonStyle())
            Button("Préciser") { text = ""; sheet = .note }.buttonStyle(GhostButtonStyle())
            Menu("Priorité") {
                Button("Automatique") { run { try await $0.setPriority(mission.id, to: nil) } }
                ForEach(MissionPriority.allCases.reversed(), id: \.self) { level in
                    Button(level.label) { run { try await $0.setPriority(mission.id, to: level) } }
                }
            }
            .menuStyle(.button).fixedSize()
            Button("Annuler", role: .destructive) { confirmCancel = true }.buttonStyle(GhostButtonStyle(destructive: true))
        }
    }

    private var whyCreated: some View {
        Section2("Pourquoi cette mission existe") {
            if let first = decisions.last {
                ForEach(first.reasons, id: \.self) { Label($0, systemImage: "checkmark.circle") }
                if !first.uncertainties.isEmpty {
                    ForEach(first.uncertainties, id: \.self) { Label($0, systemImage: "questionmark.circle").foregroundStyle(.orange) }
                }
                DisclosureGroup("Éléments utilisés et alternatives écartées") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(first.usedElements, id: \.self) { Text("• " + $0).font(.caption) }
                        ForEach(first.alternatives, id: \.kind) { Text("✕ \($0.kind.label) : \($0.whyRejected)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 4)
                }
                Text("Décision par \(first.engine == "rules" ? "règles explicites (sans IA)" : "règles + avis du modèle \(first.modelProvider ?? "")" + (first.modelIsSimulated ? " (SIMULÉ)" : ""))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Décision d'origine indisponible.").foregroundStyle(.secondary)
            }
        }
    }

    private var goal: some View {
        Section2("Objectif") {
            Text(mission.goal.kind.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(mission.goal.expectedResult).textSelection(.enabled)
            if let project = mission.goal.projectTitle { Label("Projet : \(project)", systemImage: "folder") }
            if !mission.people.isEmpty {
                Label(mission.people.map { "\($0.name) (\($0.role))" }.joined(separator: ", "), systemImage: "person.2")
            }
            if !mission.goal.availableInfo.isEmpty {
                Text("Ce que GHOST sait").font(.subheadline.weight(.semibold))
                ForEach(mission.goal.availableInfo, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
            }
            if !mission.missingInfo.isEmpty {
                Text("Ce qui manque").font(.subheadline.weight(.semibold))
                ForEach(mission.missingInfo, id: \.self) { item in
                    Label(item.text, systemImage: item.severity == .minor ? "circle.dashed" : "exclamationmark.circle")
                        .foregroundStyle(item.severity == .minor ? Color.secondary : Color.orange).font(.callout)
                }
            }
            if let q = mission.clarificationQuestion { Label("Question à poser : \(q)", systemImage: "questionmark.bubble").font(.callout) }
            if !mission.notes.isEmpty { ForEach(mission.notes, id: \.self) { Label($0, systemImage: "note.text").font(.callout) } }
            DisclosureGroup("Ce que je sais, déduis, suppose, ignore") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mission.beliefs, id: \.subject) { b in
                        Text("**\(b.level.label)** — \(b.subject) : \(b.statement)").font(.caption)
                    }
                }.padding(.top, 4)
            }
        }
    }

    private var conflict: some View {
        Section2("Échéances contradictoires") {
            ForEach(Array(mission.deadlineClaims.filter { !$0.superseded }.enumerated()), id: \.offset) { _, claim in
                HStack {
                    VStack(alignment: .leading) {
                        Text(claim.date.formatted(date: .complete, time: .shortened))
                        Text("« \(claim.text) » · \(claim.sourceName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retenir celle-ci") { run { try await $0.resolveDeadline(mission.id, to: claim.date) } }.buttonStyle(GhostButtonStyle())
                }
            }
            Text("GHOST ne choisit pas à votre place.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var priority: some View {
        Section2("Priorité : \(mission.priority.level.label)") {
            ForEach(mission.priority.factors, id: \.name) { f in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(f.name).font(.callout.weight(.medium)); Spacer()
                        ProgressView(value: f.value).frame(width: 90) }
                    Text(f.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(mission.priority.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption) }
            Text("L'échéance ne décide pas seule : urgence, importance, conséquences et effort sont pesés.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var plan: some View {
        Section2("Plan (v\(mission.plan.revision)) — stratégie : \(mission.plan.strategy)") {
            ForEach(mission.plan.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.state.symbol).foregroundStyle(step.state.color).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.callout.weight(.medium))
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        if let reason = step.blockedReason { Text("Bloquée : \(reason)").font(.caption).foregroundStyle(.orange) }
                        Text("Vérification : \(step.verification)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text(step.state.label).font(.caption).foregroundStyle(step.state.color)
                }
            }
            if !mission.successConditions.isEmpty {
                Text("Conditions de réussite").font(.subheadline.weight(.semibold))
                ForEach(mission.successConditions, id: \.self) { Text("• " + $0).font(.caption) }
            }
            if !mission.risks.isEmpty {
                Text("Risques").font(.subheadline.weight(.semibold))
                ForEach(mission.risks, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var permissions: some View {
        Section2("Autorisations nécessaires") {
            ForEach(Array(mission.permissions.enumerated()), id: \.offset) { _, need in
                HStack(alignment: .top) {
                    Image(systemName: need.status == .granted ? "checkmark.shield" : need.status == .missing ? "xmark.shield" : "hand.raised")
                        .foregroundStyle(need.status == .granted ? .green : need.status == .missing ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(need.capability.label) — \(need.resource)").font(.callout)
                        Text(need.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("« Prête » ne suffit pas : autorisez séparément la lecture du contenu et le dossier de sortie dans Activité.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var evidence: some View {
        Section2("Preuves (événements déclencheurs)") {
            ForEach(Array(mission.triggers.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.summary).font(.callout)
                    Text("\(t.sourceName) · \(t.occurredAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var history: some View {
        Section2("Historique") {
            ForEach(mission.history.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.summary).font(.callout)
                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened))\(entry.byUser ? " · vous" : "")" +
                         (entry.before != nil && entry.after != nil ? " · \(entry.before!) → \(entry.after!)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run(_ action: @escaping @Sendable (BrainEngine) async throws -> Void) {
        Task { await center.perform(action) }
    }
}

// MARK: - Réglages du cerveau

struct BrainSettingsSheet: View {
    let perception: PerceptionController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var calls = 0

    var body: some View {
        Form {
            Section("Modèle externe (facultatif)") {
                Text("Par défaut, GHOST décide avec des règles locales, sans IA et sans réseau. Vous pouvez autoriser l'envoi d'un résumé **masqué** (noms, e-mails, numéros et liens retirés) à Anthropic, uniquement pour trancher les cas ambigus. Le modèle ne peut ni créer de mission à partir d'un message informatif, ni toucher aux permissions.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("Clé API Anthropic", text: $key, prompt: Text(perception.hasModelKey ? "Clé enregistrée dans le Trousseau" : "sk-ant-…"))
                HStack {
                    Button("Enregistrer la clé") { perception.saveModelKey(key); key = "" }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if perception.hasModelKey { Button("Supprimer la clé", role: .destructive) { Task { await perception.removeModelKey() } } }
                }
                Toggle("Autoriser l'envoi de données masquées à Anthropic", isOn: Binding(
                    get: { perception.externalModelEnabled },
                    set: { value in Task { await perception.setExternalModel(enabled: value) } }))
                    .disabled(!perception.hasModelKey)
                LabeledContent("Appels journalisés", value: "\(calls)")
                Text("Le journal est technique (fournisseur, durée, jetons) et ne contient jamais le contenu des messages. Limites : 200 appels et 200 000 jetons par jour.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = perception.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            HStack { Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped).frame(width: 520)
        .task { calls = await perception.modelCallCount() }
    }
}

// MARK: - Aides d'affichage

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

enum UncertaintyEngineText {
    static func statement(_ m: Mission) -> String {
        let blockers = m.missingInfo.filter { $0.severity != .minor }.map { $0.text.prefix(1).lowercased() + $0.text.dropFirst() }
        if m.deadlineConflict { return "Je pense qu'une mission existe, mais deux sources donnent des échéances différentes : je ne choisis pas à votre place." }
        if m.state.isTerminal { return "Mission \(m.state.label.lowercased()). L'historique reste consultable." }
        if blockers.isEmpty { return "Je pense qu'une mission existe et je dispose des éléments pour la planifier (confiance \(Int(m.confidence * 100)) %)." }
        return "Je pense qu'une mission existe, mais il me manque : " + blockers.joined(separator: " ; ") + "."
    }
}

extension MissionPriority {
    var color: Color {
        switch self { case .critical: return .red; case .high: return .orange; case .normal: return GhostTheme.accent; case .low: return .gray }
    }
}
extension MissionState {
    var color: Color {
        switch self {
        case .needsClarification: return .orange; case .blocked: return .red; case .proposed: return GhostTheme.accent
        case .ready, .inProgress: return .green; case .completed: return .green; case .cancelled, .failed: return .gray
        case .detected, .analyzing: return .secondary
        }
    }
}
extension StepState {
    var color: Color {
        switch self {
        case .completed: return .green; case .ready: return GhostTheme.accent; case .blocked: return .orange
        case .failed: return .red; case .cancelled: return .gray; case .pending: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"; case .ready: return "circle.lefthalf.filled"; case .blocked: return "exclamationmark.circle"
        case .failed: return "xmark.circle"; case .cancelled: return "slash.circle"; case .pending: return "circle.dashed"
        }
    }
}
