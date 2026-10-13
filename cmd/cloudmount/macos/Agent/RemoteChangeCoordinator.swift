import Foundation
import os

private let syncLogger = Logger(subsystem: "org.rclone.cloudmount", category: "remote-sync")

struct CloudMountRemoteHint: Decodable {
    let path: String?
    let isDirectory: Bool
    let rescan: Bool
}

struct CloudMountWatchDriver {
    let start: (String, Int) throws -> UInt64?
    let next: (UInt64) throws -> [CloudMountRemoteHint]
    let stop: (UInt64) -> Void
    static let unsupported = CloudMountWatchDriver(start: { _, _ in nil }, next: { _ in [] }, stop: { _ in })
}

struct CloudMountSyncSettings {
    var hintInterval = 60
    var safetyInterval: TimeInterval = 300
    var debounce: TimeInterval = 1
    var tick: TimeInterval = 1
    var retry: TimeInterval = 10
    var maximumRetry: TimeInterval = 300
}

/// A coordinator owns one binding generation. Only its serial worker performs
/// scans. Durable publication has an independent queue, so stalled backend I/O
/// cannot postpone its startup wake or retry. Stop releases the watch immediately.
final class RemoteChangeCoordinator {
    private let snapshot: DomainCatalog.Snapshot
    private let catalog: DomainCatalog
    private let driver: CloudMountWatchDriver
    private let settings: CloudMountSyncSettings
    private let list: (String, String) throws -> [CloudMountMetadata]
    private let signal: (String, Int64) throws -> Void
    private let worker: DispatchQueue
    private let publisher: DispatchQueue
    private let lock = NSLock()
    private var stopped = false; private var started = false
    private var handle: UInt64?
    private var timer: DispatchSourceTimer?
    private var publicationTimer: DispatchSourceTimer?
    // Fields below are owned exclusively by worker.
    private var pending = Set<String>()
    private var scanAll = true
    private var flushAt: TimeInterval?
    private var nextSafety: TimeInterval = 0
    private struct Retry { let at: TimeInterval; let delay: TimeInterval }
    private var retries: [String: Retry] = [:]
    private var watchRetry: Retry?
    // Fields below are owned exclusively by publisher.
    private var signalRetry: Retry?
    private var signaledRevision: Int64 = -1

    init(snapshot: DomainCatalog.Snapshot, catalog: DomainCatalog, driver: CloudMountWatchDriver,
         settings: CloudMountSyncSettings = CloudMountSyncSettings(),
         list: @escaping (String, String) throws -> [CloudMountMetadata],
         signal: @escaping (String, Int64) throws -> Void) {
        self.snapshot = snapshot; self.catalog = catalog; self.driver = driver; self.settings = settings
        self.list = list; self.signal = signal
        worker = DispatchQueue(label: "org.rclone.cloudmount.sync.\(snapshot.domain)")
        publisher = DispatchQueue(label: "org.rclone.cloudmount.publish.\(snapshot.domain)")
    }
    deinit { stop() }

