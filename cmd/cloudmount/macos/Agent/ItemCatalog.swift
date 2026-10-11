import CryptoKit
import Foundation
import SQLite3

enum ItemCatalogError: LocalizedError {
    case noSuchItem, invalidListing, invalidMove, database, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .noSuchItem: return "item not found"
        case .invalidListing: return "invalid directory listing"
        case .invalidMove: return "invalid catalog move"
        case .database: return "CloudMount item catalog unavailable"
        case .unsupportedVersion: return "unsupported CloudMount item catalog version"
        }
    }
}

/// ItemCatalog owns domain-scoped identities and private backend-relative paths.
final class ItemCatalog {
    struct Record {
        let identifier: String
        let parentIdentifier: String
        let path: String
        let metadata: CloudMountItemMetadata
        let backendID: String?
    }

    private var database: OpaquePointer?
    private let lock = NSLock()
    private static let columns = "identifier,parent,path,filename,is_directory,size,mtime,backend_id,content_version,metadata_version"

    init(fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let type = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw ItemCatalogError.database }
        }
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw ItemCatalogError.database
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            sqlite3_busy_timeout(database, 5000)
            _ = try query("PRAGMA foreign_keys=ON")
            guard try query("PRAGMA quick_check").first?.first == "ok" else { throw ItemCatalogError.database }
            try transaction {
                guard let version = try query("PRAGMA user_version").first?.first.flatMap({ $0 }).flatMap(Int.init) else { throw ItemCatalogError.database }
                switch version {
                case 0:
                    // Never adopt an unversioned nonempty database as a new catalog.
                    guard try query("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw ItemCatalogError.database }
                    _ = try query("CREATE TABLE domains (domain TEXT PRIMARY KEY NOT NULL, binding TEXT NOT NULL)")
                    _ = try query("""
                        CREATE TABLE items (
                            domain TEXT NOT NULL, identifier TEXT NOT NULL, parent TEXT,
                            path TEXT NOT NULL CHECK(length(path)>0), filename TEXT NOT NULL,
                            is_directory INTEGER NOT NULL CHECK(is_directory IN (0,1)),
                            size INTEGER, mtime TEXT, backend_id TEXT,
                            content_version TEXT NOT NULL, metadata_version TEXT NOT NULL,
                            created REAL NOT NULL, last_seen REAL NOT NULL,
                            PRIMARY KEY(domain,identifier), UNIQUE(domain,path),
                            FOREIGN KEY(domain) REFERENCES domains(domain) ON DELETE CASCADE,
                            FOREIGN KEY(domain,parent) REFERENCES items(domain,identifier) ON DELETE CASCADE)
                        """)
                    _ = try query("CREATE INDEX items_parent ON items(domain,parent)")
                    _ = try query("PRAGMA user_version=1")
                case 1: break
                default: throw ItemCatalogError.unsupportedVersion
                }
                // Prepare all persisted fields and validate referential integrity before serving DATA.
                _ = try query("SELECT domain,binding FROM domains LIMIT 0")
                _ = try query("SELECT domain,\(Self.columns),created,last_seen FROM items LIMIT 0")
                let indexes = try query("PRAGMA index_list(items)")
                var uniqueColumns = Set<String>()
                for index in indexes where index[2] == "1" {
                    guard let name = index[1] else { throw ItemCatalogError.database }
                    let columns = try query("SELECT name FROM pragma_index_info(?) ORDER BY seqno", [name]).compactMap { $0[0] }.joined(separator: ",")
                    uniqueColumns.insert(columns)
                }
                let foreignKeys = try query("PRAGMA foreign_key_list(items)")
                let cascades = Set(foreignKeys.filter { $0[6] == "CASCADE" }.map { "\($0[3] ?? "")->\($0[2] ?? "").\($0[4] ?? "")" })
                guard uniqueColumns.contains("domain,identifier"), uniqueColumns.contains("domain,path"),
                      cascades == ["domain->domains.domain", "domain->items.domain", "parent->items.identifier"] else { throw ItemCatalogError.database }
                guard try query("PRAGMA foreign_key_check").isEmpty else { throw ItemCatalogError.database }
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    static func applicationSupportCatalog() throws -> ItemCatalog {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try ItemCatalog(fileURL: support.appendingPathComponent("Rclone CloudMount/catalog.sqlite3"))
    }

    /// bind retires all old identities if the configured selector changes.
    @discardableResult
    func bind(domain: String, remote: String) throws -> Bool {
        guard !domain.isEmpty, !remote.isEmpty else { throw ItemCatalogError.database }
        let binding = Self.digest([remote])
        return try locked { try transaction {
            let existing = try query("SELECT binding FROM domains WHERE domain=?", [domain]).first?.first
            if existing == binding { return false }
            _ = try query("DELETE FROM domains WHERE domain=?", [domain])
            _ = try query("INSERT INTO domains(domain,binding) VALUES (?,?)", [domain, binding])
            return true
        } }
    }

    func purge(domain: String) throws {
        try locked { _ = try query("DELETE FROM domains WHERE domain=?", [domain]) }
    }

    func resolve(domain: String, identifier: String) throws -> Record {
        try locked { try resolveUnlocked(domain: domain, identifier: identifier) }
    }

    /// reconcile commits a complete immediate-child listing, retiring absent subtrees.
    func reconcile(domain: String, parentIdentifier: String, entries: [CloudMountMetadata]) throws -> [CloudMountItemMetadata] {
        try locked { try transaction {
            let parentPath = try directoryPath(domain: domain, identifier: parentIdentifier)
            var paths = Set<Data>()
            for entry in entries {
                guard Self.validPath(entry.path), Self.parentPath(entry.path).utf8.elementsEqual(parentPath.utf8),
                      entry.filename.utf8.elementsEqual((entry.path as NSString).lastPathComponent.utf8),
                      paths.insert(Data(entry.path.utf8)).inserted else { throw ItemCatalogError.invalidListing }
            }
            let children = try query("SELECT \(Self.columns) FROM items WHERE domain=? AND parent IS ?", [domain, Self.storedParent(parentIdentifier)]).map(decode)
            // Match SQLite's binary path keys, not Swift's Unicode canonical equivalence.
            for child in children where !entries.contains(where: { $0.path.utf8.elementsEqual(child.path.utf8) && $0.isDirectory == child.metadata.isDirectory }) {
                _ = try query("DELETE FROM items WHERE domain=? AND identifier=?", [domain, child.identifier])
            }
            return try entries.map { entry in
                let old = try query("SELECT identifier FROM items WHERE domain=? AND path=?", [domain, entry.path]).first?.first.flatMap { $0 }
                return try save(domain: domain, identifier: old ?? CloudMountItemIdentifier.make(), parent: parentIdentifier, entry: entry)
            }
        } }
    }

    func update(domain: String, identifier: String, entry: CloudMountMetadata) throws -> CloudMountItemMetadata {
        try locked { try transaction {
            let record = try resolveUnlocked(domain: domain, identifier: identifier)
            guard record.path.utf8.elementsEqual(entry.path.utf8), record.metadata.isDirectory == entry.isDirectory,
                  entry.filename.utf8.elementsEqual(record.metadata.filename.utf8) else { throw ItemCatalogError.noSuchItem }
            return try save(domain: domain, identifier: identifier, parent: record.parentIdentifier, entry: entry)
        } }
    }

    /// relocate applies known continuity locally; it does not rename any backend object.
    func relocate(domain: String, identifier: String, parentIdentifier: String, filename: String) throws {
        try locked { try transaction {
            let record = try resolveUnlocked(domain: domain, identifier: identifier)
            let parentPath = try directoryPath(domain: domain, identifier: parentIdentifier)
            guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\0"),
                  !parentPath.utf8.elementsEqual(record.path.utf8), !parentPath.utf8.starts(with: (record.path + "/").utf8) else { throw ItemCatalogError.invalidMove }
            let destination = parentPath.isEmpty ? filename : parentPath + "/" + filename
            let all = try query("SELECT \(Self.columns) FROM items WHERE domain=?", [domain]).map(decode)
            let affected = all.filter { $0.identifier == identifier || $0.path.utf8.starts(with: (record.path + "/").utf8) }
            let unaffected = Set(all.filter { item in !affected.contains { $0.identifier == item.identifier } }.map { Data($0.path.utf8) })
            for item in affected {
                let path = destination + item.path.dropFirst(record.path.count)
                guard !unaffected.contains(Data(path.utf8)) else { throw ItemCatalogError.invalidMove }
                let parent = item.identifier == identifier ? parentIdentifier : item.parentIdentifier
                let entry = CloudMountMetadata(path: path, filename: (path as NSString).lastPathComponent, isDirectory: item.metadata.isDirectory,
                                              size: item.metadata.size, modificationTime: item.metadata.modificationTime, backendID: item.backendID, version: "")
                _ = try save(domain: domain, identifier: item.identifier, parent: parent, entry: entry)
            }
        } }
    }

    private func directoryPath(domain: String, identifier: String) throws -> String {
        guard try !query("SELECT domain FROM domains WHERE domain=?", [domain]).isEmpty else { throw ItemCatalogError.noSuchItem }
        if identifier == CloudMountItemIdentifier.root { return "" }
        let parent = try resolveUnlocked(domain: domain, identifier: identifier)
        guard parent.metadata.isDirectory else { throw ItemCatalogError.noSuchItem }
        return parent.path
    }

    private func resolveUnlocked(domain: String, identifier: String) throws -> Record {
        guard CloudMountItemIdentifier.isValid(identifier),
              let row = try query("SELECT \(Self.columns) FROM items WHERE domain=? AND identifier=?", [domain, identifier]).first else { throw ItemCatalogError.noSuchItem }
        return try decode(row)
    }

    private func save(domain: String, identifier: String, parent: String, entry: CloudMountMetadata) throws -> CloudMountItemMetadata {
        let content = Self.digest([entry.isDirectory ? "directory" : "file", entry.size.map(String.init) ?? "", entry.modificationTime ?? ""])
        let metadata = Self.digest([content, parent, entry.filename])
        let now = String(Date().timeIntervalSince1970)
        _ = try query("""
            INSERT INTO items(domain,identifier,parent,path,filename,is_directory,size,mtime,backend_id,content_version,metadata_version,created,last_seen)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(domain,identifier) DO UPDATE SET parent=excluded.parent,path=excluded.path,filename=excluded.filename,
            is_directory=excluded.is_directory,size=excluded.size,mtime=excluded.mtime,backend_id=excluded.backend_id,
            content_version=excluded.content_version,metadata_version=excluded.metadata_version,last_seen=excluded.last_seen
            """, [domain, identifier, Self.storedParent(parent), entry.path, entry.filename, entry.isDirectory ? "1" : "0",
                   entry.size.map(String.init), entry.modificationTime, entry.backendID, content, metadata, now, now])
        return try resolveUnlocked(domain: domain, identifier: identifier).metadata
    }

    private func decode(_ row: [String?]) throws -> Record {
        guard row.count == 10, let id = row[0], CloudMountItemIdentifier.isValid(id), let path = row[2], Self.validPath(path),
              let filename = row[3], let kind = row[4], ["0", "1"].contains(kind), let content = row[8], let metadata = row[9] else { throw ItemCatalogError.database }
        let parent = row[1] ?? CloudMountItemIdentifier.root
        guard parent == CloudMountItemIdentifier.root || CloudMountItemIdentifier.isValid(parent) else { throw ItemCatalogError.database }
        let item = CloudMountItemMetadata(itemIdentifier: id, parentIdentifier: parent, filename: filename, isDirectory: kind == "1",
                                         size: row[5].flatMap(Int64.init), modificationTime: row[6], contentVersion: content, metadataVersion: metadata)
        return Record(identifier: id, parentIdentifier: parent, path: path, metadata: item, backendID: row[7])
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func parentPath(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    private static func storedParent(_ identifier: String) -> String? { identifier == CloudMountItemIdentifier.root ? nil : identifier }
    private static func digest(_ values: [String]) -> String {
        // JSON framing prevents ambiguous concatenation of metadata values.
        SHA256.hash(data: try! JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }

    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func transaction<T>(_ action: () throws -> T) throws -> T {
        _ = try query("BEGIN IMMEDIATE")
        do { let result = try action(); _ = try query("COMMIT"); return result }
        catch { _ = try? query("ROLLBACK"); throw error }
    }

    private func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ItemCatalogError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            let result = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) } ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard result == SQLITE_OK else { throw ItemCatalogError.database }
        }
        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw ItemCatalogError.database }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: text)
            })
        }
    }
}
