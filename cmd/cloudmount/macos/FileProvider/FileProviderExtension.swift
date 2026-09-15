import FileProvider
import Foundation
import os

private let logger = Logger(subsystem: "org.rclone.cloudmount", category: "file-provider")
private final class OneShotCompletion { private let lock = NSLock(); private var completed = false; func run(_ action: () -> Void) { lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock(); action() } }

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain; private let remote: String?
    required init(domain: NSFileProviderDomain) { self.domain = domain; if #available(macOS 15.0, *) { remote = domain.userInfo?[CloudMountConstants.remoteUserInfoKey] as? String } else { remote = nil }; super.init() }
    func invalidate() {}
    static func decodeResponse(_ json: String?) throws -> CloudMountBridgeResponse { guard let json, let data = json.data(using: .utf8) else { throw CocoaError(.fileReadCorruptFile) }; return try JSONDecoder().decode(CloudMountBridgeResponse.self, from: data) }
    static func providerError(_ error: CloudMountBridgeError?) -> Error { if error?.code == "not_found" { return NSFileProviderError(.noSuchItem) }; return NSError(domain: "org.rclone.cloudmount", code: 1, userInfo: [NSLocalizedDescriptionKey: error?.message ?? "rclone backend operation failed"]) }
    static func providerError(_ error: Error) -> Error { let value = error as NSError; return value.domain == "org.rclone.cloudmount" && value.code == 404 ? NSFileProviderError(.noSuchItem) : error }
    static func decodeIdentifier(_ identifier: NSFileProviderItemIdentifier) throws -> (path: String, isDirectory: Bool) {
        do { return try CloudMountIdentifierCodec.decode(identifier) }
        catch { throw NSFileProviderError(.noSuchItem) }
    }
    private func requireRemote() throws -> String { guard let remote, !remote.isEmpty else { throw NSError(domain: "org.rclone.cloudmount", code: 2, userInfo: [NSLocalizedDescriptionKey: "domain has no rclone remote configured"]) }; return remote }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1); if identifier == .rootContainer { completionHandler(FileProviderItem(rootName: domain.displayName), nil); return progress }
        do { let remote = try requireRemote(); let decoded = try Self.decodeIdentifier(identifier); let connection = CloudMountXPC.connection(); connection.resume(); guard let proxy = connection.remoteObjectProxyWithErrorHandler({ connection.invalidate(); completionHandler(nil, $0) }) as? CloudMountAgentProtocol else { connection.invalidate(); completionHandler(nil, CocoaError(.xpcConnectionReplyInvalid)); return progress }
            proxy.statItem(remote: remote, path: decoded.path, isDirectory: decoded.isDirectory) { json, error in defer { connection.invalidate() }; if let error { completionHandler(nil, error); return }; do { let response = try Self.decodeResponse(json); guard response.ok, let item = response.item else { completionHandler(nil, Self.providerError(response.error)); return }; progress.completedUnitCount = 1; completionHandler(FileProviderItem(metadata: item), nil) } catch { completionHandler(nil, error) } }
        } catch { completionHandler(nil, NSFileProviderError(.noSuchItem)) }; return progress
    }
    func enumerator(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator { let remote = try requireRemote(); if identifier == .rootContainer { return FileProviderEnumerator(remote: remote, path: "") }; let decoded = try Self.decodeIdentifier(identifier); guard decoded.isDirectory else { throw NSFileProviderError(.noSuchItem) }; return FileProviderEnumerator(remote: remote, path: decoded.path) }
    func fetchContents(for identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do { let remote = try requireRemote(); let decoded = try Self.decodeIdentifier(identifier); guard !decoded.isDirectory else { throw NSFileProviderError(.noSuchItem) }; let destination = try NSFileProviderManager(for: domain)!.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString); let connection = CloudMountXPC.connection(); let gate = OneShotCompletion()
            let finish: (CloudMountMetadata?, Error?) -> Void = { metadata, error in gate.run { connection.invalidate(); if let error { completionHandler(nil, nil, error) } else if let metadata { logger.notice("Go-backed fetch completed path=\(decoded.path, privacy: .public)"); progress.completedUnitCount = 1; completionHandler(destination, FileProviderItem(metadata: metadata), nil) } } }
            connection.interruptionHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }; connection.invalidationHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }; progress.cancellationHandler = { finish(nil, CocoaError(.userCancelled)) }; connection.resume(); guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish(nil, $0) }) as? CloudMountAgentProtocol else { finish(nil, CocoaError(.xpcConnectionReplyInvalid)); return progress }
            proxy.fetchContents(remote: remote, path: decoded.path, destinationPath: destination.path) { error in if let error { finish(nil, Self.providerError(error)); return }; proxy.statItem(remote: remote, path: decoded.path, isDirectory: false) { json, error in if let error { finish(nil, error); return }; do { let response = try Self.decodeResponse(json); guard response.ok, let item = response.item else { finish(nil, Self.providerError(response.error)); return }; finish(item, nil) } catch { finish(nil, error) } } }
        } catch { completionHandler(nil, nil, error is CloudMountIdentifierCodec.CodecError ? NSFileProviderError(.noSuchItem) : error) }; return progress
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress { completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize)); return Progress(totalUnitCount: 1) }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress { completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize)); return Progress(totalUnitCount: 1) }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress { completionHandler(NSFileProviderError(.cannotSynchronize)); return Progress(totalUnitCount: 1) }
}
