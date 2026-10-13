import FileProvider
import Foundation
import os

private let serviceLogger = Logger(subsystem: "org.rclone.cloudmount", category: "remote-sync")
private enum RemoteSyncError: Error { case backend, signaling }
private struct WatchResponse: Decodable {
    let ok: Bool; let supported: Bool; let handle: UInt64?; let event: CloudMountRemoteHint?; let received: UInt64?
}

/// The Agent owns watcher lifetime and the related-executable File Provider manager.
final class CloudMountRemoteSync {
    private let catalog: DomainCatalog
    private let configuration: DomainConfigurationStore
    private let queue = DispatchQueue(label: "org.rclone.cloudmount.sync-lifecycle")
    private struct Entry { let snapshot: DomainCatalog.Snapshot; let coordinator: RemoteChangeCoordinator }
    private var coordinators: [String: Entry] = [:]
    private var stopped = false

    init(catalog: DomainCatalog, configuration: DomainConfigurationStore) { self.catalog = catalog; self.configuration = configuration }
    func restore() {
        do { for domain in try configuration.domainIdentifiers() { refresh(domain: domain) } }
        catch { serviceLogger.error("unable to restore configured sync domains") }
    }
    func refresh(domain: String) {
        queue.async {
            guard !self.stopped else { return }
            do {
                let snapshot = try self.catalog.snapshot(domain: domain)
                if let existing = self.coordinators[domain], (try? self.catalog.withSnapshot(existing.snapshot) { _ in true }) == true { return }
                self.coordinators.removeValue(forKey: domain)?.coordinator.stop()
                let settings = Self.settings()
                let coordinator = RemoteChangeCoordinator(snapshot: snapshot, catalog: self.catalog, driver: Self.driver(domain: domain), settings: settings,
                    list: Self.list, signal: Self.signal)
                self.coordinators[domain] = Entry(snapshot: snapshot, coordinator: coordinator)
                coordinator.start()
            } catch { self.coordinators.removeValue(forKey: domain)?.coordinator.stop() }
        }
    }
    func stop(domain: String) { queue.sync { coordinators.removeValue(forKey: domain)?.coordinator.stop() } }
    func stopAll() { queue.sync { stopped = true; for entry in coordinators.values { entry.coordinator.stop() }; coordinators.removeAll() } }

    private static func settings() -> CloudMountSyncSettings {
        var result = CloudMountSyncSettings()
        if let value = Bundle.main.object(forInfoDictionaryKey: "CloudMountSyncHintInterval") as? String, let seconds = Int(value), (1...3600).contains(seconds) { result.hintInterval = seconds }
        if let value = Bundle.main.object(forInfoDictionaryKey: "CloudMountSyncSafetyInterval") as? String, let seconds = Double(value), seconds >= 5, seconds <= 3600 { result.safetyInterval = seconds }
        return result
    }
    private static func decode<Value: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: Value.Type) throws -> Value {
        guard let pointer else { throw RemoteSyncError.backend }
        defer { RcloneCloudMountFreeString(pointer) }
        return try JSONDecoder().decode(type, from: Data(String(cString: pointer).utf8))
    }
    private static func driver(domain: String) -> CloudMountWatchDriver {
        var previousCount: UInt64 = 0
        return CloudMountWatchDriver(start: { remote, interval in
            let value = try remote.withCString { try decode(RcloneCloudMountWatchStart($0, Int32(interval)), as: WatchResponse.self) }
            guard value.ok else { throw RemoteSyncError.backend }
            previousCount = 0
            return value.supported ? value.handle : nil
        }, next: { handle in
            var hints: [CloudMountRemoteHint] = []
            var received = previousCount
            for _ in 0..<128 {
                let value = try decode(RcloneCloudMountWatchNext(handle, 0), as: WatchResponse.self)
                guard value.ok else { throw RemoteSyncError.backend }
                received = value.received ?? received
                guard let event = value.event else { break }
                hints.append(event)
            }
            if received > previousCount { serviceLogger.notice("raw watch hints domain=\(domain, privacy: .public) count=\(received - previousCount)") }
            previousCount = received
            return hints
        }, stop: { RcloneCloudMountWatchStop($0) })
    }
    private static func list(remote: String, path: String) throws -> [CloudMountMetadata] {
        let response = try remote.withCString { r in try path.withCString { p in try decode(RcloneCloudMountList(r, p), as: CloudMountBridgeResponse.self) } }
        guard response.ok else { throw RemoteSyncError.backend }
        return response.items ?? []
    }
    private static func signal(domain: String, revision: Int64) throws {
        let group = DispatchGroup(); group.enter()
        var result: Error?
        // Completion-owned storage is synchronized by DispatchGroup, not a run loop hack.
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            guard error == nil, let value = domains.first(where: { $0.identifier.rawValue == domain }), let manager = NSFileProviderManager(for: value) else {
                result = error ?? RemoteSyncError.signaling; group.leave(); return
            }
            manager.signalEnumerator(for: .workingSet) { error in result = error; group.leave() }
        }
        guard group.wait(timeout: .now() + 10) == .success else { throw RemoteSyncError.signaling }
        if let result { serviceLogger.error("working set signal error domain=\(domain, privacy: .public) code=\((result as NSError).code)"); throw result }
        serviceLogger.notice("working set signaled domain=\(domain, privacy: .public) revision=\(revision)")
    }
}
