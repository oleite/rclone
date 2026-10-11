import Foundation
import SQLite3

@main enum ItemCatalogTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func rejects(_ action: () throws -> Void) { do { try action(); fatalError("invalid operation accepted") } catch {} }
    static func metadata(_ path: String, directory: Bool = false, size: Int64 = 17) -> CloudMountMetadata {
        CloudMountMetadata(path: path, filename: (path as NSString).lastPathComponent, isDirectory: directory,
                           size: directory ? nil : size, modificationTime: "2026-10-01T12:00:00Z", backendID: nil, version: "unused-path-derived-version")
    }
    static func sql(_ file: URL, _ statement: String) {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { fatalError("test database open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { fatalError("test database statement failed") }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog.sqlite3")
        let catalog = try ItemCatalog(fileURL: file)
        try catalog.bind(domain: "A", remote: "local-one")
        let folders = try catalog.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("dir", directory: true), metadata("other", directory: true)])
        let dir = folders.first { $0.filename == "dir" }!.itemIdentifier
        let other = folders.first { $0.filename == "other" }!.itemIdentifier
        let a = try catalog.reconcile(domain: "A", parentIdentifier: dir, entries: [metadata("dir/a.exr"), metadata("dir/b.exr")])
        let x = a.first { $0.filename == "a.exr" }!
        let y = a.first { $0.filename == "b.exr" }!
        require(x.itemIdentifier != y.itemIdentifier, "siblings share identity")
        require(x.parentIdentifier == dir, "parent identity is not stable")
        require(CloudMountItemIdentifier.isValid(x.itemIdentifier), "opaque identity not canonical")
        let again = try catalog.reconcile(domain: "A", parentIdentifier: dir, entries: [metadata("dir/a.exr"), metadata("dir/b.exr")])
        require(again.first!.itemIdentifier == x.itemIdentifier, "repeat minted another identity")
        let reopened = try ItemCatalog(fileURL: file)
        require(try reopened.resolve(domain: "A", identifier: x.itemIdentifier).path == "dir/a.exr", "reopen lost identity/path")
        require(try reopened.resolve(domain: "A", identifier: x.itemIdentifier).parentIdentifier == dir, "reopen lost parent")
        try catalog.relocate(domain: "A", identifier: x.itemIdentifier, parentIdentifier: other, filename: "renamed.exr")
        let moved = try catalog.resolve(domain: "A", identifier: x.itemIdentifier)
        require(moved.path == "other/renamed.exr" && moved.parentIdentifier == other, "move lost stable identity/parent")
        require(moved.metadata.contentVersion == x.contentVersion, "rename changed content version")
        require(moved.metadata.metadataVersion != x.metadataVersion, "rename did not change metadata version")
        try catalog.relocate(domain: "A", identifier: other, parentIdentifier: CloudMountItemIdentifier.root, filename: "newdir")
        require(try catalog.resolve(domain: "A", identifier: x.itemIdentifier).path == "newdir/renamed.exr", "directory move lost descendant")
        rejects { try catalog.relocate(domain: "A", identifier: x.itemIdentifier, parentIdentifier: dir, filename: "b.exr") }
        require(try catalog.resolve(domain: "A", identifier: x.itemIdentifier).path == "newdir/renamed.exr", "collision did not roll back")
        let sub = try catalog.reconcile(domain: "A", parentIdentifier: dir, entries: [metadata("dir/b.exr"), metadata("dir/sub", directory: true)])[1].itemIdentifier
        let leaf = try catalog.reconcile(domain: "A", parentIdentifier: sub, entries: [metadata("dir/sub/leaf.bin")])[0].itemIdentifier
        let treeBefore = try [dir, y.itemIdentifier, sub, leaf].map { try catalog.resolve(domain: "A", identifier: $0) }
        rejects { try catalog.relocate(domain: "A", identifier: dir, parentIdentifier: CloudMountItemIdentifier.root, filename: "newdir") }
        for before in treeBefore {
            let after = try catalog.resolve(domain: "A", identifier: before.identifier)
            require(after.path == before.path && after.parentIdentifier == before.parentIdentifier && after.metadata.contentVersion == before.metadata.contentVersion && after.metadata.metadataVersion == before.metadata.metadataVersion, "directory-tree collision changed a descendant")
        }
        rejects { _ = try catalog.reconcile(domain: "A", parentIdentifier: dir, entries: [metadata("dir/new.exr"), metadata("dir/new.exr")]) }
        require(try catalog.resolve(domain: "A", identifier: y.itemIdentifier).path == "dir/b.exr", "bad listing partially changed catalog")
        rejects { _ = try catalog.reconcile(domain: "A", parentIdentifier: dir, entries: [metadata("../escape")]) }
        rejects { try catalog.relocate(domain: "A", identifier: dir, parentIdentifier: dir, filename: "cycle") }
        try catalog.bind(domain: "B", remote: "local-one")
        let b = try catalog.reconcile(domain: "B", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("newdir", directory: true)])
        require(b.first!.itemIdentifier != other, "domains share identity")
        rejects { _ = try catalog.resolve(domain: "B", identifier: x.itemIdentifier) }
        rejects { _ = try catalog.resolve(domain: "A", identifier: "f-bGVnYWN5") }
        try catalog.bind(domain: "A", remote: "local-two")
        rejects { _ = try catalog.resolve(domain: "A", identifier: x.itemIdentifier) }
        try catalog.purge(domain: "B")
        rejects { _ = try catalog.resolve(domain: "B", identifier: b.first!.itemIdentifier) }
        try catalog.bind(domain: "C", remote: "local-three")
        let errors = LockedErrors()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do { errors.addIdentifier(try catalog.reconcile(domain: "C", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("same.bin")])[0].itemIdentifier) }
            catch { errors.add(error) }
        }
        require(errors.isEmpty, "concurrent discovery failed")
        let one = try catalog.reconcile(domain: "C", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("same.bin")])[0]
        require(errors.identifiers.count == 32 && errors.identifiers.allSatisfy { $0 == one.itemIdentifier }, "concurrent callers received different identities")
        let secondConnection = try ItemCatalog(fileURL: file)
        require(try secondConnection.reconcile(domain: "C", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("same.bin")])[0].itemIdentifier == one.itemIdentifier, "duplicate path got two IDs")
        let changed = try catalog.update(domain: "C", identifier: one.itemIdentifier, entry: metadata("same.bin", size: 18))
        require(changed.contentVersion != one.contentVersion, "content metadata changes ignored")
        let freshKind = try catalog.reconcile(domain: "C", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("same.bin", directory: true)])[0]
        require(freshKind.itemIdentifier != one.itemIdentifier, "kind replacement retained old ID")
        rejects { _ = try catalog.resolve(domain: "C", identifier: one.itemIdentifier) }
        try catalog.bind(domain: "unicode", remote: "local-unicode")
        let composed = try catalog.reconcile(domain: "unicode", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("caf\u{00e9}.txt")])[0]
        let decomposed = try catalog.reconcile(domain: "unicode", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("cafe\u{0301}.txt")])[0]
        require(composed.itemIdentifier != decomposed.itemIdentifier, "unproven Unicode path change retained identity")
        rejects { _ = try catalog.resolve(domain: "unicode", identifier: composed.itemIdentifier) }
        require(try catalog.resolve(domain: "unicode", identifier: decomposed.itemIdentifier).path.utf8.elementsEqual("cafe\u{0301}.txt".utf8), "backend path bytes were normalized")
        let bothForms = try catalog.reconcile(domain: "unicode", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("caf\u{00e9}.txt"), metadata("cafe\u{0301}.txt")])
        require(bothForms.count == 2 && bothForms[0].itemIdentifier != bothForms[1].itemIdentifier, "distinct backend path bytes collided")
        try catalog.bind(domain: "rollback", remote: "local-rollback")
        let originals = try catalog.reconcile(domain: "rollback", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("gone.bin"), metadata("keep.bin")])
        // Abort only after reconciliation has deleted one row and changed another.
        sql(file, """
            CREATE TRIGGER reject_late_insert BEFORE INSERT ON items
            WHEN NEW.domain='rollback' AND NEW.filename='new.bin'
              AND NOT EXISTS(SELECT 1 FROM items WHERE domain='rollback' AND path='gone.bin')
              AND EXISTS(SELECT 1 FROM items WHERE domain='rollback' AND path='keep.bin' AND size=42)
            BEGIN SELECT RAISE(ABORT,'test failure after prior mutations'); END;
            """)
        rejects { _ = try catalog.reconcile(domain: "rollback", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("keep.bin", size: 42), metadata("new.bin")]) }
        for connection in [catalog, try ItemCatalog(fileURL: file)] {
            for original in originals {
                let item = try connection.resolve(domain: "rollback", identifier: original.itemIdentifier)
                require(item.path == original.filename && item.parentIdentifier == original.parentIdentifier && item.metadata.size == original.size && item.metadata.contentVersion == original.contentVersion && item.metadata.metadataVersion == original.metadataVersion, "failed transaction persisted prior mutations")
            }
            let stable = try connection.reconcile(domain: "rollback", parentIdentifier: CloudMountItemIdentifier.root, entries: [metadata("gone.bin"), metadata("keep.bin")])
            require(stable.map(\.itemIdentifier) == originals.map(\.itemIdentifier), "reopened rollback lost original identities")
        }
        sql(file, "DROP TRIGGER reject_late_insert")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        require(permissions.intValue == 0o600, "catalog permissions are not private")
        let newer = root.appendingPathComponent("newer.sqlite3")
        sql(newer, "PRAGMA user_version=99")
        rejects { _ = try ItemCatalog(fileURL: newer) }
        let malformed = root.appendingPathComponent("malformed.sqlite3")
        sql(malformed, "PRAGMA user_version=1; CREATE TABLE items (wrong TEXT)")
        rejects { _ = try ItemCatalog(fileURL: malformed) }
        let unconstrained = root.appendingPathComponent("unconstrained.sqlite3")
        sql(unconstrained, """
            PRAGMA user_version=1;
            CREATE TABLE domains (domain TEXT, binding TEXT);
            CREATE TABLE items (domain TEXT, identifier TEXT, parent TEXT, path TEXT, filename TEXT,
                is_directory INTEGER, size INTEGER, mtime TEXT, backend_id TEXT,
                content_version TEXT, metadata_version TEXT, created REAL, last_seen REAL);
            """)
        rejects { _ = try ItemCatalog(fileURL: unconstrained) }
        let corrupt = root.appendingPathComponent("corrupt.sqlite3")
        try Data("not a database".utf8).write(to: corrupt)
        rejects { _ = try ItemCatalog(fileURL: corrupt) }
        print("ItemCatalog tests passed: persistence, concurrency, move/rollback, isolation, purge, schema, corruption")
    }
}

private final class LockedErrors {
    private let lock = NSLock(); private var errors: [Error] = []; private var values: [String] = []
    func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
    func addIdentifier(_ identifier: String) { lock.lock(); defer { lock.unlock() }; values.append(identifier) }
    var identifiers: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return errors.isEmpty }
}
