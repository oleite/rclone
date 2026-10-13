import CryptoKit
import Foundation
import SQLite3

enum ItemCatalogError: LocalizedError {
    case noSuchItem, invalidListing, invalidMove, database, unsupportedVersion, syncAnchorExpired
    var errorDescription: String? {
        switch self {
        case .noSuchItem: return "item not found"
        case .invalidListing: return "invalid directory listing"
        case .invalidMove: return "invalid catalog move"
        case .database: return "CloudMount item catalog unavailable"
        case .unsupportedVersion: return "unsupported CloudMount item catalog version"
        case .syncAnchorExpired: return "sync anchor expired"
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
    private let journalLimit: Int
    private static let columns = "identifier,parent,path,filename,is_directory,size,mtime,backend_id,content_version,metadata_version"

    init(fileURL: URL, journalLimit: Int = 20_000) throws {
        self.journalLimit = max(1, journalLimit)
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
                case 1, 2: break
                default: throw ItemCatalogError.unsupportedVersion
                }
                if version < 2 { try migrateSyncState() }
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
                _ = try query("SELECT domain,epoch,revision,floor FROM domains LIMIT 0")
                _ = try query("SELECT domain,identifier,last_scan FROM directory_state LIMIT 0")
                _ = try query("SELECT domain,sequence,parent,identifier,metadata FROM changes LIMIT 0")
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
            _ = try query("INSERT INTO domains(domain,binding,epoch) VALUES (?,?,?)", [domain, binding, UUID().uuidString.lowercased()])
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
            let authoritative = try !query("SELECT identifier FROM directory_state WHERE domain=? AND identifier=?", [domain, parentIdentifier]).isEmpty
            var baselineChanged = false
            // Match SQLite's binary path keys, not Swift's Unicode canonical equivalence.
            for child in children where !entries.contains(where: { $0.path.utf8.elementsEqual(child.path.utf8) && $0.isDirectory == child.metadata.isDirectory }) {
                let retired = try query("""
                    WITH RECURSIVE subtree(identifier) AS (
                      SELECT identifier FROM items WHERE domain=? AND identifier=?
                      UNION ALL SELECT i.identifier FROM items i JOIN subtree s ON i.parent=s.identifier WHERE i.domain=?)
                    SELECT \(Self.columns) FROM items WHERE domain=? AND identifier IN subtree
                    """, [domain, child.identifier, domain, domain]).map(decode)
                if authoritative { for record in retired { try appendChange(domain: domain, parent: record.parentIdentifier, identifier: record.identifier, metadata: nil) } }
                else { baselineChanged = true }
                _ = try query("DELETE FROM items WHERE domain=? AND identifier=?", [domain, child.identifier])
            }
            let result = try entries.map { entry in
                let old = try query("SELECT \(Self.columns) FROM items WHERE domain=? AND path=?", [domain, entry.path]).first.map(decode)
                let current = try save(domain: domain, identifier: old?.identifier ?? CloudMountItemIdentifier.make(), parent: parentIdentifier, entry: entry)
                if old?.metadata.metadataVersion != current.metadataVersion {
                    if authoritative { try appendChange(domain: domain, parent: parentIdentifier, identifier: current.itemIdentifier, metadata: current) }
                    else { baselineChanged = true }
                }
                return current
            }
            _ = try query("DELETE FROM directory_state WHERE domain=? AND identifier!=? AND identifier NOT IN (SELECT identifier FROM items WHERE domain=?)", [domain, CloudMountItemIdentifier.root, domain])
            _ = try query("INSERT INTO directory_state(domain,identifier,last_scan) VALUES (?,?,?) ON CONFLICT(domain,identifier) DO UPDATE SET last_scan=excluded.last_scan", [domain, parentIdentifier, String(Date().timeIntervalSince1970)])
            if baselineChanged { try advanceRevision(domain: domain) }
            return result
        } }
    }

    func update(domain: String, identifier: String, entry: CloudMountMetadata) throws -> CloudMountItemMetadata {
        try locked { try transaction {
            let record = try resolveUnlocked(domain: domain, identifier: identifier)
            guard record.path.utf8.elementsEqual(entry.path.utf8), record.metadata.isDirectory == entry.isDirectory,
                  entry.filename.utf8.elementsEqual(record.metadata.filename.utf8) else { throw ItemCatalogError.noSuchItem }
            let current = try save(domain: domain, identifier: identifier, parent: record.parentIdentifier, entry: entry)
            if current.metadataVersion != record.metadata.metadataVersion { try appendChange(domain: domain, parent: record.parentIdentifier, identifier: identifier, metadata: current) }
            return current
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
                let current = try save(domain: domain, identifier: item.identifier, parent: parent, entry: entry)
                if item.parentIdentifier != parent { try appendChange(domain: domain, parent: item.parentIdentifier, identifier: item.identifier, metadata: nil) }
                if current.metadataVersion != item.metadata.metadataVersion { try appendChange(domain: domain, parent: parent, identifier: item.identifier, metadata: current) }
            }
        } }
    }

    private func migrateSyncState() throws {
        _ = try query("ALTER TABLE domains ADD COLUMN epoch TEXT NOT NULL DEFAULT ''")
        _ = try query("ALTER TABLE domains ADD COLUMN revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)")
        _ = try query("ALTER TABLE domains ADD COLUMN floor INTEGER NOT NULL DEFAULT 0 CHECK(floor>=0 AND floor<=revision)")
        for row in try query("SELECT domain FROM domains") {
            _ = try query("UPDATE domains SET epoch=? WHERE domain=?", [UUID().uuidString.lowercased(), row[0]])
        }
        _ = try query("""
            CREATE TABLE directory_state (
                domain TEXT NOT NULL, identifier TEXT NOT NULL, last_scan REAL NOT NULL,
                PRIMARY KEY(domain,identifier), FOREIGN KEY(domain) REFERENCES domains(domain) ON DELETE CASCADE)
            """)
        _ = try query("INSERT INTO directory_state SELECT DISTINCT domain,COALESCE(parent,?),0 FROM items", [CloudMountItemIdentifier.root])
        _ = try query("""
            CREATE TABLE changes (
                domain TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>0),
                parent TEXT NOT NULL, identifier TEXT NOT NULL, metadata TEXT,
                PRIMARY KEY(domain,sequence), FOREIGN KEY(domain) REFERENCES domains(domain) ON DELETE CASCADE)
            """)
        _ = try query("CREATE INDEX changes_parent ON changes(domain,parent,sequence)")
        _ = try query("PRAGMA user_version=2")
    }

    func revision(domain: String) throws -> Int64 {
        try locked { try anchorUnlocked(domain: domain).sequence }
    }

    func currentAnchor(domain: String) throws -> Data {
        try locked { try anchorUnlocked(domain: domain).data }
    }

    func authoritativeDirectories(domain: String) throws -> [String] {
        try locked { try query("SELECT identifier FROM directory_state WHERE domain=? ORDER BY identifier", [domain]).compactMap { $0[0] } }
    }

    private func anchorUnlocked(domain: String) throws -> CloudMountSyncAnchor {
        guard let row = try query("SELECT epoch,revision FROM domains WHERE domain=?", [domain]).first,
              let epoch = row[0].flatMap(UUID.init(uuidString:)), let sequence = row[1].flatMap(Int64.init), sequence >= 0 else { throw ItemCatalogError.noSuchItem }
        return CloudMountSyncAnchor(epoch: epoch, sequence: sequence)
    }

    @discardableResult private func advanceRevision(domain: String) throws -> Int64 {
        let current = try anchorUnlocked(domain: domain).sequence
        guard current < Int64.max else { throw ItemCatalogError.database }
        _ = try query("UPDATE domains SET revision=revision+1 WHERE domain=?", [domain])
        return current + 1
    }

    private func appendChange(domain: String, parent: String, identifier: String, metadata: CloudMountItemMetadata?) throws {
        let sequence = try advanceRevision(domain: domain)
        let payload = try metadata.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        _ = try query("INSERT INTO changes(domain,sequence,parent,identifier,metadata) VALUES (?,?,?,?,?)", [domain, String(sequence), parent, identifier, payload])
        if let removed = try query("SELECT sequence FROM changes WHERE domain=? ORDER BY sequence DESC LIMIT 1 OFFSET ?", [domain, String(journalLimit)]).first?[0] {
            _ = try query("UPDATE domains SET floor=MAX(floor,?) WHERE domain=?", [removed, domain])
            _ = try query("DELETE FROM changes WHERE domain=? AND sequence<=?", [domain, removed])
        }
    }

    func changes(domain: String, container: String, from data: Data, limit: Int) throws -> CloudMountChangeResponse {
        try locked { try transaction {
            let head = try anchorUnlocked(domain: domain)
            guard let from = CloudMountSyncAnchor.decode(data), from.epoch == head.epoch,
                  from.sequence <= head.sequence,
                  let floor = try query("SELECT floor FROM domains WHERE domain=?", [domain]).first?[0].flatMap(Int64.init),
                  from.sequence >= floor else { throw ItemCatalogError.syncAnchorExpired }
            let bound = min(200, max(1, limit))
            var filter = ""; var parameters: [String?] = [domain, String(from.sequence)]
            if container != CloudMountItemIdentifier.workingSet {
                if container == CloudMountItemIdentifier.root { filter = " AND parent=?" }
                else {
                    guard CloudMountItemIdentifier.isValid(container) else { throw ItemCatalogError.noSuchItem }
                    let kind = try query("SELECT is_directory FROM items WHERE domain=? AND identifier=?", [domain, container]).first?[0]
                    let deletedDirectory = try !query("SELECT sequence FROM changes WHERE domain=? AND parent=? LIMIT 1", [domain, container]).isEmpty
                    filter = kind == "1" || deletedDirectory ? " AND parent=?" : " AND identifier=?"
                }
                parameters.append(container)
            }
            parameters.append(String(bound + 1))
            let rows = try query("SELECT sequence,identifier,metadata FROM changes WHERE domain=? AND sequence>?\(filter) ORDER BY sequence LIMIT ?", parameters)
            let more = rows.count > bound
            let consumed = Array(rows.prefix(bound))
            var updates: [String: CloudMountItemMetadata] = [:]; var deleted = Set<String>()
            for row in consumed {
                guard let identifier = row[1], CloudMountItemIdentifier.isValid(identifier) else { throw ItemCatalogError.database }
                if let payload = row[2] {
                    let item = try JSONDecoder().decode(CloudMountItemMetadata.self, from: Data(payload.utf8))
                    guard item.itemIdentifier == identifier else { throw ItemCatalogError.database }
                    updates[identifier] = item; deleted.remove(identifier)
                } else { updates.removeValue(forKey: identifier); deleted.insert(identifier) }
            }
            let sequence = more ? consumed.last![0].flatMap(Int64.init)! : head.sequence
            return CloudMountChangeResponse(items: updates.values.sorted { $0.itemIdentifier < $1.itemIdentifier }, deleted: deleted.sorted(),
                anchor: CloudMountSyncAnchor(epoch: head.epoch, sequence: sequence).data, moreComing: more, nextPage: nil)
        } }
    }

    func workingSet(domain: String, page: Data?, limit: Int) throws -> CloudMountChangeResponse {
        try locked { try transaction {
            let head = try anchorUnlocked(domain: domain)
            var offset = 0
            if let page {
                guard page.count < 500, let text = String(data: page, encoding: .utf8) else { throw ItemCatalogError.syncAnchorExpired }
                let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "w2", let anchor = Data(base64Encoded: String(parts[1])), anchor == head.data,
                      let value = Int(parts[2]), value >= 0, String(value) == parts[2],
                      "w2:\(head.data.base64EncodedString()):\(value)" == text else { throw ItemCatalogError.syncAnchorExpired }
                offset = value
            }
            let bound = min(200, max(1, limit))
            let records = try query("SELECT \(Self.columns) FROM items WHERE domain=? ORDER BY identifier LIMIT ? OFFSET ?", [domain, String(bound + 1), String(offset)]).map(decode)
            let more = records.count > bound
            return CloudMountChangeResponse(items: records.prefix(bound).map(\.metadata), deleted: [], anchor: head.data, moreComing: false,
                nextPage: more ? Data("w2:\(head.data.base64EncodedString()):\(offset + bound)".utf8) : nil)
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
