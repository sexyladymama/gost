import SwiftUI
import GhostMind

/// Ce que GHOST a créé à la demande (logos, documents), rangé dans le dossier choisi par l'utilisateur.
struct CreationsView: View {
    let perception: PerceptionController
    private var center: MindCenter { perception.mind }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = center.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(10) }
            folderBanner
            if center.creations.isEmpty {
                ContentUnavailableView("Aucune création", systemImage: "wand.and.stars",
                                       description: Text("Quand un message vous demande de créer quelque chose (« crée un logo », « rédige une lettre »), GHOST le fait et range le fichier dans votre dossier de création."))
            } else {
                ScrollView { VStack(spacing: 14) { ForEach(center.creations) { CreationCard(creation: $0, perception: perception) } }.padding(14) }
            }
        }
        .task { await center.reload() }
    }

    private var folderBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: perception.outputFolderName == nil ? "folder.badge.questionmark" : "folder").foregroundStyle(perception.outputFolderName == nil ? .orange : .green)
            Text(perception.outputFolderName.map { "GHOST range ses créations dans « \($0) » et n'écrase jamais un fichier." }
                 ?? "Choisissez le dossier où GHOST range ce qu'il crée.").font(.callout)
            Spacer()
            Button(perception.outputFolderName == nil ? "Choisir un dossier…" : "Changer…") { Task { await perception.chooseOutputFolder() } }
                .buttonStyle(GhostButtonStyle(prominent: perception.outputFolderName == nil))
        }
        .padding(12)
    }
}

private struct CreationCard: View {
    let creation: Creation
    let perception: PerceptionController

    private var status: (String, Color) {
        switch creation.status {
        case .done: return ("Créé", .green); case .needsModel: return ("Modèle requis", .orange)
        case .needsFolder: return ("Dossier requis", .orange); case .failed: return ("Échec", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: creation.kind == .logo ? "paintbrush.pointed" : "doc.text")
                Text(creation.title).font(.headline)
                if creation.version > 1 { Text("· version \(creation.version)").foregroundStyle(.secondary) }
                Spacer()
                Chip(text: status.0, color: status.1)
            }
            Text("D'après : « \(creation.basis) »" + (creation.generatedBy.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let note = creation.note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.orange) }
            if creation.kind == .logo, let png = creation.paths.first(where: { $0.hasSuffix(".png") }), let image = NSImage(contentsOfFile: png) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            ForEach(creation.paths, id: \.self) { Text(($0 as NSString).lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary) }
            HStack {
                if !creation.paths.isEmpty {
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(creation.paths.map { URL(fileURLWithPath: $0) })
                    }.buttonStyle(GhostButtonStyle(prominent: creation.status == .done))
                }
                Button("Refaire") { run { try await $0.redoCreation(creation.id) } }.buttonStyle(GhostButtonStyle())
                Button("Fermer") { run { try await $0.hideCreation(creation.id) } }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14)
        .ghostGlass(cornerRadius: 14)
    }
    private func run(_ action: @escaping @Sendable (MindEngine) async throws -> Void) { Task { await perception.mind.perform(action) } }
}
