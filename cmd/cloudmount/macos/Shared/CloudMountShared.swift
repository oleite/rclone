import Foundation

@objc protocol CloudMountControlProtocol {
    func ping(reply: @escaping (String) -> Void)
    func configureDomain(domainIdentifier: String, remote: String, reply: @escaping (NSError?) -> Void)
    func removeDomainConfiguration(domainIdentifier: String, reply: @escaping (NSError?) -> Void)
    func domainConfigurationStatus(domainIdentifier: String, reply: @escaping (Bool, NSError?) -> Void)
}

@objc protocol CloudMountDataProtocol {
    func listDirectory(domainIdentifier: String, path: String, reply: @escaping (String?, NSError?) -> Void)
    func statItem(domainIdentifier: String, path: String, isDirectory: Bool, reply: @escaping (String?, NSError?) -> Void)
    func fetchContents(
        domainIdentifier: String,
        path: String,
        fileHandle: FileHandle,
        reply: @escaping (NSError?) -> Void
    )
}

struct CloudMountMetadata: Codable {
    let path: String; let filename: String; let isDirectory: Bool; let size: Int64?
    let modificationTime: String?; let backendID: String?; let version: String
}
struct CloudMountBridgeError: Codable { let code: String; let message: String }
struct CloudMountBridgeResponse: Codable {
    let ok: Bool; let items: [CloudMountMetadata]?; let item: CloudMountMetadata?; let error: CloudMountBridgeError?
}

enum CloudMountConstants {
    static let domainIdentifier = "org.rclone.cloudmount.test"
    static let domainDisplayName = "Rclone CloudMount Test"

    static var controlMachServiceName: String {
        infoString("CloudMountControlMachService")
    }

    static var dataMachServiceName: String {
        infoString("CloudMountDataMachService")
    }

    static var agentCodeSigningRequirement: String {
        let teamID = requirementString(infoString("CloudMountTeamIdentifier"))
        let agentID = requirementString(infoString("CloudMountAgentIdentifier"))
        return "anchor apple generic and certificate leaf[subject.OU] = \(teamID) and identifier \(agentID)"
    }

    private static func infoString(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("\(key) is missing from Info.plist")
        }
        return value
    }

    private static func requirementString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum CloudMountXPC {
    static func controlConnection() -> NSXPCConnection {
        makeConnection(
            machServiceName: CloudMountConstants.controlMachServiceName,
            protocol: CloudMountControlProtocol.self
        )
    }

    static func dataConnection() -> NSXPCConnection {
        makeConnection(
            machServiceName: CloudMountConstants.dataMachServiceName,
            protocol: CloudMountDataProtocol.self
        )
    }

    private static func makeConnection(machServiceName: String, protocol: Protocol) -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: []
        )
        connection.setCodeSigningRequirement(CloudMountConstants.agentCodeSigningRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: `protocol`)
        return connection
    }
}
