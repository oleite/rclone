import Foundation
import SQLite3

@main enum SyncCatalogTests {
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func entry(_ path: String, directory: Bool = false, size: Int64 = 10) -> CloudMountMetadata {
        CloudMountMetadata(path: path, filename: (path as NSString).lastPathComponent, isDirectory: directory,
                           size: directory ? nil : size, modificationTime: "2026-10-13T12:00:00Z", backendID: nil, version: "")
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("legacy.sqlite3")
        try seedV1(legacy)
        let migrated = try ItemCatalog(fileURL: legacy)
        let legacyID = "i-00000000-0000-0000-0000-000000000001"
        for domain in ["A", "B", "C"] {
            let record = try migrated.resolve(domain: domain, identifier: legacyID)
            require(record.path == "old.txt" && record.metadata.size == 7 && record.metadata.contentVersion == "old-content" &&
                    record.metadata.metadataVersion == "old-metadata" && record.backendID == "private-evidence", "v1 migration altered original row")
            require(try migrated.authoritativeDirectories(domain: domain) == [CloudMountItemIdentifier.root], "migration lost observed root")
        }
        let migratedAnchor = try migrated.currentAnchor(domain: "A")
        require(try ItemCatalog(fileURL: legacy).currentAnchor(domain: "A") == migratedAnchor, "migration repeated/changed epoch")
        let file = directory.appendingPathComponent("catalog.sqlite3")
        let catalog = try ItemCatalog(fileURL: file, journalLimit: 6)
        try catalog.bind(domain: "A", remote: "fixture-a:")
        try catalog.bind(domain: "B", remote: "fixture-b:")
        let root = CloudMountItemIdentifier.root
        let a0 = try catalog.currentAnchor(domain: "A")
        let original = try catalog.reconcile(domain: "A", parentIdentifier: root, entries: [entry("keep.txt"), entry("folder", directory: true)])
        let baseline = try catalog.currentAnchor(domain: "A")
        require(baseline != a0, "baseline changes must protect working set page revision")
        require(try catalog.changes(domain: "A", container: root, from: a0, limit: 2).items.isEmpty, "first enumeration manufactured fake changes")
        require(try catalog.authoritativeDirectories(domain: "A") == [root], "known directory incorrectly authoritative")
        _ = try catalog.reconcile(domain: "A", parentIdentifier: root, entries: [entry("keep.txt"), entry("folder", directory: true)])
        require(try catalog.currentAnchor(domain: "A") == baseline, "no-op advanced revision")
        let folder = original[1].itemIdentifier
        let child = try catalog.reconcile(domain: "A", parentIdentifier: folder, entries: [entry("folder/child.txt")])[0]
        let before = try catalog.currentAnchor(domain: "A")
        let changed = try catalog.reconcile(domain: "A", parentIdentifier: root, entries: [entry("keep.txt", size: 20), entry("new.txt")])
        let delta = try catalog.changes(domain: "A", container: CloudMountItemIdentifier.workingSet, from: before, limit: 6)
        require(Set(delta.items.map(\.filename)) == ["keep.txt", "new.txt"], "create/update missing")
        require(Set(delta.deleted) == [folder, child.itemIdentifier], "subtree tombstones missing")
        let finalAnchor = try catalog.currentAnchor(domain: "A")
        require(!delta.moreComing && delta.anchor == finalAnchor, "delta failed to reach head")
        require(changed[0].itemIdentifier == original[0].itemIdentifier, "modify changed identity")
        let scoped = try catalog.changes(domain: "A", container: root, from: before, limit: 6)
        require(scoped.deleted == [folder], "root delta includes descendant deletion")
        let reopened = try ItemCatalog(fileURL: file, journalLimit: 6)
        require(try reopened.currentAnchor(domain: "A") == delta.anchor, "restart lost anchor")
        require(try reopened.changes(domain: "A", container: root, from: before, limit: 6).items.count == 2, "restart lost journal")
        rejectsAnchor { _ = try catalog.changes(domain: "B", container: root, from: before, limit: 2) }
        for invalid in [Data(), Data("1".utf8), Data("2:not-uuid:0".utf8), Data("2:00000000-0000-0000-0000-000000000000:00".utf8)] {
            rejectsAnchor { _ = try catalog.changes(domain: "A", container: root, from: invalid, limit: 2) }
        }
        let pageStart = try catalog.currentAnchor(domain: "A")
        let many = (0..<5).map { entry("item\($0).txt") }
        _ = try catalog.reconcile(domain: "A", parentIdentifier: root, entries: changed.map { entry($0.filename, size: $0.size!) } + many)
        var cursor = pageStart; var found = Set<String>(); var pages = 0
        repeat {
            let value = try catalog.changes(domain: "A", container: root, from: cursor, limit: 2)
            for item in value.items { require(found.insert(item.filename).inserted, "duplicate across change pages") }
            cursor = value.anchor; pages += 1
            if !value.moreComing { break }
        } while pages < 10
        require(found == Set(many.map(\.filename)) && pages == 3, "pagination lost updates")
        rejectsAnchor { _ = try catalog.changes(domain: "A", container: root, from: baseline, limit: 2) }
        let page = try catalog.workingSet(domain: "A", page: nil, limit: 2)
        require(page.items.count == 2 && page.nextPage != nil, "working set not bounded")
        let head = try catalog.currentAnchor(domain: "A")
        var all = page.items; var next = page.nextPage
        while let token = next { let value = try catalog.workingSet(domain: "A", page: token, limit: 2); all += value.items; next = value.nextPage }
        require(all.count == 7 && Set(all.map(\.itemIdentifier)).count == 7, "working set lost/duplicated known items")
        _ = try catalog.update(domain: "A", identifier: original[0].itemIdentifier, entry: entry("keep.txt", size: 30))
        rejectsAnchor { _ = try catalog.workingSet(domain: "A", page: page.nextPage, limit: 2) }
        let latest = try catalog.changes(domain: "A", container: root, from: head, limit: 2)
        require(latest.items.count == 1 && latest.items[0].size == 30, "stat update not journaled")
        // Pruning while another consumer pages must expire, not omit old rows.
        let slowCursor = latest.anchor
        for size in 31...38 { _ = try catalog.update(domain: "A", identifier: original[0].itemIdentifier, entry: entry("keep.txt", size: Int64(size))) }
        rejectsAnchor { _ = try catalog.changes(domain: "A", container: root, from: slowCursor, limit: 2) }
        let beforeRollback = try catalog.currentAnchor(domain: "A")
        try exec(file, "CREATE TRIGGER reject_journal BEFORE INSERT ON changes BEGIN SELECT RAISE(ABORT,'injected journal failure'); END")
        do { _ = try catalog.update(domain: "A", identifier: original[0].itemIdentifier, entry: entry("keep.txt", size: 999)); fatalError("SQLite failure accepted") }
        catch ItemCatalogError.database {}
        require(try catalog.resolve(domain: "A", identifier: original[0].itemIdentifier).metadata.size == 38, "journal failure changed item")
        require(try catalog.currentAnchor(domain: "A") == beforeRollback, "journal failure changed revision")
        try exec(file, "DROP TRIGGER reject_journal")
        // A page coalesces repeated transitions to final state; no update/delete ambiguity.
        let burstStart = try catalog.currentAnchor(domain: "A")
        _ = try catalog.update(domain: "A", identifier: original[0].itemIdentifier, entry: entry("keep.txt", size: 40))
        _ = try catalog.reconcile(domain: "A", parentIdentifier: root, entries: many + [entry("new.txt")])
        let burst = try catalog.changes(domain: "A", container: root, from: burstStart, limit: 6)
        require(burst.deleted == [original[0].itemIdentifier] && burst.items.isEmpty, "update followed by delete not coalesced")
        // Unrelated domain/container revisions must not be returned as this container's items.
        _ = try catalog.reconcile(domain: "B", parentIdentifier: root, entries: [])
        let bStart = try catalog.currentAnchor(domain: "B")
        _ = try catalog.reconcile(domain: "B", parentIdentifier: root, entries: [entry("other.txt")])
        require(try catalog.changes(domain: "A", container: root, from: burst.anchor, limit: 2).items.isEmpty, "B journal crossed A")
        require(try catalog.changes(domain: "B", container: root, from: bStart, limit: 2).items.count == 1, "empty authoritative root missed create")
        let paging = try ItemCatalog(fileURL: directory.appendingPathComponent("large-page.sqlite3"))
        try paging.bind(domain: "pages", remote: "fixture-pages:")
        _ = try paging.reconcile(domain: "pages", parentIdentifier: root, entries: [])
        let pageAnchor = try paging.currentAnchor(domain: "pages")
        _ = try paging.reconcile(domain: "pages", parentIdentifier: root, entries: (0...200).map { entry("entry-\($0).txt") })
        let large = try paging.changes(domain: "pages", container: root, from: pageAnchor, limit: 100_000)
        require(large.items.count == 200 && large.moreComing, "production payload bound not enforced")
        let tail = try paging.changes(domain: "pages", container: root, from: large.anchor, limit: 200)
        require(tail.items.count == 1 && !tail.moreComing, "production page boundary lost final item")
        try paging.bind(domain: "filter", remote: "fixture-filter:")
        let parent = try paging.reconcile(domain: "filter", parentIdentifier: root, entries: [entry("nested", directory: true)])[0]
        _ = try paging.reconcile(domain: "filter", parentIdentifier: parent.itemIdentifier, entries: [])
        let filterAnchor = try paging.currentAnchor(domain: "filter")
        _ = try paging.reconcile(domain: "filter", parentIdentifier: root, entries: [entry("nested", directory: true), entry("unrelated.txt")])
        let unrelated = try paging.changes(domain: "filter", container: parent.itemIdentifier, from: filterAnchor, limit: 2)
        require(unrelated.items.isEmpty && unrelated.anchor != filterAnchor && !unrelated.moreComing, "unrelated revisions did not advance filtered anchor")
        let leaf = try paging.reconcile(domain: "filter", parentIdentifier: parent.itemIdentifier, entries: [entry("nested/leaf.txt")])[0]
        let itemAnchor = try paging.currentAnchor(domain: "filter")
        _ = try paging.update(domain: "filter", identifier: leaf.itemIdentifier, entry: entry("nested/leaf.txt", size: 50))
        let document = try paging.changes(domain: "filter", container: leaf.itemIdentifier, from: itemAnchor, limit: 2)
        require(document.items.count == 1 && document.items[0].size == 50, "single-document change filtering broken")
        try catalog.bind(domain: "A", remote: "other:")
        rejectsAnchor { _ = try catalog.changes(domain: "A", container: root, from: latest.anchor, limit: 2) }
        print("SyncCatalog tests passed: baselines, durable journal, subtree deletion, domain epochs, pagination, pruning, working set")
    }
    static func exec(_ file: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK else { fatalError("test database unavailable") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { fatalError("test SQL failed") }
    }
    static func seedV1(_ file: URL) throws {
        try exec(file, """
            PRAGMA user_version=1;
            CREATE TABLE domains (domain TEXT PRIMARY KEY NOT NULL, binding TEXT NOT NULL);
            CREATE TABLE items (
                domain TEXT NOT NULL, identifier TEXT NOT NULL, parent TEXT,
                path TEXT NOT NULL CHECK(length(path)>0), filename TEXT NOT NULL,
                is_directory INTEGER NOT NULL CHECK(is_directory IN (0,1)), size INTEGER, mtime TEXT, backend_id TEXT,
                content_version TEXT NOT NULL, metadata_version TEXT NOT NULL, created REAL NOT NULL, last_seen REAL NOT NULL,
                PRIMARY KEY(domain,identifier), UNIQUE(domain,path),
                FOREIGN KEY(domain) REFERENCES domains(domain) ON DELETE CASCADE,
                FOREIGN KEY(domain,parent) REFERENCES items(domain,identifier) ON DELETE CASCADE);
            CREATE INDEX items_parent ON items(domain,parent);
            """)
        for domain in ["A", "B", "C"] {
            try exec(file, """
                INSERT INTO domains VALUES ('\(domain)','binding-preserved');
                INSERT INTO items VALUES ('\(domain)','i-00000000-0000-0000-0000-000000000001',NULL,'old.txt','old.txt',0,7,
                '2026-10-01T00:00:00Z','private-evidence','old-content','old-metadata',1,2);
                """)
        }
    }
    static func rejectsAnchor(_ action: () throws -> Void) {
        do { try action(); fatalError("invalid/expired anchor accepted") }
        catch ItemCatalogError.syncAnchorExpired {}
        catch { fatalError("wrong anchor error") }
    }
}
