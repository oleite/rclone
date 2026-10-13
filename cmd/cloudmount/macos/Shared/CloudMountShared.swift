import Foundation

@objc protocol CloudMountControlProtocol {
    func ping(reply: @escaping (String) -> Void)
    func configureDomain(domainIdentifier: String, remote: String, reply: @escaping (NSError?) -> Void)
    func removeDomainConfiguration(domainIdentifier: String, reply: @escaping (NSError?) -> Void)
    func domainConfigurationStatus(domainIdentifier: String, reply: @escaping (Bool, NSError?) -> Void)
}

@objc protocol CloudMountDataProtocol {
    func listDirectory(domainIdentifier: String, parentIdentifier: String, reply: @escaping (String?, NSError?) -> Void)
    func statItem(domainIdentifier: String, itemIdentifier: String, reply: @escaping (String?, NSError?) -> Void)
    func currentSyncAnchor(domainIdentifier: String, containerIdentifier: String, reply: @escaping (Data?, NSError?) -> Void)
    func enumerateChanges(domainIdentifier: String, containerIdentifier: String, fromAnchor: Data, limit: Int, reply: @escaping (String?, NSError?) -> Void)
    func enumerateWorkingSet(domainIdentifier: String, page: Data?, limit: Int, reply: @escaping (String?, NSError?) -> Void)
    func fetchContents(
        domainIdentifier: String,
        itemIdentifier: String,
        operationIdentifier: String,
        fileHandle: FileHandle,
        reply: @escaping (NSError?) -> Void
    )
    func fetchPartialContents(
        domainIdentifier: String,
        itemIdentifier: String,
        operationIdentifier: String,
        offset: Int64,
        length: Int64,
        fileHandle: FileHandle,
        reply: @escaping (NSError?) -> Void
    )
    func cancelFetch(domainIdentifier: String, operationIdentifier: String, reply: @escaping () -> Void)
}

struct CloudMountMetadata: Codable {
    let path: String; let filename: String; let isDirectory: Bool; let size: Int64?
    let modificationTime: String?; let backendID: String?; let version: String
}
struct CloudMountBridgeError: Codable { let code: String; let message: String }
struct CloudMountBridgeResponse: Codable {
    let ok: Bool; let items: [CloudMountMetadata]?; let item: CloudMountMetadata?; let error: CloudMountBridgeError?
}

enum CloudMountItemIdentifier {
    static let root = "NSFileProviderRootContainerItemIdentifier"
    static let workingSet = "NSFileProviderWorkingSetContainerItemIdentifier"
    static func make() -> String { "i-" + UUID().uuidString.lowercased() }
    static func isValid(_ value: String) -> Bool {
        guard value.hasPrefix("i-"), let uuid = UUID(uuidString: String(value.dropFirst(2))) else { return false }
        return value == "i-" + uuid.uuidString.lowercased()
    }
}

/// A catalog epoch scopes durable sequences; it is not a backend delta token.
struct CloudMountSyncAnchor {
    let epoch: UUID
    let sequence: Int64
    var data: Data { Data("2:\(epoch.uuidString.lowercased()):\(sequence)".utf8) }
    static func decode(_ data: Data) -> CloudMountSyncAnchor? {
        guard data.count < 500, let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "2", let epoch = UUID(uuidString: String(parts[1])),
              let sequence = Int64(parts[2]), sequence >= 0 else { return nil }
        let value = CloudMountSyncAnchor(epoch: epoch, sequence: sequence)
        return value.data == data ? value : nil
    }
}

struct CloudMountChangeResponse: Codable {
    let items: [CloudMountItemMetadata]
    let deleted: [String]
    let anchor: Data
    let moreComing: Bool
    let nextPage: Data?
}

enum CloudMountDomainIdentifier {
    private static let namespace = "org.rclone.cloudmount."
    private static let prefix = namespace + "domain."
    static func make() -> String { prefix + UUID().uuidString.lowercased() }
    static func isValid(_ value: String) -> Bool {
        guard value.hasPrefix(prefix), let uuid = UUID(uuidString: String(value.dropFirst(prefix.count))) else { return false }
        return value == prefix + uuid.uuidString.lowercased()
    }
    // Existing owned-namespace IDs may be removed, but new registrations use UUIDs.
    static func isManaged(_ value: String) -> Bool {
        guard value.hasPrefix(namespace), value.count > namespace.count else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }
}

enum CloudMountPeerIdentity {
    static func acceptsUser(_ peer: UInt32, expected: UInt32) -> Bool { peer == expected }
}

// DATA responses deliberately exclude backend-relative paths and selectors.
struct CloudMountItemMetadata: Codable {
    let itemIdentifier: String
    let parentIdentifier: String
    let filename: String
    let isDirectory: Bool
    let size: Int64?
    let modificationTime: String?
    let contentVersion: String
    let metadataVersion: String
}

struct CloudMountItemResponse: Codable {
    let ok: Bool
    let items: [CloudMountItemMetadata]?
    let item: CloudMountItemMetadata?
    let error: CloudMountBridgeError?
}

enum CloudMountConstants {
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
