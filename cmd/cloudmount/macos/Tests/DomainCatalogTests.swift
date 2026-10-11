import Foundation

@main enum DomainCatalogTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DomainConfigurationStore(fileURL: directory.appendingPathComponent("domains.json"))
        let catalog = try ItemCatalog(fileURL: directory.appendingPathComponent("catalog.sqlite3"))
        let domains = DomainCatalog(configuration: store, catalog: catalog)
        let entry = CloudMountMetadata(path: "one.txt", filename: "one.txt", isDirectory: false, size: 1, modificationTime: nil, backendID: nil, version: "")
        try domains.configure(domain: "A", remote: "local-one")
        let old = try catalog.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [entry])[0].itemIdentifier
        // Simulate a crash after JSON write but before binding update.
        try store.configure(domainIdentifier: "A", remote: "local-two")
        guard try domains.snapshot(domain: "A").remote == "local-two" else { fatalError("mapping recovery failed") }
        do { _ = try catalog.resolve(domain: "A", identifier: old); fatalError("old ID survived mapping recovery") } catch {}
        let fresh = try catalog.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [entry])[0].itemIdentifier
        try domains.configure(domain: "A", remote: "local-two")
        guard try catalog.resolve(domain: "A", identifier: fresh).path == "one.txt" else { fatalError("same selector reset identity") }
        try domains.remove(domain: "A")
        guard try !store.isConfigured(domainIdentifier: "A") else { fatalError("mapping not removed") }
        do { _ = try catalog.resolve(domain: "A", identifier: fresh); fatalError("catalog not purged") } catch {}
        try domains.configure(domain: "A", remote: "local-two")
        let recreated = try catalog.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [entry])[0].itemIdentifier
        guard recreated != fresh else { fatalError("removed domain reused identity") }
        let pending = try domains.snapshot(domain: "A")
        try domains.configure(domain: "A", remote: "local-three")
        do {
            _ = try domains.withSnapshot(pending) { try $0.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [entry]) }
            fatalError("stale directory completion repopulated remapped domain")
        } catch ItemCatalogError.noSuchItem {}
        let current = try domains.snapshot(domain: "A")
        let currentID = try domains.withSnapshot(current) { try $0.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [entry])[0].itemIdentifier }
        try domains.configure(domain: "A", remote: "local-two")
        try domains.configure(domain: "A", remote: "local-three")
        do { _ = try domains.withSnapshot(current) { try $0.resolve(domain: "A", identifier: currentID) }; fatalError("ABA remapping accepted stale result") }
        catch ItemCatalogError.noSuchItem {}
        let beforeRemoval = try domains.snapshot(domain: "A")
        try domains.remove(domain: "A")
        do { _ = try domains.withSnapshot(beforeRemoval) { _ in true }; fatalError("removed domain accepted old generation") }
        catch ItemCatalogError.noSuchItem {}
        try domains.configure(domain: "A", remote: "local-three")
        do { _ = try domains.withSnapshot(beforeRemoval) { _ in true }; fatalError("remove/re-add accepted old generation") }
        catch ItemCatalogError.noSuchItem {}
        let discoveredDirectory = CloudMountMetadata(path: "discovered", filename: "discovered", isDirectory: true, size: nil, modificationTime: nil, backendID: nil, version: "")
        let olderEntered = DispatchSemaphore(value: 0), releaseOlder = DispatchSemaphore(value: 0), olderDone = DispatchSemaphore(value: 0)
        let newerRequested = DispatchSemaphore(value: 0), newerEntered = DispatchSemaphore(value: 0), newerDone = DispatchSemaphore(value: 0)
        let results = DiscoveryResults()
        DispatchQueue.global().async {
            defer { olderDone.signal() }
            do { try domains.withDirectoryDiscovery(domain: "A", parentIdentifier: CloudMountItemIdentifier.root) { snapshot in
                olderEntered.signal(); guard releaseOlder.wait(timeout: .now() + 5) == .success else { fatalError("older discovery was not released") }
                _ = try domains.withSnapshot(snapshot) { try $0.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: []) }
            } } catch { results.error(error) }
        }
        guard olderEntered.wait(timeout: .now() + 5) == .success else { fatalError("older discovery did not start") }
        DispatchQueue.global().async {
            defer { newerDone.signal() }; newerRequested.signal()
            do { try domains.withDirectoryDiscovery(domain: "A", parentIdentifier: CloudMountItemIdentifier.root) { snapshot in
                newerEntered.signal()
                let discovered = try domains.withSnapshot(snapshot) { try $0.reconcile(domain: "A", parentIdentifier: CloudMountItemIdentifier.root, entries: [discoveredDirectory])[0] }
                let child = CloudMountMetadata(path: "discovered/child.bin", filename: "child.bin", isDirectory: false, size: 1, modificationTime: nil, backendID: nil, version: "")
                let descendant = try domains.withSnapshot(snapshot) { try $0.reconcile(domain: "A", parentIdentifier: discovered.itemIdentifier, entries: [child])[0] }
                results.items([discovered, descendant])
            } } catch { results.error(error) }
        }
        guard newerRequested.wait(timeout: .now() + 5) == .success else { fatalError("newer discovery did not start") }
        guard newerEntered.wait(timeout: .now() + 0.1) == .timedOut else { fatalError("same-directory backend observations overlapped") }
        // An unrelated directory may be discovered while the root observation waits.
        let unrelated = try domains.withDirectoryDiscovery(domain: "A", parentIdentifier: "unrelated") { _ in true }
        guard unrelated else { fatalError("unrelated discovery blocked") }
        releaseOlder.signal()
        guard olderDone.wait(timeout: .now() + 5) == .success && newerDone.wait(timeout: .now() + 5) == .success else { fatalError("overlapping discovery did not finish") }
        guard results.errors.isEmpty, results.values.count == 2 else { fatalError("ordered discovery failed") }
        for item in results.values {
            let record = try catalog.resolve(domain: "A", identifier: item.itemIdentifier)
            guard record.parentIdentifier == item.parentIdentifier else { fatalError("ordered discovery lost descendant/parent identity") }
        }
        print("DomainCatalog tests passed: mapping recovery, same-selector persistence, removal/recreation")
    }
}

private final class DiscoveryResults {
    private let lock = NSLock(); private var failures: [Error] = []; private var records: [CloudMountItemMetadata] = []
    func error(_ value: Error) { lock.lock(); defer { lock.unlock() }; failures.append(value) }
    func items(_ value: [CloudMountItemMetadata]) { lock.lock(); defer { lock.unlock() }; records = value }
    var errors: [Error] { lock.lock(); defer { lock.unlock() }; return failures }
    var values: [CloudMountItemMetadata] { lock.lock(); defer { lock.unlock() }; return records }
}
