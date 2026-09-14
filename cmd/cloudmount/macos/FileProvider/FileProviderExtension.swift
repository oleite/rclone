import FileProvider
import Foundation
import os

private let logger = Logger(subsystem: "org.rclone.cloudmount", category: "file-provider")

private final class OneShotCompletion {
    private let lock = NSLock()
    private var completed = false

    func run(_ action: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        action()
    }
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer || identifier.rawValue == CloudMountConstants.helloIdentifier {
            completionHandler(FileProviderItem(identifier: identifier), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress(totalUnitCount: 1)
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier == .rootContainer else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderEnumerator()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard itemIdentifier.rawValue == CloudMountConstants.helloIdentifier else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        do {
            let manager = NSFileProviderManager(for: domain)!
            let destination = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
            let connection = CloudMountXPC.connection()
            let completion = OneShotCompletion()
            let finish: (Error?) -> Void = { error in
                completion.run {
                    connection.invalidate()
                    if let error {
                        completionHandler(nil, nil, error)
                    } else {
                        logger.notice("agent completed synthetic item \(itemIdentifier.rawValue, privacy: .public)")
                        progress.completedUnitCount = 1
                        completionHandler(destination, FileProviderItem(identifier: itemIdentifier), nil)
                    }
                }
            }
            connection.interruptionHandler = { finish(NSFileProviderError(.serverUnreachable)) }
            connection.invalidationHandler = { finish(NSFileProviderError(.serverUnreachable)) }
            progress.cancellationHandler = { finish(CocoaError(.userCancelled)) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { finish($0) } as? CloudMountAgentProtocol
            guard let proxy else {
                finish(CocoaError(.xpcConnectionReplyInvalid))
                return progress
            }
            proxy.writeSyntheticContent(itemIdentifier: itemIdentifier.rawValue, destinationPath: destination.path) {
                finish($0)
            }
        } catch {
            completionHandler(nil, nil, error)
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents url: URL?, options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
        return Progress(totalUnitCount: 1)
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
        return Progress(totalUnitCount: 1)
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSFileProviderError(.cannotSynchronize))
        return Progress(totalUnitCount: 1)
    }
}
