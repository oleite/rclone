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
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CloudMountMachService") as? String,
              !value.isEmpty else {
            fatalError("CloudMountMachService is missing from Info.plist")
        }
        return value
    }
}

enum CloudMountXPC {
    static func connection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CloudMountConstants.machServiceName,
            options: []
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CloudMountAgentProtocol.self)
        return connection
    }
}
