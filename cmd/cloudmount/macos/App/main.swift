import FileProvider
import Foundation
import ServiceManagement

enum ControlError: Error, CustomStringConvertible {
    case usage
    case operation(String)

    var description: String {
        switch self {
        case .usage: return "usage: RcloneCloudMount <agent-register|agent-unregister|agent-status|agent-ping|domain-list|domain-remove-test> | domain-add-test <remote:path>"
        case .operation(let message): return message
        }
    }
}

private let agentPlistName = Bundle.main.object(forInfoDictionaryKey: "CloudMountAgentPlistName") as! String

func waitForResult<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) throws -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: T?
    var failure: Error?
    body { value, error in
        result = value
        failure = error
        semaphore.signal()
    }
    semaphore.wait()
    if let failure { throw failure }
    return result
}

func domain(remote: String? = nil) -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(CloudMountConstants.domainIdentifier),
        displayName: CloudMountConstants.domainDisplayName
    )
    if #available(macOS 15.0, *), let remote { domain.userInfo = [CloudMountConstants.remoteUserInfoKey: remote] }
#if CLOUDMOUNT_FILE_PROVIDER_TESTING_MODE
    domain.testingModes = [.alwaysEnabled]
#endif
    return domain
}

func agentStatusText(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

func run() throws {
    guard CommandLine.arguments.count >= 2 else { throw ControlError.usage }
    let command = CommandLine.arguments[1]
    guard command == "domain-add-test" || CommandLine.arguments.count == 2 else { throw ControlError.usage }
    let service = SMAppService.agent(plistName: agentPlistName)

    switch command {
    case "agent-register":
        try service.register()
        print("agent registration requested; status=\(agentStatusText(service.status))")
    case "agent-unregister":
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        service.unregister { error in failure = error; semaphore.signal() }
        semaphore.wait()
        if let failure { throw failure }
        print("agent unregistered; status=\(agentStatusText(service.status))")
    case "agent-status":
        print(agentStatusText(service.status))
    case "agent-ping":
        let connection = CloudMountXPC.connection()
        let semaphore = DispatchSemaphore(value: 0)
        var response: String?
        var failure: Error?
        connection.invalidationHandler = { semaphore.signal() }
        connection.interruptionHandler = { semaphore.signal() }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = error
            semaphore.signal()
        } as? CloudMountAgentProtocol
        guard let proxy else {
            connection.invalidate()
            throw ControlError.operation("could not create agent XPC proxy")
        }
        proxy.ping { value in response = value; semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            connection.invalidate()
            throw ControlError.operation("agent ping timed out")
        }
        connection.invalidate()
        if let failure { throw failure }
        guard response == "pong" else { throw ControlError.operation("unexpected ping reply: \(response ?? "nil")") }
        print("pong")
    case "domain-add-test":
        guard CommandLine.arguments.count == 3 else { throw ControlError.usage }
        let remote = CommandLine.arguments[2]
        guard !remote.isEmpty else { throw ControlError.usage }
        try waitForResult { completion in
            NSFileProviderManager.add(domain(remote: remote), completionHandler: { completion((), $0) })
        } as Void?
        print("domain added: \(CloudMountConstants.domainIdentifier)")
    case "domain-list":
        let domains: [NSFileProviderDomain] = try waitForResult { completion in
            NSFileProviderManager.getDomainsWithCompletionHandler { completion($0, $1) }
        } ?? []
        for value in domains {
            let configured = if #available(macOS 15.0, *) { value.userInfo?[CloudMountConstants.remoteUserInfoKey] as? String != nil } else { false }
            print("identifier=\(value.identifier.rawValue) displayName=\(value.displayName) userEnabled=\(value.userEnabled) remoteConfigured=\(configured)")
        }
    case "domain-remove-test":
        try waitForResult { completion in
            NSFileProviderManager.remove(domain(), completionHandler: { completion((), $0) })
        } as Void?
        print("domain removed: \(CloudMountConstants.domainIdentifier)")
    default:
        throw ControlError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
