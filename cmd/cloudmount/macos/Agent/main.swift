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

private let peerCodeSigningRequirement: String = {
    let teamID = requirementString(infoString("CloudMountTeamIdentifier"))
    let appID = requirementString(infoString("CloudMountAppBundleIdentifier"))
    let providerID = requirementString(infoString("CloudMountFileProviderBundleIdentifier"))
    return "anchor apple generic and certificate leaf[subject.OU] = \(teamID) and (identifier \(appID) or identifier \(providerID))"
}()

private final class AgentService: NSObject, CloudMountAgentProtocol {
    func ping(reply: @escaping (String) -> Void) {
        logger.notice("received ping")
        reply("pong")
    }

    private func stringResult(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return #"{"ok":false,"error":{"code":"internal_error","message":"bridge returned no response"}}"# }
        defer { RcloneCloudMountFreeString(pointer) }
        return String(cString: pointer)
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

    func listDirectory(domainIdentifier: String, path: String, reply: @escaping (String?, NSError?) -> Void) {
        backendQueue.async {
            do {
                let remote = try configurationStore.remote(domainIdentifier: domainIdentifier)
                logger.notice("Go-backed List domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .public)")
                reply(remote.withCString { r in path.withCString { p in self.stringResult(RcloneCloudMountList(r, p)) } }, nil)
            } catch { reply(nil, self.storeError(error)) }
        }
    }

    func statItem(domainIdentifier: String, path: String, isDirectory: Bool, reply: @escaping (String?, NSError?) -> Void) {
        backendQueue.async {
            do {
                let remote = try configurationStore.remote(domainIdentifier: domainIdentifier)
                logger.notice("Go-backed Stat domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .public) directory=\(isDirectory)")
                reply(remote.withCString { r in path.withCString { p in self.stringResult(RcloneCloudMountStat(r, p, isDirectory ? 1 : 0)) } }, nil)
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
            logger.notice("Go-backed Fetch domain=\(domainIdentifier, privacy: .public) path=\(path, privacy: .public)")
            let json = remote.withCString { r in path.withCString { p in self.stringResult(RcloneCloudMountFetchFD(r, p, Int32(fileHandle.fileDescriptor))) } }
            guard let data = json.data(using: .utf8), let response = try? JSONDecoder().decode(CloudMountBridgeResponse.self, from: data) else { reply(NSError(domain: "org.rclone.cloudmount", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid bridge response"])); return }
            if response.ok { logger.notice("Go-backed Fetch completed path=\(path, privacy: .public)"); reply(nil) }
            else { let message = response.error?.message ?? "backend fetch failed"; logger.error("Go-backed Fetch failed path=\(path, privacy: .public): \(message, privacy: .private)"); let code = response.error?.code == "not_found" ? 404 : 2; reply(NSError(domain: "org.rclone.cloudmount", code: code, userInfo: [NSLocalizedDescriptionKey: message])) }
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = AgentService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(peerCodeSigningRequirement)
        logger.notice("configured same-team XPC peer authentication")
        connection.exportedInterface = NSXPCInterface(with: CloudMountAgentProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { logger.notice("XPC connection invalidated") }
        connection.interruptionHandler = { logger.notice("XPC connection interrupted") }
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: CloudMountConstants.machServiceName)
listener.delegate = delegate
logger.notice("agent listening on \(CloudMountConstants.machServiceName, privacy: .public)")
listener.resume()
RunLoop.current.run()
