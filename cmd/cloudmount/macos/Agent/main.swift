import Foundation
import os

private let logger = Logger(subsystem: "org.rclone.cloudmount", category: "agent")
private let backendQueue = DispatchQueue(label: "org.rclone.cloudmount.backend", attributes: .concurrent)
private let configurationStore: DomainConfigurationStore = {
    do { return try DomainConfigurationStore.applicationSupportStore() }
    catch { fatalError("unable to locate CloudMount configuration store: \(error.localizedDescription)") }
}()

private let domainCatalog: DomainCatalog = {
    do { return DomainCatalog(configuration: configurationStore, catalog: try ItemCatalog.applicationSupportCatalog()) }
    catch { fatalError("unable to open CloudMount item catalog") }
}()

private func infoString(_ key: String) -> String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
        fatalError("\(key) is missing from Info.plist")
    }
    return value
}

private func requirementString(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private let controlPeerCodeSigningRequirement: String = {
    let teamID = requirementString(infoString("CloudMountTeamIdentifier"))
    let appID = requirementString(infoString("CloudMountAppBundleIdentifier"))
    return "anchor apple generic and certificate leaf[subject.OU] = \(teamID) and identifier \(appID)"
}()

private let dataPeerCodeSigningRequirement: String = {
    let teamID = requirementString(infoString("CloudMountTeamIdentifier"))
    let providerID = requirementString(infoString("CloudMountFileProviderBundleIdentifier"))
    return "anchor apple generic and certificate leaf[subject.OU] = \(teamID) and identifier \(providerID)"
}()

private func stringResult(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return #"{"ok":false,"error":{"code":"internal_error","message":"bridge returned no response"}}"# }
    defer { RcloneCloudMountFreeString(pointer) }
    return String(cString: pointer)
}

private func sanitizedResult(_ result: String) -> String {
    guard let data = result.data(using: .utf8),
          let response = try? JSONDecoder().decode(CloudMountBridgeResponse.self, from: data),
          !response.ok else { return result }
    let code = response.error?.code ?? "backend_error"
    let message: String
    switch code {
    case "not_found": message = "item not found"
    case "cancelled": message = "transfer cancelled"
    case "invalid_range": message = "invalid byte range"
    case "short_full_read": message = "incomplete file content"
    case "short_range_read": message = "incomplete byte range"
    default: message = "backend operation failed"
    }
    let sanitized = CloudMountBridgeResponse(ok: false, items: nil, item: nil, error: CloudMountBridgeError(code: code, message: message))
    guard let encoded = try? JSONEncoder().encode(sanitized) else {
        return #"{"ok":false,"error":{"code":"internal_error","message":"backend operation failed"}}"#
    }
    return String(decoding: encoded, as: UTF8.self)
}

private final class FetchOperations {
    private let lock = NSLock()
    private var transfers: [String: UInt64] = [:]
    private func key(_ domainIdentifier: String, _ operationIdentifier: String) -> String { domainIdentifier + "\0" + operationIdentifier }

    func register(domainIdentifier: String, operationIdentifier: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        let operationKey = key(domainIdentifier, operationIdentifier)
        guard transfers[operationKey] == nil else { return nil }
        let transfer = RcloneCloudMountTransferCreate()
        transfers[operationKey] = transfer
        return transfer
    }

    func cancel(domainIdentifier: String, operationIdentifier: String) {
        lock.lock(); let transfer = transfers[key(domainIdentifier, operationIdentifier)]; lock.unlock()
        if let transfer { RcloneCloudMountTransferCancel(transfer) }
    }

    func release(domainIdentifier: String, operationIdentifier: String, transfer: UInt64) {
        lock.lock(); transfers.removeValue(forKey: key(domainIdentifier, operationIdentifier)); lock.unlock()
        RcloneCloudMountTransferRelease(transfer)
    }
}

private let fetchOperations = FetchOperations()

private final class ControlService: NSObject, CloudMountControlProtocol {
    func ping(reply: @escaping (String) -> Void) {
        logger.notice("received ping")
        reply("pong")
    }

    private func storeError(_ error: Error) -> NSError { error as NSError }

    func configureDomain(domainIdentifier: String, remote: String, reply: @escaping (NSError?) -> Void) {
        backendQueue.async {
            do { try domainCatalog.configure(domain: domainIdentifier, remote: remote); logger.notice("configured domain \(domainIdentifier, privacy: .public)"); reply(nil) }
            catch { logger.error("failed to configure domain \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .private)"); reply(self.storeError(error)) }
        }
    }

    func removeDomainConfiguration(domainIdentifier: String, reply: @escaping (NSError?) -> Void) {
        backendQueue.async {
            do { try domainCatalog.remove(domain: domainIdentifier); logger.notice("removed domain configuration \(domainIdentifier, privacy: .public)"); reply(nil) }
            catch { logger.error("failed to remove domain configuration \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .private)"); reply(self.storeError(error)) }
        }
    }

    func domainConfigurationStatus(domainIdentifier: String, reply: @escaping (Bool, NSError?) -> Void) {
        backendQueue.async {
            do { reply(try configurationStore.isConfigured(domainIdentifier: domainIdentifier), nil) }
            catch { reply(false, self.storeError(error)) }
        }
    }
}

private final class DataService: NSObject, CloudMountDataProtocol {
    private func storeError(_ error: Error) -> NSError {
        let missing = (error as? ItemCatalogError) == .noSuchItem
        return NSError(domain: "org.rclone.cloudmount", code: missing ? 404 : 2,
                       userInfo: [NSLocalizedDescriptionKey: missing ? "item not found" : "backend operation failed"])
    }

    private func itemResult(_ raw: String, transform: (CloudMountBridgeResponse) throws -> CloudMountItemResponse) throws -> String {
        let sanitized = sanitizedResult(raw)
        guard let data = sanitized.data(using: .utf8) else { throw ItemCatalogError.database }
        let response = try JSONDecoder().decode(CloudMountBridgeResponse.self, from: data)
        let result = response.ok ? try transform(response) : CloudMountItemResponse(ok: false, items: nil, item: nil, error: response.error)
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    func listDirectory(domainIdentifier: String, parentIdentifier: String, reply: @escaping (String?, NSError?) -> Void) {
        backendQueue.async {
            do {
                let result = try domainCatalog.withDirectoryDiscovery(domain: domainIdentifier, parentIdentifier: parentIdentifier) { snapshot in
                    let remote = snapshot.remote
                    let path: String
                    if parentIdentifier == CloudMountItemIdentifier.root { path = "" }
                    else {
                        let parent = try domainCatalog.withSnapshot(snapshot) { try $0.resolve(domain: domainIdentifier, identifier: parentIdentifier) }
                        guard parent.metadata.isDirectory else { throw ItemCatalogError.noSuchItem }
                        path = parent.path
                    }
                    logger.notice("Go-backed List domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private)")
                    let result = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountList(r, p)) } }
                    return try self.itemResult(result) { response in
                        let items = try domainCatalog.withSnapshot(snapshot) { try $0.reconcile(domain: domainIdentifier, parentIdentifier: parentIdentifier, entries: response.items ?? []) }
                        return CloudMountItemResponse(ok: true, items: items, item: nil, error: nil)
                    }
                }
                reply(result, nil)
            } catch { reply(nil, self.storeError(error)) }
        }
    }

    func statItem(domainIdentifier: String, itemIdentifier: String, reply: @escaping (String?, NSError?) -> Void) {
        backendQueue.async {
            do {
                let snapshot = try domainCatalog.snapshot(domain: domainIdentifier)
                let remote = snapshot.remote
                let record = try domainCatalog.withSnapshot(snapshot) { try $0.resolve(domain: domainIdentifier, identifier: itemIdentifier) }
                let path = record.path
                let isDirectory = record.metadata.isDirectory
                logger.notice("Go-backed Stat domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private) directory=\(isDirectory)")
                let result = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountStat(r, p, isDirectory ? 1 : 0)) } }
                reply(try self.itemResult(result) { response in
                    guard let entry = response.item else { throw ItemCatalogError.database }
                    let item = try domainCatalog.withSnapshot(snapshot) { try $0.update(domain: domainIdentifier, identifier: itemIdentifier, entry: entry) }
                    return CloudMountItemResponse(ok: true, items: nil, item: item, error: nil)
                }, nil)
            } catch { reply(nil, self.storeError(error)) }
        }
    }

    func fetchContents(
        domainIdentifier: String,
        itemIdentifier: String,
        operationIdentifier: String,
        fileHandle: FileHandle,
        reply: @escaping (NSError?) -> Void
    ) {
        guard let transfer = fetchOperations.register(domainIdentifier: domainIdentifier, operationIdentifier: operationIdentifier) else {
            reply(NSError(domain: "org.rclone.cloudmount", code: 3, userInfo: [NSLocalizedDescriptionKey: "duplicate fetch operation"])); return
        }
        backendQueue.async {
            defer { try? fileHandle.close(); fetchOperations.release(domainIdentifier: domainIdentifier, operationIdentifier: operationIdentifier, transfer: transfer) }
            let remote: String
            let snapshot: DomainCatalog.Snapshot
            let path: String
            do {
                snapshot = try domainCatalog.snapshot(domain: domainIdentifier)
                remote = snapshot.remote
                let record = try domainCatalog.withSnapshot(snapshot) { try $0.resolve(domain: domainIdentifier, identifier: itemIdentifier) }
                guard !record.metadata.isDirectory else { throw ItemCatalogError.noSuchItem }
                path = record.path
            }
            catch { reply(self.storeError(error)); return }
            logger.notice("Go-backed Fetch domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private)")
            let rawJSON = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountFetchFD(r, p, Int32(fileHandle.fileDescriptor), transfer)) } }
            let json = sanitizedResult(rawJSON)
            guard let data = json.data(using: .utf8), let response = try? JSONDecoder().decode(CloudMountBridgeResponse.self, from: data) else { reply(NSError(domain: "org.rclone.cloudmount", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid bridge response"])); return }
            if response.ok {
                do { _ = try domainCatalog.withSnapshot(snapshot) { try $0.resolve(domain: domainIdentifier, identifier: itemIdentifier) } }
                catch { reply(self.storeError(error)); return }
                logger.notice("Go-backed Fetch completed path=\(path, privacy: .private)"); reply(nil) }
            else { let message = response.error?.message ?? "backend operation failed"; logger.error("Go-backed Fetch failed path=\(path, privacy: .private) code=\(response.error?.code ?? "backend_error", privacy: .public)"); let code = response.error?.code == "not_found" ? 404 : 2; reply(NSError(domain: "org.rclone.cloudmount", code: code, userInfo: [NSLocalizedDescriptionKey: message])) }
        }
    }

    func fetchPartialContents(domainIdentifier: String, itemIdentifier: String, operationIdentifier: String, offset: Int64, length: Int64, fileHandle: FileHandle, reply: @escaping (NSError?) -> Void) {
        guard let transfer = fetchOperations.register(domainIdentifier: domainIdentifier, operationIdentifier: operationIdentifier) else {
            reply(NSError(domain: "org.rclone.cloudmount", code: 3, userInfo: [NSLocalizedDescriptionKey: "duplicate fetch operation"])); return
        }
        backendQueue.async {
            defer { try? fileHandle.close(); fetchOperations.release(domainIdentifier: domainIdentifier, operationIdentifier: operationIdentifier, transfer: transfer) }
            let remote: String
            let snapshot: DomainCatalog.Snapshot
            let path: String
            do {
                snapshot = try domainCatalog.snapshot(domain: domainIdentifier)
                remote = snapshot.remote
                let record = try domainCatalog.withSnapshot(snapshot) { try $0.resolve(domain: domainIdentifier, identifier: itemIdentifier) }
                guard !record.metadata.isDirectory else { throw ItemCatalogError.noSuchItem }
                path = record.path
            }
            catch { reply(self.storeError(error)); return }
            logger.notice("Go-backed range fetch domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private) offset=\(offset) length=\(length)")
            let rawJSON = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountFetchRangeFD(r, p, Int32(fileHandle.fileDescriptor), offset, length, transfer)) } }
            let json = sanitizedResult(rawJSON)
            guard let data = json.data(using: .utf8), let response = try? JSONDecoder().decode(CloudMountBridgeResponse.self, from: data) else { reply(NSError(domain: "org.rclone.cloudmount", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid bridge response"])); return }
            if response.ok {
                do { _ = try domainCatalog.withSnapshot(snapshot) { try $0.resolve(domain: domainIdentifier, identifier: itemIdentifier) } }
                catch { reply(self.storeError(error)); return }
                logger.notice("Go-backed range fetch completed offset=\(offset) length=\(length)"); reply(nil) }
            else { let message = response.error?.message ?? "backend operation failed"; let code = response.error?.code == "cancelled" ? NSUserCancelledError : 2; reply(NSError(domain: "org.rclone.cloudmount", code: code, userInfo: [NSLocalizedDescriptionKey: message])) }
        }
    }

    func cancelFetch(domainIdentifier: String, operationIdentifier: String, reply: @escaping () -> Void) {
        fetchOperations.cancel(domainIdentifier: domainIdentifier, operationIdentifier: operationIdentifier)
        logger.notice("cancelled fetch operation domain=\(domainIdentifier, privacy: .public)")
        reply()
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: Any
    private let interface: NSXPCInterface
    private let peerRequirement: String
    private let role: String

    init(service: Any, protocol: Protocol, peerRequirement: String, role: String) {
        self.service = service
        self.interface = NSXPCInterface(with: `protocol`)
        self.peerRequirement = peerRequirement
        self.role = role
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(peerRequirement)
        logger.notice("configured \(self.role, privacy: .public) XPC peer authentication")
        connection.exportedInterface = interface
        connection.exportedObject = service
        connection.invalidationHandler = { logger.notice("XPC connection invalidated") }
        connection.interruptionHandler = { logger.notice("XPC connection interrupted") }
        connection.resume()
        return true
    }
}

private let controlDelegate = ListenerDelegate(service: ControlService(), protocol: CloudMountControlProtocol.self, peerRequirement: controlPeerCodeSigningRequirement, role: "control")
private let dataDelegate = ListenerDelegate(service: DataService(), protocol: CloudMountDataProtocol.self, peerRequirement: dataPeerCodeSigningRequirement, role: "data")
private let controlListener = NSXPCListener(machServiceName: infoString("CloudMountControlMachService"))
private let dataListener = NSXPCListener(machServiceName: infoString("CloudMountDataMachService"))
controlListener.delegate = controlDelegate
dataListener.delegate = dataDelegate
logger.notice("agent listening on separate control and data services")
controlListener.resume()
dataListener.resume()
RunLoop.current.run()
