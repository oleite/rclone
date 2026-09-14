import Foundation
import os

private let logger = Logger(subsystem: "org.rclone.cloudmount", category: "agent")

private final class AgentService: NSObject, CloudMountAgentProtocol {
    func ping(reply: @escaping (String) -> Void) {
        logger.notice("received ping")
        reply("pong")
    }

    func writeSyntheticContent(
        itemIdentifier: String,
        destinationPath: String,
        reply: @escaping (NSError?) -> Void
    ) {
        do {
            try CloudMountConstants.syntheticContents.write(
                toFile: destinationPath,
                atomically: true,
                encoding: .utf8
            )
            logger.notice("agent wrote synthetic item \(itemIdentifier, privacy: .public) to \(destinationPath, privacy: .public)")
            reply(nil)
        } catch {
            logger.error("synthetic write failed: \(error.localizedDescription, privacy: .public)")
            reply(error as NSError)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = AgentService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
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
