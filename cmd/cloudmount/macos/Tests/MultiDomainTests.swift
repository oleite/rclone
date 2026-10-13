import FileProvider
import Foundation
import SQLite3

@main enum MultiDomainTests {
    static func main() throws {
        guard CloudMountPeerIdentity.acceptsUser(501, expected: 501), !CloudMountPeerIdentity.acceptsUser(502, expected: 501),
              !CloudMountPeerIdentity.acceptsUser(0, expected: 501) else { fatalError("peer user isolation failed") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("domains.json"), catalogURL = directory.appendingPathComponent("catalog.sqlite3")
        let store = DomainConfigurationStore(fileURL: configURL), catalog = try ItemCatalog(fileURL: catalogURL)
        let domains = DomainCatalog(configuration: store, catalog: catalog)
        let a = CloudMountDomainIdentifier.make(), b = CloudMountDomainIdentifier.make(), c = CloudMountDomainIdentifier.make()
        var items: [String: CloudMountItemMetadata] = [:]
        for (domain, name) in [(a, "a.txt"), (b, "b.txt"), (c, "c.txt")] {
            try domains.configure(domain: domain, remote: "fixture-" + name + ":")
            let entry = CloudMountMetadata(path: name, filename: name, isDirectory: false, size: 7, modificationTime: nil, backendID: "same-backend-id", version: "")
            let snapshot = try domains.snapshot(domain: domain)
            let item = try domains.withSnapshot(snapshot) { try $0.reconcile(domain: domain, parentIdentifier: CloudMountItemIdentifier.root, entries: [entry])[0] }
            let repeated = try domains.withSnapshot(snapshot) { try $0.reconcile(domain: domain, parentIdentifier: CloudMountItemIdentifier.root, entries: [entry])[0] }
            guard item.itemIdentifier == repeated.itemIdentifier, item.parentIdentifier == CloudMountItemIdentifier.root else { fatalError("repeated enumeration changed identity/parent") }
            items[domain] = item
        }
        let reopened = try ItemCatalog(fileURL: catalogURL)
        for domain in [a, b, c] {
            guard try reopened.resolve(domain: domain, identifier: items[domain]!.itemIdentifier).metadata.filename == items[domain]!.filename else { fatalError("restart lost identity") }
        }
        expectMissing { _ = try catalog.resolve(domain: b, identifier: items[a]!.itemIdentifier) }
        expectMissing { _ = try domains.snapshot(domain: "malformed-unknown") }
        // Seed the same UUID representation in two domains to prove lookup uses
        // the complete domain+ID key, rather than a global identifier cache.
        var database: OpaquePointer?
        guard sqlite3_open(catalogURL.path, &database) == SQLITE_OK else { fatalError("test catalog open failed") }
        defer { sqlite3_close(database) }
        let shared = items[a]!.itemIdentifier
        guard sqlite3_exec(database, "UPDATE items SET identifier='\(shared)' WHERE domain='\(b)'", nil, nil, nil) == SQLITE_OK else { fatalError("shared UUID fixture failed") }
        guard try catalog.resolve(domain: a, identifier: shared).path == "a.txt",
              try catalog.resolve(domain: b, identifier: shared).path == "b.txt" else { fatalError("identical ID representations crossed domains") }
        let stale = try domains.snapshot(domain: a)
        try domains.configure(domain: a, remote: "remapped:")
        expectMissing { _ = try domains.withSnapshot(stale) { _ in true } }
        guard try catalog.resolve(domain: b, identifier: shared).path == "b.txt",
              try catalog.resolve(domain: c, identifier: items[c]!.itemIdentifier).path == "c.txt" else { fatalError("remap crossed domains") }
        let active = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completed.signal() }
            do { try domains.withDirectoryDiscovery(domain: a, parentIdentifier: CloudMountItemIdentifier.root) { snapshot in
                active.signal(); guard release.wait(timeout: .now() + 5) == .success else { fatalError("stalled domain not released") }
                expectMissing { _ = try domains.withSnapshot(snapshot) { _ in true } }
            } } catch { fatalError("A discovery setup failed") }
        }
        guard active.wait(timeout: .now() + 5) == .success else { fatalError("A discovery didn't start") }
        let independent = DispatchSemaphore(value: 0)
        for domain in [b, c] {
            DispatchQueue.global().async {
                do { try domains.withDirectoryDiscovery(domain: domain, parentIdentifier: CloudMountItemIdentifier.root) { snapshot in
                    _ = try domains.withSnapshot(snapshot) { _ in true }
                }; independent.signal() } catch { fatalError("independent discovery failed") }
            }
        }
        guard independent.wait(timeout: .now() + 2) == .success, independent.wait(timeout: .now() + 2) == .success else { fatalError("stalled A blocked B/C") }
        try domains.remove(domain: a)
        release.signal()
        guard completed.wait(timeout: .now() + 5) == .success else { fatalError("stale A completion deadlocked") }
        guard try !store.isConfigured(domainIdentifier: a), try store.isConfigured(domainIdentifier: b), try store.isConfigured(domainIdentifier: c),
              try reopened.resolve(domain: b, identifier: shared).path == "b.txt" else { fatalError("A removal affected B/C") }
        for (id, name) in [(b, "Context B"), (c, "Context C")] {
            let provider = FileProviderExtension(domain: NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: name))
            var observed: NSFileProviderItem?
            _ = provider.item(for: .rootContainer, request: NSFileProviderRequest()) { item, error in
                guard error == nil else { fatalError("root lookup failed") }; observed = item
            }
            guard observed?.filename == name, observed?.itemIdentifier == .rootContainer else { fatalError("provider root context crossed domains") }
        }
        print("MultiDomain tests passed: A/B/C persistence/isolation, identical UUIDs, stale completions, concurrent discovery, Provider contexts, peer UID")
    }
    private static func expectMissing(_ body: () throws -> Void) {
        do { try body(); fatalError("cross-domain or stale lookup accepted") }
        catch ItemCatalogError.noSuchItem {} catch { fatalError("wrong isolation error") }
    }
}