    private var active: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    private var watchHandle: UInt64? { lock.lock(); defer { lock.unlock() }; return handle }
    func start() {
        lock.lock(); guard !started, !stopped else { lock.unlock(); return }; started = true; lock.unlock()
        publisher.async { [self] in
            self.publish()
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.publisher)
            timer.schedule(deadline: .now() + self.settings.tick, repeating: max(0.01, self.settings.tick))
            timer.setEventHandler { [weak self] in self?.publish() }
            self.publicationTimer = timer; timer.resume()
        }
        worker.async { [self] in
            guard self.active else { return }
            self.startWatch()
            guard self.active else { return }
            let now = Date().timeIntervalSince1970
            self.flushAt = now; self.nextSafety = now + self.settings.safetyInterval
            self.tick()
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now() + self.settings.tick, repeating: max(0.01, self.settings.tick))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        lock.lock(); stopped = true
        let handle = self.handle; self.handle = nil
        let timer = self.timer; self.timer = nil
        let publicationTimer = self.publicationTimer; self.publicationTimer = nil; lock.unlock()
        timer?.cancel(); publicationTimer?.cancel()
        if let handle { driver.stop(handle) }
    }
    private func releaseWatch(_ expected: UInt64) {
        lock.lock(); let owned = handle == expected; if owned { handle = nil }; lock.unlock()
        if owned { driver.stop(expected) }
    }
    private func retry(after previous: Retry?, now: TimeInterval) -> Retry {
        let delay = min(settings.maximumRetry, max(settings.retry, previous.map { $0.delay * 2 } ?? settings.retry))
        return Retry(at: now + delay, delay: delay)
    }
    private func startWatch() {
        do {
            let created = try driver.start(snapshot.remote, settings.hintInterval)
            lock.lock()
            if stopped { lock.unlock(); if let created { driver.stop(created) }; return }
            handle = created; lock.unlock(); watchRetry = nil
            syncLogger.notice("watch started domain=\(self.snapshot.domain, privacy: .public) supported=\(created != nil)")
        } catch {
            watchRetry = retry(after: watchRetry, now: Date().timeIntervalSince1970)
            syncLogger.error("watch startup failed domain=\(self.snapshot.domain, privacy: .public); safety reconciliation retained")
        }
    }
    private func directories() throws -> [(identifier: String, path: String)] {
        try catalog.withSnapshot(snapshot) { items in
            try items.authoritativeDirectories(domain: snapshot.domain).map { identifier in
                (identifier, identifier == CloudMountItemIdentifier.root ? "" : try items.resolve(domain: snapshot.domain, identifier: identifier).path)
            }.sorted { lhs, rhs in lhs.path.split(separator: "/").count < rhs.path.split(separator: "/").count }
        }
    }
    private func tick() {
        guard active else { return }
        let now = Date().timeIntervalSince1970
        do {
            let known = try directories()
            if let watchRetry, watchRetry.at <= now { startWatch() }
            if let handle = watchHandle {
                do {
                    let hints = try driver.next(handle)
                    if !hints.isEmpty { syncLogger.notice("watch hints domain=\(self.snapshot.domain, privacy: .public) count=\(hints.count)") }
                    for hint in hints {
                        guard !hint.rescan, let path = hint.path, !path.isEmpty else { scanAll = true; continue }
                        let parent = (path as NSString).deletingLastPathComponent
                        for directory in known {
                            if directory.path.utf8.elementsEqual(parent.utf8) ||
                                (hint.isDirectory && (directory.path.utf8.elementsEqual(path.utf8) || directory.path.utf8.starts(with: (path + "/").utf8))) {
                                pending.insert(directory.identifier)
                            }
                        }
                    }
                    if !hints.isEmpty, flushAt == nil { flushAt = now + settings.debounce }
                } catch {
                    releaseWatch(handle); watchRetry = retry(after: watchRetry, now: now)
                    syncLogger.error("watch failed domain=\(self.snapshot.domain, privacy: .public); retry scheduled")
                }
            }
            if now >= nextSafety {
                scanAll = true; flushAt = now; nextSafety = now + settings.safetyInterval
                syncLogger.notice("safety reconciliation domain=\(self.snapshot.domain, privacy: .public) containers=\(known.count)")
            }
            let identifiers = Set(known.map(\.identifier))
            retries = retries.filter { identifiers.contains($0.key) }
            var due = Set(retries.filter { $0.value.at <= now }.keys)
            if let deadline = flushAt, deadline <= now {
                due.formUnion(scanAll ? identifiers : pending)
                pending.removeAll(); scanAll = false; flushAt = nil
            }
            for directory in known where due.contains(directory.identifier) && (retries[directory.identifier]?.at ?? 0) <= now {
                guard active else { return }
                do {
                    let revision = try catalog.withDirectoryDiscovery(domain: snapshot.domain, parentIdentifier: directory.identifier) { _ in
                        let path = try catalog.withSnapshot(snapshot) { items in
                            directory.identifier == CloudMountItemIdentifier.root ? "" : try items.resolve(domain: snapshot.domain, identifier: directory.identifier).path
                        }
                        let entries = try list(snapshot.remote, path)
                        guard active else { throw ItemCatalogError.noSuchItem }
                        return try catalog.withSnapshot(snapshot) { items in
                            _ = try items.reconcile(domain: snapshot.domain, parentIdentifier: directory.identifier, entries: entries)
                            return try items.revision(domain: snapshot.domain)
                        }
                    }
                    retries.removeValue(forKey: directory.identifier)
                    syncLogger.notice("authoritative reconciliation committed domain=\(self.snapshot.domain, privacy: .public) container=\(directory.identifier, privacy: .public) revision=\(revision)")
                } catch {
                    retries[directory.identifier] = retry(after: retries[directory.identifier], now: now)
                    syncLogger.error("authoritative reconciliation failed domain=\(self.snapshot.domain, privacy: .public); previous state retained")
                }
            }
        } catch ItemCatalogError.noSuchItem { stop() }
        catch {
            scanAll = true; flushAt = now + settings.retry
            syncLogger.error("sync state unavailable domain=\(self.snapshot.domain, privacy: .public); retry scheduled")
        }
    }
    private func publish() {
        guard active else { return }
        let now = Date().timeIntervalSince1970
        guard (signalRetry?.at ?? 0) <= now else { return }
        do {
            let revision = try catalog.withSnapshot(snapshot) { try $0.revision(domain: snapshot.domain) }
            guard active, revision > signaledRevision else { return }
            try signal(snapshot.domain, revision)
            if active { signaledRevision = revision; signalRetry = nil }
        } catch ItemCatalogError.noSuchItem { stop() }
        catch {
            signalRetry = retry(after: signalRetry, now: now)
            syncLogger.error("working set signal failed domain=\(self.snapshot.domain, privacy: .public); durable revision retained")
        }
    }
}
