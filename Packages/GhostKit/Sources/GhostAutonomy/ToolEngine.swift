import Foundation

public struct ToolResult: Sendable {
    public var files: [String] = []
    public var inputs: [InputReceipt] = []
    public var records: [SalesRecord] = []
    public var data: Data?
    public var artifact: ArtifactReceipt?
    public var verification: VerificationReport?
    public var notification: String?
}

/// Catalogue fermé : aucun nom d'outil, script ou commande arbitraire n'est évalué.
public actor ToolEngine {
    private let trust: ExecutionTrust
    public init(trust: ExecutionTrust) { self.trust = trust }
    public func execute(_ tool: ToolID, context: ExecutionContext, text: String? = nil) async throws -> ToolResult {
        guard tool == .createDocument || text == nil else { throw ExecutionError.invalid("Argument supplémentaire interdit par le schéma de l'outil.") }
        return try await trust.perform(context.id, namespace: context.mission.namespace,
                                       risk: context.declaredSensitive ? .sensitive : .low) { grant in
            var result = ToolResult()
            switch tool {
            case .listAuthorizedFiles:
                result.files = try SecureFiles.list(grant)
                guard !result.files.isEmpty else { throw ExecutionError.approval("Aucun CSV/TSV commercial dans le dossier autorisé.") }
            case .readAuthorizedFile:
                guard context.inputNames.count <= 100 else { throw ExecutionError.invalid("Trop de sources.") }
                var total = 0
                for name in context.inputNames {
                    let data = try SecureFiles.read(name, grant: grant); total += data.count
                    guard total <= SecureFiles.maxBytes, let text = String(data: data, encoding: .utf8) else { throw ExecutionError.invalid("Sources trop volumineuses ou non UTF-8.") }
                    result.inputs.append(InputReceipt(name: name, hash: ExecutionIdentity.hash(data), text: text))
                }
            case .createDocument:
                guard let text, !text.isEmpty, text.utf8.count <= SecureFiles.maxBytes else { throw ExecutionError.invalid("Texte UTF-8 non vide et borné requis.") }
                result.data = Data(text.utf8)
            case .createSpreadsheet:
                for input in context.inputs { result.records += try SalesParser.parse(input.text, source: input.name) }
                result.data = try SpreadsheetEngine.create(records: result.records)
            case .saveArtifact:
                guard let bytes = context.stagedArtifact else { throw ExecutionError.invalid("Aucun artefact préparé.") }
                result.artifact = try SecureFiles.save(bytes, name: context.outputName, grant: grant)
            case .verifyArtifact:
                guard let artifact = context.artifact, artifact.fileName == context.outputName else { throw ExecutionError.invalid("Emplacement du résultat non conforme.") }
                let bytes = try SecureFiles.read(artifact.fileName, grant: grant, output: true)
                result.verification = SpreadsheetEngine.verify(bytes, expected: context.records, expectedHash: artifact.hash)
            case .notifyUser:
                guard context.verification?.status == .passed, let artifact = context.artifact else { throw ExecutionError.invalid("Notification de réussite interdite sans vérification passée.") }
                result.notification = "Fichier Excel local terminé et vérifié : \(artifact.fileName). Aucun envoi externe effectué."
            }
            return result
        }
    }
    /// Avant reprise, les sources sauvegardées doivent toujours être identiques.
    public func validateInputs(_ context: ExecutionContext) async throws {
        try await trust.perform(context.id, namespace: context.mission.namespace) { grant in
            for input in context.inputs {
                let bytes = try SecureFiles.read(input.name, grant: grant)
                guard ExecutionIdentity.hash(bytes) == input.hash else { throw ExecutionError.approval("Une source a changé depuis le checkpoint. Préparez une nouvelle exécution ; les anciennes données ne seront pas utilisées silencieusement.") }
            }
        }
    }
}
