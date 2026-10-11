import Foundation

/// DomainCatalog checks mapping/catalog bindings before any DATA resolution.
/// Backend I/O runs outside its lock; snapshot validation rejects stale completions.
final class DomainCatalog {
    struct Snapshot {
        let domain: String
        let remote: String
        fileprivate let generation: UUID
    }

    private let catalog: ItemCatalog
    private let configuration: DomainConfigurationStore
    private let lock = NSLock()
    private var generations: [String: UUID] = [:]
    private struct DirectoryKey: Hashable { let domain: String; let parent: String; let generation: UUID }
    private final class DiscoveryGate { let lock = NSLock(); var users = 0 }
    private var discoveries: [DirectoryKey: DiscoveryGate] = [:]

    init(configuration: DomainConfigurationStore, catalog: ItemCatalog) {
        self.configuration = configuration
        self.catalog = catalog
    }

    func configure(domain: String, remote: String) throws {
        lock.lock(); defer { lock.unlock() }
        try configuration.configure(domainIdentifier: domain, remote: remote)
        _ = try snapshotUnlocked(domain: domain)
    }

    func remove(domain: String) throws {
        lock.lock(); defer { lock.unlock() }
        // An interrupted removal can leave a mapping, but never old catalog IDs.
        try catalog.purge(domain: domain)
        generations.removeValue(forKey: domain)
        try configuration.remove(domainIdentifier: domain)
    }

    func snapshot(domain: String) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return try snapshotUnlocked(domain: domain)
    }

    /// Serialize observation and reconciliation of one directory, not other I/O.
    /// Gates belong to the binding generation and disappear after the last caller.
    func withDirectoryDiscovery<T>(domain: String, parentIdentifier: String, _ action: (Snapshot) throws -> T) throws -> T {
        let snapshot = try self.snapshot(domain: domain)
        let key = DirectoryKey(domain: domain, parent: parentIdentifier, generation: snapshot.generation)
        lock.lock()
        let gate = discoveries[key] ?? DiscoveryGate()
        discoveries[key] = gate; gate.users += 1
        lock.unlock()
        gate.lock.lock()
        defer {
            gate.lock.unlock()
            lock.lock(); gate.users -= 1
            if gate.users == 0 { discoveries.removeValue(forKey: key) }
            lock.unlock()
        }
        _ = try withSnapshot(snapshot) { _ in true }
        return try action(snapshot)
    }

    /// withSnapshot validates the mapping and commits catalog work under the same lock.
    func withSnapshot<T>(_ snapshot: Snapshot, _ action: (ItemCatalog) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let current = try snapshotUnlocked(domain: snapshot.domain)
        guard current.generation == snapshot.generation else { throw ItemCatalogError.noSuchItem }
        return try action(catalog)
    }

    private func snapshotUnlocked(domain: String) throws -> Snapshot {
        let remote: String
        do { remote = try configuration.remote(domainIdentifier: domain) }
        catch DomainConfigurationStoreError.domainNotConfigured { throw ItemCatalogError.noSuchItem }
        // Recover a crash between the JSON mutation and SQLite transaction.
        let changed = try catalog.bind(domain: domain, remote: remote)
        if changed || generations[domain] == nil { generations[domain] = UUID() }
        return Snapshot(domain: domain, remote: remote, generation: generations[domain]!)
    }
}
