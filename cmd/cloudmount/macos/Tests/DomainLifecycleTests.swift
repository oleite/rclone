import Foundation

@main enum DomainLifecycleTests {
    static func main() throws {
        if CommandLine.arguments.count == 4 {
            try probeRemoval(lockDirectory: URL(fileURLWithPath: CommandLine.arguments[2]),
                             identifier: CommandLine.arguments[3], busy: CommandLine.arguments[1] == "--busy")
            return
        }
        let ids = (0..<100).map { _ in CloudMountDomainIdentifier.make() }
        guard Set(ids).count == 100, ids.allSatisfy(CloudMountDomainIdentifier.isValid) else { fatalError("domain IDs collide or are not opaque canonical UUIDs") }
        for id in ["", "remote:", "org.rclone.cloudmount.domain.not-a-uuid", "org.rclone.cloudmount.domain.01234567-89AB-4CDE-8F01-23456789ABCD"] {
            guard !CloudMountDomainIdentifier.isValid(id) else { fatalError("malformed domain accepted") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DomainConfigurationStore(fileURL: directory.appendingPathComponent("domains.json"))
        var registered: [String: String] = [:]
        var failConfigure = false, failAdd = false, partialAdd = false, failDeregister = false, failInspect = false, failCleanup = false
        let lifecycle = DomainLifecycle(
            registeredIdentifiers: { if failInspect { throw Injected.failure }; return Array(registered.keys) },
            isConfigured: { try store.isConfigured(domainIdentifier: $0) },
            configure: { id, remote in try store.configure(domainIdentifier: id, remote: remote); if failConfigure { throw Injected.failure } },
            register: { id, name in if !failAdd || partialAdd { registered[id] = name }; if failAdd { throw Injected.failure } },
            deregister: { id in if failDeregister { throw Injected.failure }; registered.removeValue(forKey: id) },
            removeConfiguration: { id in if failCleanup { throw Injected.failure }; try store.remove(domainIdentifier: id) },
            lockDirectory: directory.appendingPathComponent("locks")
        )
        let a = try lifecycle.add(displayName: "Unicode café 日本", remote: "fixture-a:", identifier: ids[0])
        let b = try lifecycle.add(displayName: "Fixture B", remote: "fixture-b:", identifier: ids[1])
        let c = try lifecycle.add(displayName: "Fixture C", remote: "fixture-c:", identifier: ids[2])
        guard registered[a] == "Unicode café 日本", registered.count == 3,
              try DomainConfigurationStore(fileURL: directory.appendingPathComponent("domains.json")).remote(domainIdentifier: b) == "fixture-b:" else { fatalError("multiple domains/display names/reopen failed") }
        expectFailure { _ = try lifecycle.add(displayName: "replacement", remote: "wrong:", identifier: a) }
        guard try store.remote(domainIdentifier: a) == "fixture-a:", registered[a] == "Unicode café 日本" else { fatalError("duplicate add changed live mapping") }
        for name in ["", " ", "bad/name", "bad\\name", "bad\nname", String(repeating: "x", count: 256)] {
            expectFailure { _ = try lifecycle.add(displayName: name, remote: "fixture:", identifier: ids[3]) }
        }
        expectFailure { _ = try lifecycle.add(displayName: "valid", remote: "", identifier: ids[3]) }
        expectFailure { _ = try lifecycle.add(displayName: "valid", remote: "fixture:", identifier: "invalid") }
        guard registered.count == 3, try !store.isConfigured(domainIdentifier: ids[3]) else { fatalError("invalid input changed authorities") }
        failConfigure = true
        expectFailure { _ = try lifecycle.add(displayName: "failure", remote: "fixture:", identifier: ids[3]) }
        failConfigure = false
        guard try !store.isConfigured(domainIdentifier: ids[3]) else { fatalError("partial configure survived rollback") }
        failAdd = true
        expectFailure { _ = try lifecycle.add(displayName: "failure", remote: "fixture:", identifier: ids[3]) }
        guard try !store.isConfigured(domainIdentifier: ids[3]) else { fatalError("failed registration survived rollback") }
        partialAdd = true
        expectFailure { _ = try lifecycle.add(displayName: "failure", remote: "fixture:", identifier: ids[3]) }
        guard registered[ids[3]] == nil, try !store.isConfigured(domainIdentifier: ids[3]) else { fatalError("partial registration left live orphan") }
        failDeregister = true
        expectFailure { _ = try lifecycle.add(displayName: "failure", remote: "fixture:", identifier: ids[3]) }
        guard registered[ids[3]] != nil, try store.isConfigured(domainIdentifier: ids[3]) else { fatalError("failed rollback orphaned registered domain") }
        failAdd = false; partialAdd = false
        expectFailure { try lifecycle.remove(identifier: ids[3]) }
        guard registered[ids[3]] != nil, try store.isConfigured(domainIdentifier: ids[3]) else { fatalError("failed removal purged mapping") }
        failDeregister = false; failCleanup = true
        expectFailure { try lifecycle.remove(identifier: ids[3]) }
        guard registered[ids[3]] == nil, try store.isConfigured(domainIdentifier: ids[3]) else { fatalError("cleanup failure not retained for retry") }
        failCleanup = false
        try lifecycle.remove(identifier: ids[3])
        expectFailure { try lifecycle.remove(identifier: ids[3]) }
        expectFailure { try lifecycle.remove(identifier: "malformed") }
        try lifecycle.remove(identifier: a)
        guard registered.count == 2, registered[b] != nil, registered[c] != nil,
              try !store.isConfigured(domainIdentifier: a), try store.remote(domainIdentifier: b) == "fixture-b:" else { fatalError("removal crossed domains") }
        // Registry uncertainty must retain the newly configured mapping.
        failAdd = true; failInspect = false
        let uncertain = DomainLifecycle(registeredIdentifiers: { if failInspect { throw Injected.failure }; return Array(registered.keys) },
            isConfigured: { try store.isConfigured(domainIdentifier: $0) }, configure: { try store.configure(domainIdentifier: $0, remote: $1) },
            register: { _, _ in failInspect = true; throw Injected.failure }, deregister: { registered.removeValue(forKey: $0) },
            removeConfiguration: { try store.remove(domainIdentifier: $0) }, lockDirectory: directory.appendingPathComponent("locks"))
        expectFailure { _ = try uncertain.add(displayName: "uncertain", remote: "fixture:", identifier: ids[4]) }
        guard try store.isConfigured(domainIdentifier: ids[4]) else { fatalError("uncertain registry state lost mapping") }
        // Removal during pending registration must not purge the configured mapping.
        var overlapping: DomainLifecycle!
        overlapping = DomainLifecycle(registeredIdentifiers: { Array(registered.keys) },
            isConfigured: { try store.isConfigured(domainIdentifier: $0) },
            configure: { try store.configure(domainIdentifier: $0, remote: $1) },
            register: { id, name in
                expectError(.busy) { try overlapping.remove(identifier: id) }
                // A different executable process contends while registration is stalled.
                try runRemovalProbe(directory: directory.appendingPathComponent("locks"), identifier: id, busy: true)
                try runRemovalProbe(directory: directory.appendingPathComponent("locks"), identifier: ids[6], busy: false)
                registered[id] = name
            }, deregister: { registered.removeValue(forKey: $0) },
            removeConfiguration: { try store.remove(domainIdentifier: $0) }, lockDirectory: directory.appendingPathComponent("locks"))
        _ = try overlapping.add(displayName: "overlap", remote: "fixture:", identifier: ids[5])
        guard registered[ids[5]] != nil, try store.isConfigured(domainIdentifier: ids[5]) else {
            fatalError("overlapping add/remove orphaned a registered domain")
        }
        try runRemovalProbe(directory: directory.appendingPathComponent("locks"), identifier: ids[5], busy: false)
        guard String(describing: DomainLifecycleError.rollbackIncomplete).contains("retry removal using the domain ID") else {
            fatalError("CLI lifecycle error loses recovery guidance")
        }
        print("DomainLifecycle tests passed: opaque IDs, names, rollback, isolated cleanup, cross-process add/remove guard and release")
    }
    private static func runRemovalProbe(directory: URL, identifier: String, busy: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [busy ? "--busy" : "--free", directory.path, identifier]
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { fatalError("cross-process lifecycle probe failed") }
    }
    private static func probeRemoval(lockDirectory: URL, identifier: String, busy: Bool) throws {
        var operations: [String] = []
        let lifecycle = DomainLifecycle(registeredIdentifiers: { operations.append("inspect"); return [identifier] },
            isConfigured: { _ in true }, configure: { _, _ in fatalError("unexpected configure") },
            register: { _, _ in fatalError("unexpected register") },
            deregister: { _ in operations.append("deregister") },
            removeConfiguration: { _ in operations.append("cleanup") }, lockDirectory: lockDirectory)
        if busy {
            expectError(.busy) { try lifecycle.remove(identifier: identifier) }
            guard operations.isEmpty else { fatalError("busy lifecycle touched authorities") }
        } else {
            try lifecycle.remove(identifier: identifier)
            guard operations == ["inspect", "deregister", "cleanup"] else { fatalError("cleanup ordering changed") }
        }
    }
    private static func expectFailure(_ action: () throws -> Void) { do { try action(); fatalError("expected lifecycle failure") } catch {} }
    private static func expectError(_ expected: DomainLifecycleError, _ action: () throws -> Void) {
        do { try action(); fatalError("expected lifecycle error") }
        catch let error as DomainLifecycleError { guard error == expected else { fatalError("wrong lifecycle error") } }
        catch { fatalError("unexpected error category") }
    }
    private enum Injected: Error { case failure }
}
