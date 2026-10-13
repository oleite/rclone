import FileProvider
import Foundation
import ServiceManagement

enum ControlError: Error, CustomStringConvertible {
    case usage
    case operation(String)

    var description: String {
        switch self {
        case .usage: return "usage: RcloneCloudMount <agent-register|agent-unregister|agent-status|agent-ping|domain-list> | domain-add <display-name> <remote:path> | domain-remove <domain-id> | domain-path <domain-id>"
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

func domain(identifier: String, displayName: String) -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(identifier),
        displayName: displayName
    )
#if CLOUDMOUNT_FILE_PROVIDER_TESTING_MODE
    domain.testingModes = [.alwaysEnabled]
#endif
    return domain
}

func registeredDomains() throws -> [NSFileProviderDomain] {
    try waitForResult { completion in NSFileProviderManager.getDomainsWithCompletionHandler { completion($0, $1) } } ?? []
}

func lifecycle() -> DomainLifecycle {
    DomainLifecycle(
        registeredIdentifiers: { try registeredDomains().map { $0.identifier.rawValue } },
        isConfigured: configurationStatus,
        configure: { id, remote in try withAgent { proxy, completion in proxy.configureDomain(domainIdentifier: id, remote: remote) { completion($0) } } },
        register: { id, name in try waitForResult { completion in NSFileProviderManager.add(domain(identifier: id, displayName: name), completionHandler: { completion((), $0) }) } as Void? },
        deregister: { id in
            guard let value = try registeredDomains().first(where: { $0.identifier.rawValue == id }) else { throw DomainLifecycleError.unknownDomain }
            try waitForResult { completion in NSFileProviderManager.remove(value, completionHandler: { completion((), $0) }) } as Void?
        },
        removeConfiguration: { id in try withAgent { proxy, completion in proxy.removeDomainConfiguration(domainIdentifier: id) { completion($0) } } }
    )
}

func withAgent(_ operation: (CloudMountControlProtocol, @escaping (Error?) -> Void) -> Void) throws {
    let connection = CloudMountXPC.controlConnection()
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    connection.resume()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in failure = error; semaphore.signal() }) as? CloudMountControlProtocol else {
        connection.invalidate(); throw ControlError.operation("could not create agent XPC proxy")
    }
    operation(proxy) { error in failure = error; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 10) == .success else { connection.invalidate(); throw ControlError.operation("agent operation timed out") }
    connection.invalidate()
    if let failure { throw failure }
}

func pingAgent() throws {
    let connection = CloudMountXPC.controlConnection(); let semaphore = DispatchSemaphore(value: 0)
    var value: String?; var failure: Error?
    connection.resume()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in failure = error; semaphore.signal() }) as? CloudMountControlProtocol else { connection.invalidate(); throw ControlError.operation("could not create agent XPC proxy") }
    proxy.ping { value = $0; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 10) == .success else { connection.invalidate(); throw ControlError.operation("agent ping timed out") }
    connection.invalidate(); if let failure { throw failure }
    guard value == "pong" else { throw ControlError.operation("unexpected ping reply: \(value ?? "nil")") }
}

func configurationStatus(domainIdentifier: String) throws -> Bool {
    let connection = CloudMountXPC.controlConnection(); let semaphore = DispatchSemaphore(value: 0)
    var configured = false; var failure: Error?
    connection.resume()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in failure = error; semaphore.signal() }) as? CloudMountControlProtocol else { connection.invalidate(); throw ControlError.operation("could not create agent XPC proxy") }
    proxy.domainConfigurationStatus(domainIdentifier: domainIdentifier) { configured = $0; failure = $1; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 10) == .success else { connection.invalidate(); throw ControlError.operation("domain configuration status timed out") }
    connection.invalidate(); if let failure { throw failure }; return configured
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
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    switch command {
    case "domain-add": guard arguments.count == 2 else { throw ControlError.usage }
    case "domain-remove", "domain-path": guard arguments.count == 1 else { throw ControlError.usage }
    default: guard arguments.isEmpty else { throw ControlError.usage }
    }
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
        try pingAgent()
        print("pong")
    case "domain-add":
        let identifier = CloudMountDomainIdentifier.make()
        guard CloudMountDomainIdentifier.isValid(identifier), DomainLifecycle.validDisplayName(arguments[0]) else { throw DomainLifecycleError.invalidInput }
        try pingAgent()
        // Emit the opaque ID before side effects so an interrupted add can be cleaned up.
        print("domain identifier: \(identifier)")
        fflush(stdout)
        _ = try lifecycle().add(displayName: arguments[0], remote: arguments[1], identifier: identifier)
        print("domain added: \(identifier)")
    case "domain-list":
        let domains = try registeredDomains()
        for value in domains {
            let configured = try configurationStatus(domainIdentifier: value.identifier.rawValue)
            print("identifier=\(value.identifier.rawValue) displayName=\(value.displayName) userEnabled=\(value.userEnabled) remoteConfigured=\(configured)")
        }
    case "domain-remove":
        try lifecycle().remove(identifier: arguments[0])
        print("domain removed: \(arguments[0])")
    case "domain-path":
        guard CloudMountDomainIdentifier.isManaged(arguments[0]),
              let value = try registeredDomains().first(where: { $0.identifier.rawValue == arguments[0] }),
              let manager = NSFileProviderManager(for: value) else { throw DomainLifecycleError.unknownDomain }
        let url: URL? = try waitForResult { completion in manager.getUserVisibleURL(for: .rootContainer) { completion($0, $1) } }
        guard let url else { throw ControlError.operation("domain location unavailable") }
        print(url.path)
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
