import SwiftUI
import GhostKit
import GhostBrain
import GhostContext
import GhostCore

/// Objectifs en langage naturel : GHOST comprend, planifie, choisit ses outils, vous demande votre accord pour ce qui engage, et vérifie.
struct ObjectivesView: View {
    let perception: PerceptionController
    private var center: CoreCenter { perception.core }
    @State private var text = ""
    @State private var scope: ContextScope = .professional

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                aiStatus
                VStack(alignment: .leading, spacing: 8) {
                    Text("Que doit faire GHOST ?").font(.headline)
                    TextField("Ex. : prépare un briefing pour ma réunion de demain avec l'Atelier Lune", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5)
                    HStack {
                        Picker("Contexte", selection: $scope) { Text("Professionnel").tag(ContextScope.professional); Text("Personnel").tag(ContextScope.personal) }
                            .pickerStyle(.segmented).frame(maxWidth: 260)
                        Spacer()
                        Button("Confier à GHOST") {
                            let objective = text, chosen = scope; text = ""
                            Task { await center.perform { _ = try await $0.submit(objective: objective, scope: chosen, privacy: perception.corePrivacy) } }
                        }
                        .buttonStyle(GhostButtonStyle()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    }
                }
                .padding(14).ghostGlass(cornerRadius: 14)
                if let error = center.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                if center.sessions.isEmpty {
                    ContentUnavailableView("Aucun objectif", systemImage: "target",
                                           description: Text("Décrivez un objectif : GHOST choisit lui-même les étapes et les outils, et vous demande votre accord avant tout ce qui engage."))
                }
                ForEach(center.sessions) { SessionCard(session: $0, perception: perception) }
            }
            .padding(14)
        }
        .task { await center.reload(); await perception.refreshAIStatus() }
    }

    private var aiStatus: some View {
        @Bindable var perception = perception
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(perception.aiStatus, id: \.self) { Label($0, systemImage: "cpu").font(.caption).foregroundStyle(.secondary) }
            Picker("Modèle utilisé pour les objectifs", selection: $perception.corePrivacy) {
                Text("Local uniquement").tag(ModelPrivacy.localOnly)
                Text("Local, puis externe").tag(ModelPrivacy.externalAllowed)
                Text("Externe uniquement").tag(ModelPrivacy.externalOnly)
            }
            .pickerStyle(.segmented)
            if perception.corePrivacy != .localOnly && !perception.externalModelEnabled {
                Label("Le modèle externe n'est pas activé : enregistrez une clé et activez-le dans Confidentialité. Sans cela, aucun objectif ne peut utiliser un modèle externe.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Tester le modèle local") { Task { await perception.testModelConnection(external: false) } }.buttonStyle(GhostButtonStyle())
                Button("Tester le modèle externe") { Task { await perception.testModelConnection(external: true) } }.buttonStyle(GhostButtonStyle())
                    .disabled(!perception.externalModelEnabled)
                if let result = perception.connectionTest { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
            Text(perception.corePrivacy == .localOnly ? "Les objectifs restent sur ce Mac." : "Avec un modèle externe, l'objectif, les extraits de mémoire pertinents et les résultats d'outils sont envoyés ; les adresses e-mail sont masquées avant l'envoi.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

private struct SessionCard: View {
    let session: AgentSession
    let perception: PerceptionController
    @State private var reply = ""

    private var color: Color {
        switch session.phase {
        case .running, .pending: return .blue; case .review: return .green; case .approval, .clarification: return .orange
        case .blocked, .cancelled: return .red; case .paused: return .gray
        }
    }
    private func run(_ action: @escaping @Sendable (CoreCoordinator) async throws -> Void) { Task { await perception.core.perform(action) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(session.objective).font(.headline).lineLimit(3)
                Spacer()
                Chip(text: session.phase.label, color: color)
            }
            if let model = session.model {
                Text("Modèle : \(session.provider ?? "?") / \(model)" + (session.isSimulated ? " — SIMULÉ" : "") + " · \(session.iterations) étape(s) · \(session.toolCalls) outil(s)")
                    .font(.caption).foregroundStyle(session.isSimulated ? .orange : .secondary)
            }
            if !session.plan.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(session.plan.enumerated()), id: \.offset) { Text("\($0.offset + 1). \($0.element.title)").font(.caption) }
                }
            }
            ForEach(session.receipts) { r in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: r.status == "ok" || r.status == "proposed" ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(r.status == "ok" || r.status == "proposed" ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(r.call.tool.rawValue) — \(r.call.reason)").font(.caption.weight(.medium))
                        Text(r.content.prefix(220)).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            if let error = session.error { Label(error, systemImage: "info.circle").font(.callout).foregroundStyle(.orange) }

            switch session.phase {
            case .clarification:
                Text(session.clarification ?? "").font(.callout)
                HStack {
                    TextField("Votre réponse", text: $reply).textFieldStyle(.roundedBorder)
                    Button("Répondre") { let r = reply; reply = ""; run { try await $0.answer(session.id, text: r) } }.buttonStyle(GhostButtonStyle()).disabled(reply.isEmpty)
                }
            case .approval:
                if let approval = session.approval {
                    Text("GHOST demande votre accord pour cette action exacte :").font(.callout.weight(.semibold))
                    Text(approval.preview).font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading).ghostGlass(cornerRadius: 10)
                    HStack {
                        Button("Approuver et exécuter") { run { try await $0.approve(session.id, digest: approval.digest) } }.buttonStyle(GhostButtonStyle())
                        Button("Refuser") { run { try await $0.reject(session.id) } }.buttonStyle(GhostButtonStyle())
                    }
                }
            case .review:
                if let answer = session.answer { Text(answer).font(.callout).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).ghostGlass(cornerRadius: 10) }
                ForEach(session.receipts.compactMap(\.artifact), id: \.fileName) { Label("\($0.fileName)\($0.verified ? " — vérifié" : "")", systemImage: "doc.text").font(.caption) }
                Button("Je l'ai relu : terminer la mission") { run { try await $0.acceptResult(session.id) } }.buttonStyle(GhostButtonStyle())
            case .paused:
                Button("Reprendre") { run { try await $0.resume(session.id) } }.buttonStyle(GhostButtonStyle())
            default: EmptyView()
            }
            ForEach(session.evidence.filter { $0.kind == "preference_proposal" }) { proposal in
                HStack {
                    Text("GHOST propose de retenir : « \(proposal.text) »").font(.caption)
                    Spacer()
                    Button("Retenir") { run { try await $0.confirmPreference(session.id, evidenceID: proposal.id) } }.buttonStyle(GhostButtonStyle())
                    Button("Ignorer") { run { try await $0.rejectPreference(session.id, evidenceID: proposal.id) } }.buttonStyle(GhostButtonStyle())
                }
            }
            if [.running, .clarification, .approval, .blocked, .paused].contains(session.phase) {
                Button("Annuler") { run { await $0.cancel(session.id) } }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14).ghostGlass(cornerRadius: 14)
    }
}
