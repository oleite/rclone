import Foundation

@main enum RemoteChangeCoordinatorTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func wait(_ semaphore: DispatchSemaphore, _ message: String) { require(semaphore.wait(timeout: .now() + 3) == .success, message) }
    static func entry(_ size: Int64) -> CloudMountMetadata {
        CloudMountMetadata(path: "fixture.txt", filename: "fixture.txt", isDirectory: false, size: size,
                           modificationTime: "2026-10-13T12:00:00Z", backendID: nil, version: "")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try ItemCatalog(fileURL: root.appendingPathComponent("catalog.sqlite3"))
        let configuration = DomainConfigurationStore(fileURL: root.appendingPathComponent("domains.json"))
        let catalog = DomainCatalog(configuration: configuration, catalog: items)
        try catalog.configure(domain: "A", remote: "fixture-a:")
        try catalog.configure(domain: "B", remote: "fixture-b:")
        let parent = CloudMountItemIdentifier.root
        let original = try items.reconcile(domain: "A", parentIdentifier: parent, entries: [entry(10)])[0]
        _ = try items.reconcile(domain: "B", parentIdentifier: parent, entries: [entry(10)])
        let remote = FixtureRemote()
        let driver = CloudMountWatchDriver(start: { _, _ in 1 }, next: { _ in remote.hints() }, stop: { _ in remote.stopped() })
        let settings = CloudMountSyncSettings(hintInterval: 1, safetyInterval: 1000, debounce: 0.03, tick: 0.01, retry: 0.03, maximumRetry: 0.1)
        // Durable publication must not depend on any remote operation finishing.
        let constructing = DispatchSemaphore(value: 0), constructed = DispatchSemaphore(value: 0)
        let durable = DispatchSemaphore(value: 0)
        let restart = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "A"), catalog: catalog,
            driver: CloudMountWatchDriver(start: { _, _ in constructing.signal(); constructed.wait(); return nil }, next: { _ in [] }, stop: { _ in }),
            settings: settings, list: { _, _ in [entry(10)] }, signal: { _, _ in durable.signal() })
        restart.start(); wait(constructing, "watch construction not suspended")
        let publishedWhileConstructing = durable.wait(timeout: .now() + 1) == .success
        restart.stop(); constructed.signal()

        let listBlocked = DispatchSemaphore(value: 0), listRelease = DispatchSemaphore(value: 0)
        let signalFailure = DispatchSemaphore(value: 0), signalRetried = DispatchSemaphore(value: 0)
        let attempts = SignalAttempts()
        let retrying = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "A"), catalog: catalog,
            driver: .unsupported, settings: settings,
            list: { _, _ in listBlocked.signal(); listRelease.wait(); return [entry(10)] },
            signal: { _, _ in
                if attempts.next() == 1 { signalFailure.signal(); throw TestFailure.injected }
                signalRetried.signal()
            })
        retrying.start(); wait(listBlocked, "listing not suspended")
        let failedWhileListing = signalFailure.wait(timeout: .now() + 1) == .success
        let retriedWhileListing = signalRetried.wait(timeout: .now() + 1) == .success
        retrying.stop(); listRelease.signal()
        FileHandle.standardError.write(Data("Independent publication: blocked constructor=\(publishedWhileConstructing), blocked listing retry=\(failedWhileListing && retriedWhileListing)\n".utf8))
        require(publishedWhileConstructing, "durable startup signal blocked by watch construction")
        require(failedWhileListing && retriedWhileListing, "durable signal retry blocked by remote listing")
        let coordinator = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "A"), catalog: catalog,
            driver: driver, settings: settings, list: { _, _ in try remote.list() }, signal: { _, _ in try remote.signal() })
        coordinator.start()
        wait(remote.signaled, "startup did not signal durable state")
        wait(remote.listed, "startup reconciliation not completed")
        let before = try items.currentAnchor(domain: "A")
        remote.change(size: 20, hints: 20)
        wait(remote.signaled, "coalesced hints did not converge")
        require(try items.resolve(domain: "A", identifier: original.itemIdentifier).metadata.size == 20, "hint did not reconcile actual backend metadata")
        require(try items.changes(domain: "A", container: parent, from: before, limit: 200).items.count == 1, "duplicate hints duplicated journal transitions")
        require(remote.calls == 2, "hint burst caused duplicate authoritative scans")
        require(try items.resolve(domain: "B", identifier: (items.workingSet(domain: "B", page: nil, limit: 1).items[0].itemIdentifier)).metadata.size == 10, "watch A changed B")
        remote.failLists()
        remote.change(size: 99, hints: 1)
        wait(remote.failed, "failed listing not attempted")
        require(try items.resolve(domain: "A", identifier: original.itemIdentifier).metadata.size == 20, "backend failure became deletion/update")
        remote.restoreLists()
        wait(remote.signaled, "failed listing did not retry")
        require(try items.resolve(domain: "A", identifier: original.itemIdentifier).metadata.size == 99, "retry did not refresh")
        remote.failSignalOnce()
        remote.change(size: 100, hints: 1)
        wait(remote.signalFailed, "signal failure not exercised")
        wait(remote.signaled, "committed journal not re-signaled")
        require(try items.resolve(domain: "A", identifier: original.itemIdentifier).metadata.size == 100, "signal failure rolled back committed metadata")
        coordinator.stop()
        require(remote.stopCount == 1, "watch not released")
        coordinator.stop()
        require(remote.stopCount == 1, "watch Stop not idempotent")

        // A suspended backend must not block B; a removed generation must not commit late.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), bReady = DispatchSemaphore(value: 0)
        let blocked = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "A"), catalog: catalog,
            driver: .unsupported, settings: settings,
            list: { _, _ in entered.signal(); release.wait(); return [] }, signal: { _, _ in })
        blocked.start(); wait(entered, "A scan not entered")
        let independent = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "B"), catalog: catalog,
            driver: .unsupported, settings: settings, list: { _, _ in [entry(11)] }, signal: { _, _ in bReady.signal() })
        independent.start(); wait(bReady, "A blocked B")
        try catalog.remove(domain: "A"); blocked.stop(); release.signal(); independent.stop()
        require(try !configuration.isConfigured(domainIdentifier: "A"), "late scan restored removed mapping")

        let remapEntered = DispatchSemaphore(value: 0), remapResume = DispatchSemaphore(value: 0), remapStopped = DispatchSemaphore(value: 0)
        let oldBinding = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "B"), catalog: catalog,
            driver: CloudMountWatchDriver(start: { _, _ in 3 }, next: { _ in [] }, stop: { _ in remapStopped.signal() }), settings: settings,
            list: { _, _ in remapEntered.signal(); remapResume.wait(); return [] }, signal: { _, _ in })
        oldBinding.start(); wait(remapEntered, "old binding scan did not enter")
        try catalog.configure(domain: "B", remote: "new-binding:")
        let replacement = try items.reconcile(domain: "B", parentIdentifier: parent, entries: [entry(47)])[0]
        remapResume.signal(); wait(remapStopped, "retired generation did not stop watch")
        require(try items.resolve(domain: "B", identifier: replacement.itemIdentifier).metadata.size == 47, "stale empty scan retired replacement state")

        // Stop may race a slow watch constructor; its eventual handle must be released.
        let starting = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let late = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "B"), catalog: catalog,
            driver: CloudMountWatchDriver(start: { _, _ in starting.signal(); resume.wait(); return 2 }, next: { _ in [] }, stop: { _ in released.signal() }),
            settings: settings, list: { _, _ in fatalError("stopped constructor scanned") }, signal: { _, _ in })
        late.start(); wait(starting, "watch constructor not started"); late.stop(); resume.signal(); wait(released, "late watch handle leaked")

        // Without ChangeNotify, startup and periodic authoritative safety scans suffice.
        _ = try items.reconcile(domain: "B", parentIdentifier: parent, entries: [entry(10)])
        let polling = FixtureRemote()
        let poller = RemoteChangeCoordinator(snapshot: try catalog.snapshot(domain: "B"), catalog: catalog,
            driver: .unsupported, settings: CloudMountSyncSettings(hintInterval: 1, safetyInterval: 0.06, debounce: 0.02, tick: 0.01, retry: 0.02, maximumRetry: 0.1),
            list: { _, _ in try polling.list() }, signal: { _, _ in try polling.signal() })
        poller.start(); wait(polling.signaled, "unsupported watcher startup failed")
        wait(polling.listed, "polling startup reconciliation not completed")
        polling.change(size: 77, hints: 0); wait(polling.signaled, "safety reconciliation did not converge")
        poller.stop()
        print("Remote coordinator tests passed: coalescing, catch-up/safety, failures/retry, signaling, independent domains, stale scans/start, stop")
    }
}

