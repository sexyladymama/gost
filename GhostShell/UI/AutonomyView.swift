import SwiftUI
import AppKit
import GhostAutonomy
import GhostBrain

struct AutonomyView: View {
    let perception: PerceptionController
    @State private var selectedMission = ""
    @State private var selectedExecution: String?
    @State private var sensitive = false
    private var center: ExecutionCenter { perception.execution }
    private var eligible: [Mission] {
        perception.brain.missions.filter { $0.state == .ready && $0.verdict == .confirmed && $0.workKind == .produce && $0.goal.deliverable == "Fichier Excel" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exécution locale").font(.title2.weight(.semibold))
            Text("CSV/TSV commerciaux → Excel vérifié. Les colonnes attendues sont produit,quantite,prix_unitaire. Aucun envoi externe ni remplacement de fichier.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = center.error ?? perception.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if eligible.isEmpty {
                Text("Confirmez d'abord une mission Excel prête dans Missions. Le Brain doit connaître les données sources ; l'accès au contenu sera autorisé séparément ici.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Mission", selection: $selectedMission) {
                        Text("Choisir…").tag("")
                        ForEach(eligible) { Text($0.title).tag($0.id) }
                    }
                    Button("Autoriser les dossiers et exécuter") {
                        Task { await perception.prepareExecution(selectedMission, sensitive: sensitive) }
                    }.disabled(selectedMission.isEmpty)
                }
                Toggle("Ces données sont sensibles : demander une validation supplémentaire", isOn: $sensitive).font(.caption)
            }
            Divider()
            HSplitView {
                List(center.executions, selection: $selectedExecution) { execution in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(execution.mission.title).lineLimit(2)
                        Text(execution.state.label).font(.caption).foregroundStyle(execution.state == .completed ? .green : .secondary)
                        ProgressView(value: execution.progress)
                    }.padding(.vertical, 4).tag(execution.id)
                }.frame(minWidth: 260, idealWidth: 300)
                ScrollView {
                    if let id = selectedExecution, let execution = center.archive.executions[id] {
                        detail(execution).padding(16)
                    } else {
                        ContentUnavailableView("Sélectionnez une exécution", systemImage: "play.circle",
                                               description: Text("Permissions, étapes, vérifications et historique restent consultables après fermeture."))
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(16)
        .task { await center.reload() }
    }
    @ViewBuilder private func detail(_ execution: ExecutionContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(execution.mission.goal.expectedResult).font(.headline).textSelection(.enabled)
            Text(execution.state.label).font(.subheadline.weight(.semibold))
            Text("Périmètre : préparation locale seulement. La validation du destinataire et la remise externe du plan initial restent à réaliser.")
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: execution.progress)
            if let notification = execution.notification { Label(notification, systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            if let error = execution.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            controls(execution)
            if execution.state == .waitingForApproval {
                Text(execution.approval ?? "Autorisation requise.").font(.callout)
                HStack {
                    if ["sensitive", "collision"].contains(execution.approvalKind ?? "") {
                        Button(execution.approvalKind == "collision" ? "Approuver une nouvelle version" : "Approuver les données sensibles") {
                            run { engine in try await engine.approve(execution.id); try await engine.start(execution.id) }
                        }
                    }
                    Button("Refuser", role: .destructive) { run { try await $0.deny(execution.id) } }
                }
            }
            Group {
                Text("Sources : " + (execution.inputPath ?? "Non autorisées"))
                Text("Sortie : " + (execution.outputPath ?? "Non autorisée"))
            }.font(.caption).textSelection(.enabled)
            ForEach(execution.operations) { operation in
                VStack(alignment: .leading, spacing: 2) {
                    Label(operation.tool.rawValue, systemImage: operation.status == "completed" ? "checkmark.circle.fill" : "circle.dashed")
                    Text("\(operation.status) · tentatives : \(operation.attempts)/3").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let report = execution.verification {
                Divider(); Text("Vérification : \(report.status.rawValue)").font(.headline)
                ForEach(report.checks, id: \.self) { Label($0, systemImage: "checkmark").font(.caption) }
                ForEach(report.problems, id: \.self) { Label($0, systemImage: "xmark").font(.caption).foregroundStyle(.red) }
            }
            if execution.verification?.status == .passed, let artifact = execution.artifact, let folder = execution.outputPath {
                Button("Afficher le résultat dans Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder).appendingPathComponent(artifact.fileName)])
                }
                Text(artifact.fileName).font(.caption).textSelection(.enabled)
            }
            DisclosureGroup("Historique des opérations") {
                ForEach(execution.history.reversed()) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.message).font(.caption)
                        Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func controls(_ execution: ExecutionContext) -> some View {
        HStack {
            if [.running, .verifying, .authorized].contains(execution.state) {
                Button("Pause") { run { try await $0.pause(execution.id) } }
            }
            if [.paused, .failed, .pending].contains(execution.state) || execution.approvalKind == "permissions" {
                Button("Autoriser les dossiers et reprendre") { Task { await perception.resumeExecution(execution.id) } }
            }
            if !execution.state.isTerminal {
                Button("Annuler", role: .destructive) { run { try await $0.cancel(execution.id) } }
                Button("Révoquer les dossiers") { Task { await perception.revokeExecution(execution.id) } }
            }
        }
    }
    private func run(_ action: @escaping @Sendable (ExecutionEngine) async throws -> Void) { Task { await center.perform(action) } }
}
