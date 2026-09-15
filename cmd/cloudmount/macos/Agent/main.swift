import Foundation
import os

private let logger = Logger(subsystem: "org.rclone.cloudmount", category: "agent")
private let backendQueue = DispatchQueue(label: "org.rclone.cloudmount.backend", attributes: .concurrent)
private let configurationStore: DomainConfigurationStore = {
    do { return try DomainConfigurationStore.applicationSupportStore() }
    catch { fatalError("unable to locate CloudMount configuration store: \(error.localizedDescription)") }
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
    let message = code == "not_found" ? "item not found" : "backend operation failed"
    let sanitized = CloudMountBridgeResponse(ok: false, items: nil, item: nil, error: CloudMountBridgeError(code: code, message: message))
    guard let encoded = try? JSONEncoder().encode(sanitized) else {
        return #"{"ok":false,"error":{"code":"internal_error","message":"backend operation failed"}}"#
    }
    return String(decoding: encoded, as: UTF8.self)
}

private final class ControlService: NSObject, CloudMountControlProtocol {
    func ping(reply: @escaping (String) -> Void) {
        logger.notice("received ping")
        reply("pong")
    }

    private func storeError(_ error: Error) -> NSError { error as NSError }

    func configureDomain(domainIdentifier: String, remote: String, reply: @escaping (NSError?) -> Void) {
        backendQueue.async {
            do { try configurationStore.configure(domainIdentifier: domainIdentifier, remote: remote); logger.notice("configured domain \(domainIdentifier, privacy: .public)"); reply(nil) }
            catch { logger.error("failed to configure domain \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .private)"); reply(self.storeError(error)) }
        }
    }

    func removeDomainConfiguration(domainIdentifier: String, reply: @escaping (NSError?) -> Void) {
        backendQueue.async {
            do { try configurationStore.remove(domainIdentifier: domainIdentifier); logger.notice("removed domain configuration \(domainIdentifier, privacy: .public)"); reply(nil) }
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
    private func storeError(_ error: Error) -> NSError { error as NSError }

    func listDirectory(domainIdentifier: String, path: String, reply: @escaping (String?, NSError?) -> Void) {
        backendQueue.async {
            do {
                let remote = try configurationStore.remote(domainIdentifier: domainIdentifier)
                logger.notice("Go-backed List domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private)")
                let result = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountList(r, p)) } }
                reply(sanitizedResult(result), nil)
            } catch { reply(nil, self.storeError(error)) }
        }
    }

    func statItem(domainIdentifier: String, path: String, isDirectory: Bool, reply: @escaping (String?, NSError?) -> Void) {
        backendQueue.async {
            do {
                let remote = try configurationStore.remote(domainIdentifier: domainIdentifier)
                logger.notice("Go-backed Stat domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private) directory=\(isDirectory)")
                let result = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountStat(r, p, isDirectory ? 1 : 0)) } }
                reply(sanitizedResult(result), nil)
            } catch { reply(nil, self.storeError(error)) }
        }
    }

    func fetchContents(
        domainIdentifier: String,
        path: String,
        fileHandle: FileHandle,
        reply: @escaping (NSError?) -> Void
    ) {
        backendQueue.async {
            defer { try? fileHandle.close() }
            let remote: String
            do { remote = try configurationStore.remote(domainIdentifier: domainIdentifier) }
            catch { reply(self.storeError(error)); return }
            logger.notice("Go-backed Fetch domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .private)")
            let rawJSON = remote.withCString { r in path.withCString { p in stringResult(RcloneCloudMountFetchFD(r, p, Int32(fileHandle.fileDescriptor))) } }
            let json = sanitizedResult(rawJSON)
            guard let data = json.data(using: .utf8), let response = try? JSONDecoder().decode(CloudMountBridgeResponse.self, from: data) else { reply(NSError(domain: "org.rclone.cloudmount", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid bridge response"])); return }
            if response.ok { logger.notice("Go-backed Fetch completed path=\(path, privacy: .private)"); reply(nil) }
            else { let message = response.error?.message ?? "backend operation failed"; logger.error("Go-backed Fetch failed path=\(path, privacy: .private) code=\(response.error?.code ?? "backend_error", privacy: .public)"); let code = response.error?.code == "not_found" ? 404 : 2; reply(NSError(domain: "org.rclone.cloudmount", code: code, userInfo: [NSLocalizedDescriptionKey: message])) }
        }
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
