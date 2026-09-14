import Foundation

@objc protocol CloudMountAgentProtocol {
    func ping(reply: @escaping (String) -> Void)
    func writeSyntheticContent(
        itemIdentifier: String,
        destinationPath: String,
        reply: @escaping (NSError?) -> Void
    )
}

enum CloudMountConstants {
    static let domainIdentifier = "org.rclone.cloudmount.synthetic-test"
    static let domainDisplayName = "Rclone CloudMount Test"
    static let helloIdentifier = "synthetic-hello"
    static let helloFilename = "hello.txt"
    static let syntheticContents = "Hello from rclone cloudmount agent\n"

    static var machServiceName: String {
        infoString("CloudMountMachService")
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
    static func connection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CloudMountConstants.machServiceName,
            options: []
        )
        connection.setCodeSigningRequirement(CloudMountConstants.agentCodeSigningRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: CloudMountAgentProtocol.self)
        return connection
    }
}