private enum TestFailure: Error { case injected }
private final class SignalAttempts {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

private final class FixtureRemote {
    private let lock = NSLock(); private var size: Int64 = 10; private var pending = 0
    private var listFailure = false; private var signalFailure = false; private var listings = 0; private var stops = 0
    let signaled = DispatchSemaphore(value: 0), failed = DispatchSemaphore(value: 0), signalFailed = DispatchSemaphore(value: 0), listed = DispatchSemaphore(value: 0)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return listings }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func stopped() { lock.lock(); stops += 1; lock.unlock() }
    func change(size: Int64, hints: Int) { lock.lock(); self.size = size; pending += hints; lock.unlock() }
    func hints() -> [CloudMountRemoteHint] { lock.lock(); defer { lock.unlock() }; let count = pending; pending = 0; return (0..<count).map { _ in CloudMountRemoteHint(path: "fixture.txt", isDirectory: false, rescan: false) } }
    func list() throws -> [CloudMountMetadata] {
        lock.lock(); defer { lock.unlock() }; listings += 1
        if listFailure { failed.signal(); throw Failure.injected }
        listed.signal()
        return [RemoteChangeCoordinatorTests.entry(size)]
    }
    func signal() throws { lock.lock(); defer { lock.unlock() }; if signalFailure { signalFailure = false; signalFailed.signal(); throw Failure.injected }; signaled.signal() }
    func failLists() { lock.lock(); listFailure = true; lock.unlock() }
    func restoreLists() { lock.lock(); listFailure = false; lock.unlock() }
    func failSignalOnce() { lock.lock(); signalFailure = true; lock.unlock() }
    private enum Failure: Error { case injected }
}
