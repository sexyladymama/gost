import Foundation
import CryptoKit

/// L'IA embarquée de GHOST : Qwen 2.5 7B Instruct (Alibaba Cloud, licence Apache-2.0), quantifiée Q4_K_M, au format GGUF.
/// Les fichiers sont épinglés par révision, taille et SHA-256 : un fichier modifié ou incomplet n'est jamais chargé.
public struct LocalModelFile: Sendable { public var name: String; public var size: Int64; public var sha256: String }

public enum LocalModelError: Error, LocalizedError, Sendable {
    case badStatus(Int), sizeMismatch(String), hashMismatch(String), storage(String)
    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Le serveur de téléchargement a répondu \(code)."
        case .sizeMismatch(let n): return "Fichier incomplet : \(n)."
        case .hashMismatch(let n): return "Empreinte inattendue pour \(n) : fichier supprimé, rien n'est chargé."
        case .storage(let s): return s
        }
    }
}

public final class LocalModelStore: @unchecked Sendable {
    public static let modelID = "qwen2.5-7b-instruct-q4_k_m"
    public static let repository = "Qwen/Qwen2.5-7B-Instruct-GGUF"
    public static let revision = "bb5d59e06d9551d752d08b292a50eb208b07ab1f"
    public static let files = [
        LocalModelFile(name: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf", size: 3_993_201_344, sha256: "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db"),
        LocalModelFile(name: "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf", size: 689_872_288, sha256: "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a")
    ]
    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public let directory: URL
    private let files: [LocalModelFile]
    private let session: URLSession
    private let baseURL: URL

    /// `baseDirectory` : dossier « GHOST » du profil. Les paramètres facultatifs servent aux tests (faux fichiers, faux serveur).
    public init(baseDirectory: URL, files: [LocalModelFile] = LocalModelStore.files, baseURL: URL = URL(string: "https://huggingface.co/\(LocalModelStore.repository)/resolve/\(LocalModelStore.revision)/")!,
                session: URLSession = .shared) {
        directory = baseDirectory.appendingPathComponent("models", isDirectory: true).appendingPathComponent(Self.modelID, isDirectory: true)
        self.files = files; self.baseURL = baseURL; self.session = session
    }

    private var marker: URL { directory.appendingPathComponent(".verified") }
    /// Premier fragment : llama.cpp charge les fragments suivants tout seul.
    public var modelPath: String { directory.appendingPathComponent(files[0].name).path }

    /// Installé = tous les fichiers à la taille exacte ET vérifiés (SHA-256) au moins une fois.
    public var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        return files.allSatisfy { size(of: $0.name) == $0.size }
    }
    public var installedBytes: Int64 { files.reduce(0) { $0 + (size(of: $1.name) ?? 0) } }

    private func size(of name: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
    }

    /// Calcule le SHA-256 de chaque fichier ; un fichier de taille ou d'empreinte inattendue est supprimé.
    public func verify() throws {
        try? FileManager.default.removeItem(at: marker)
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            guard size(of: file.name) == file.size else { throw LocalModelError.sizeMismatch(file.name) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else { try? FileManager.default.removeItem(at: url); throw LocalModelError.hashMismatch(file.name) }
        }
        try Data("ok".utf8).write(to: marker)
    }

    /// Téléchargement REPRENABLE (en-tête Range) dans un fichier `.part`, puis vérification. `progress` : 0…1 sur l'ensemble.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = Double(files.reduce(0) { $0 + $1.size })
        var done = 0.0
        for file in files {
            let final = directory.appendingPathComponent(file.name), part = directory.appendingPathComponent(file.name + ".part")
            if size(of: file.name) == file.size { done += Double(file.size); progress(done / total); continue }
            var have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
            if have > file.size { try? FileManager.default.removeItem(at: part); have = 0 }
            if have < file.size {
                var request = URLRequest(url: baseURL.appendingPathComponent(file.name))
                if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
                let (bytes, response) = try await session.bytes(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 || code == 206 else { throw LocalModelError.badStatus(code) }
                if code == 200 && have > 0 { try? FileManager.default.removeItem(at: part); have = 0 }   // le serveur ignore Range : on repart de zéro
                if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: part)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var buffer = Data(); buffer.reserveCapacity(1 << 20)
                var received = have
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 1 << 20 {
                        try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                        progress((done + Double(received)) / total)
                    }
                    try Task.checkCancellation()
                }
                try handle.write(contentsOf: buffer); received += Int64(buffer.count)
            }
            guard size(of: file.name + ".part") == file.size else { throw LocalModelError.sizeMismatch(file.name) }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            done += Double(file.size); progress(done / total)
        }
        try verify()
    }

    public func remove() { try? FileManager.default.removeItem(at: directory) }
}
