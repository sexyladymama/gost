import Foundation
import CSQLite

/// Connexion exclusivement détenue par ContextEngine. Aucun fichier défectueux n'est réinitialisé.
final class ContextDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL?, profileID: String) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ContextError.storage("Impossible d'ouvrir la base. Aucun fichier existant n'a été effacé.")
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA secure_delete=ON")
            let version = try scalar("PRAGMA user_version")
            guard version == nil || version == "0" || version == "1" else {
                throw ContextError.storage("Version de mémoire plus récente ; ouverture refusée pour préserver les données.")
            }
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
            if let owner = try scalar("SELECT CAST(value AS TEXT) FROM metadata WHERE key='owner'"), owner != profileID {
                throw ContextError.storage("Cette base appartient à un autre profil.")
            }
            if try scalar("SELECT key FROM metadata WHERE key='owner'") == nil {
                try execute("INSERT INTO metadata(key,value) VALUES('owner',?)", values: [Data(profileID.utf8)])
            }
            try execute("CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, kind TEXT NOT NULL, scope TEXT NOT NULL, domain TEXT NOT NULL, search_text TEXT NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS relations (id TEXT PRIMARY KEY, from_id TEXT NOT NULL REFERENCES nodes(id), to_id TEXT NOT NULL REFERENCES nodes(id), payload BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS nodes_domain_scope ON nodes(domain,scope)")
            try execute("CREATE INDEX IF NOT EXISTS relations_from ON relations(from_id)")
            try execute("CREATE INDEX IF NOT EXISTS relations_to ON relations(to_id)")
            try execute("PRAGMA user_version=1")
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }
    deinit { sqlite3_close(handle) }

    func load() throws -> ContextSnapshot {
        var snapshot: ContextSnapshot
        if let data = try blobs("SELECT value FROM metadata WHERE key='state'").first {
            do { snapshot = try decoder.decode(ContextSnapshot.self, from: data) }
            catch { throw ContextError.storage("Paramètres de mémoire illisibles ; données conservées.") }
        } else { snapshot = ContextSnapshot() }
        do {
            for data in try blobs("SELECT payload FROM nodes") {
                let node = try decoder.decode(ContextNode.self, from: data); snapshot.nodes[node.id] = node
            }
            for data in try blobs("SELECT payload FROM relations") {
                let edge = try decoder.decode(ContextRelation.self, from: data)
                guard snapshot.nodes[edge.from] != nil, snapshot.nodes[edge.to] != nil else {
                    throw ContextError.storage("Relation sans entité ; données conservées.")
                }
                snapshot.relations[edge.id] = edge
            }
        } catch { throw ContextError.storage("Graphe illisible ; aucune reconstruction destructive n'a été effectuée.") }
        return snapshot
    }

    func save(_ snapshot: ContextSnapshot) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM relations")
            try execute("DELETE FROM nodes")
            for node in snapshot.nodes.values {
                let search = ContextText.normalized(node.title + " " + node.properties.values.joined(separator: " "))
                try execute("INSERT INTO nodes VALUES(?,?,?,?,?,?)", values: [node.id, node.kind.rawValue, node.scope.rawValue, node.domain.rawValue, search].map { Data($0.utf8) } + [try encoder.encode(node)])
            }
            for edge in snapshot.relations.values {
                try execute("INSERT INTO relations VALUES(?,?,?,?)", values: [edge.id, edge.from, edge.to].map { Data($0.utf8) } + [try encoder.encode(edge)])
            }
            var state = snapshot; state.nodes = [:]; state.relations = [:]
            try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('state',?)", values: [try encoder.encode(state)])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func search(_ query: String, domain: MemoryDomain?, scope: ContextScope?) throws -> [String] {
        let tokens = ContextText.normalized(query).split(separator: " ").prefix(12)
        var sql = "SELECT CAST(id AS BLOB) FROM nodes WHERE 1=1"
        var values: [Data] = []
        if let domain { sql += " AND domain=?"; values.append(Data(domain.rawValue.utf8)) }
        if let scope { sql += " AND scope=?"; values.append(Data(scope.rawValue.utf8)) }
        for token in tokens { sql += " AND search_text LIKE ?"; values.append(Data(("%" + token + "%").utf8)) }
        sql += " ORDER BY search_text, id LIMIT 200"
        return try blobs(sql, values: values).compactMap { String(data: $0, encoding: .utf8) }
    }

    private func prepare(_ sql: String, values: [Data]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index, value) in values.enumerated() {
            // Les paramètres textuels sont comparés en TEXT, les payloads JSON sont aussi des chaînes UTF-8.
            let result = value.withUnsafeBytes { bytes in
                sqlite3_bind_text(statement, Int32(index + 1), bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(value.count), transient)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    private func execute(_ sql: String, values: [Data] = []) throws {
        let statement = try prepare(sql, values: values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func blobs(_ sql: String, values: [Data] = []) throws -> [Data] {
        let statement = try prepare(sql, values: values); defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            if let bytes = sqlite3_column_blob(statement, 0) { result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) }
        }
    }
    private func scalar(_ sql: String) throws -> String? { try blobs(sql).first.flatMap { String(data: $0, encoding: .utf8) } }
    private func failure() -> ContextError {
        ContextError.storage(handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Échec SQLite")
    }
}
