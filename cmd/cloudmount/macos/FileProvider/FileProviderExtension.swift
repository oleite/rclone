import FileProvider
import Foundation
import os

private let logger = Logger(subsystem: "org.rclone.cloudmount", category: "file-provider")
private final class OneShotCompletion { private let lock = NSLock(); private var completed = false; func run(_ action: () -> Void) { lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock(); action() } }

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching {
    private let domain: NSFileProviderDomain
    private var domainIdentifier: String { domain.identifier.rawValue }
    required init(domain: NSFileProviderDomain) { self.domain = domain; super.init() }
    func invalidate() {}
    static func decodeResponse(_ json: String?) throws -> CloudMountBridgeResponse { guard let json, let data = json.data(using: .utf8) else { throw CocoaError(.fileReadCorruptFile) }; return try JSONDecoder().decode(CloudMountBridgeResponse.self, from: data) }
    static func providerError(_ error: CloudMountBridgeError?) -> Error { if error?.code == "not_found" { return NSFileProviderError(.noSuchItem) }; return NSError(domain: "org.rclone.cloudmount", code: 1, userInfo: [NSLocalizedDescriptionKey: error?.message ?? "rclone backend operation failed"]) }
    static func providerError(_ error: Error) -> Error { let value = error as NSError; return value.domain == "org.rclone.cloudmount" && value.code == 404 ? NSFileProviderError(.noSuchItem) : error }
    static func decodeIdentifier(_ identifier: NSFileProviderItemIdentifier) throws -> (path: String, isDirectory: Bool) {
        do { return try CloudMountIdentifierCodec.decode(identifier) }
        catch { throw NSFileProviderError(.noSuchItem) }
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1); if identifier == .rootContainer { completionHandler(FileProviderItem(rootName: domain.displayName), nil); return progress }
        do { let decoded = try Self.decodeIdentifier(identifier); let connection = CloudMountXPC.dataConnection(); connection.resume(); guard let proxy = connection.remoteObjectProxyWithErrorHandler({ connection.invalidate(); completionHandler(nil, $0) }) as? CloudMountDataProtocol else { connection.invalidate(); completionHandler(nil, CocoaError(.xpcConnectionReplyInvalid)); return progress }
            proxy.statItem(domainIdentifier: domainIdentifier, path: decoded.path, isDirectory: decoded.isDirectory) { json, error in defer { connection.invalidate() }; if let error { completionHandler(nil, error); return }; do { let response = try Self.decodeResponse(json); guard response.ok, let item = response.item else { completionHandler(nil, Self.providerError(response.error)); return }; progress.completedUnitCount = 1; completionHandler(FileProviderItem(metadata: item), nil) } catch { completionHandler(nil, error) } }
        } catch { completionHandler(nil, NSFileProviderError(.noSuchItem)) }; return progress
    }
    func enumerator(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator { if identifier == .rootContainer { return FileProviderEnumerator(domainIdentifier: domainIdentifier, path: "") }; let decoded = try Self.decodeIdentifier(identifier); guard decoded.isDirectory else { throw NSFileProviderError(.noSuchItem) }; return FileProviderEnumerator(domainIdentifier: domainIdentifier, path: decoded.path) }
    func fetchContents(for identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do { let decoded = try Self.decodeIdentifier(identifier); guard !decoded.isDirectory else { throw NSFileProviderError(.noSuchItem) }; guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }; let destination = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString); guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }; let fileHandle: FileHandle
            do { fileHandle = try FileHandle(forWritingTo: destination) } catch { try? FileManager.default.removeItem(at: destination); throw error }
            let connection = CloudMountXPC.dataConnection(); let gate = OneShotCompletion(); let operationIdentifier = UUID().uuidString; var proxy: CloudMountDataProtocol?
            let finish: (CloudMountMetadata?, Error?) -> Void = { metadata, error in gate.run { connection.invalidate(); var finalError = error; if finalError == nil { do { try fileHandle.synchronize() } catch { finalError = error } }; try? fileHandle.close(); if let finalError { try? FileManager.default.removeItem(at: destination); completionHandler(nil, nil, finalError) } else if let metadata { logger.notice("Go-backed fetch completed path=\(decoded.path, privacy: .private)"); progress.completedUnitCount = 1; completionHandler(destination, FileProviderItem(metadata: metadata), nil) } else { try? FileManager.default.removeItem(at: destination); completionHandler(nil, nil, CocoaError(.fileReadCorruptFile)) } } }
            connection.interruptionHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }; connection.invalidationHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }; progress.cancellationHandler = { if let proxy { proxy.cancelFetch(domainIdentifier: self.domainIdentifier, operationIdentifier: operationIdentifier) { finish(nil, CocoaError(.userCancelled)) } } else { finish(nil, CocoaError(.userCancelled)) } }; connection.resume(); guard let dataProxy = connection.remoteObjectProxyWithErrorHandler({ finish(nil, $0) }) as? CloudMountDataProtocol else { finish(nil, CocoaError(.xpcConnectionReplyInvalid)); return progress }; proxy = dataProxy
            dataProxy.fetchContents(domainIdentifier: domainIdentifier, path: decoded.path, operationIdentifier: operationIdentifier, fileHandle: fileHandle) { error in if let error { finish(nil, Self.providerError(error)); return }; dataProxy.statItem(domainIdentifier: self.domainIdentifier, path: decoded.path, isDirectory: false) { json, error in if let error { finish(nil, error); return }; do { let response = try Self.decodeResponse(json); guard response.ok, let item = response.item else { finish(nil, Self.providerError(response.error)); return }; finish(item, nil) } catch { finish(nil, error) } } }
        } catch { completionHandler(nil, nil, error is CloudMountIdentifierCodec.CodecError ? NSFileProviderError(.noSuchItem) : error) }; return progress
    }

    func fetchPartialContents(for identifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion, request: NSFileProviderRequest, minimalRange requestedRange: NSRange, aligningTo alignment: Int, options: NSFileProviderFetchContentsOptions, completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1); let emptyRange = NSRange(location: 0, length: 0)
        do {
            let decoded = try Self.decodeIdentifier(identifier); guard !decoded.isDirectory else { throw NSFileProviderError(.noSuchItem) }
            guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
            let destination = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let fileHandle: FileHandle
            do { fileHandle = try FileHandle(forWritingTo: destination) } catch { try? FileManager.default.removeItem(at: destination); throw error }
            let connection = CloudMountXPC.dataConnection(); let gate = OneShotCompletion(); let operationIdentifier = UUID().uuidString; var proxy: CloudMountDataProtocol?; var retrievedRange = emptyRange
            let finish: (CloudMountMetadata?, Error?) -> Void = { metadata, error in gate.run {
                connection.invalidate(); var finalError = error
                if finalError == nil { do { try fileHandle.synchronize() } catch { finalError = error } }
                try? fileHandle.close()
                if let finalError { try? FileManager.default.removeItem(at: destination); completionHandler(nil, nil, retrievedRange, [], finalError) }
                else if let metadata { logger.notice("partial fetch completed offset=\(retrievedRange.location) length=\(retrievedRange.length) path=\(decoded.path, privacy: .private)"); progress.completedUnitCount = 1; completionHandler(destination, FileProviderItem(metadata: metadata), retrievedRange, [], nil) }
                else { try? FileManager.default.removeItem(at: destination); completionHandler(nil, nil, retrievedRange, [], CocoaError(.fileReadCorruptFile)) }
            } }
            connection.interruptionHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }
            connection.invalidationHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }
            progress.cancellationHandler = { if let proxy { proxy.cancelFetch(domainIdentifier: self.domainIdentifier, operationIdentifier: operationIdentifier) { logger.notice("partial fetch cancelled"); finish(nil, CocoaError(.userCancelled)) } } else { finish(nil, CocoaError(.userCancelled)) } }
            connection.resume(); guard let dataProxy = connection.remoteObjectProxyWithErrorHandler({ finish(nil, $0) }) as? CloudMountDataProtocol else { finish(nil, CocoaError(.xpcConnectionReplyInvalid)); return progress }; proxy = dataProxy
            dataProxy.statItem(domainIdentifier: domainIdentifier, path: decoded.path, isDirectory: false) { json, error in
                if let error { finish(nil, error); return }
                do {
                    let response = try Self.decodeResponse(json); guard response.ok, let metadata = response.item, let size = metadata.size else { finish(nil, Self.providerError(response.error)); return }
                    if strictVersionMismatch(requested: requestedVersion.contentVersion, current: metadata.version, strict: options.contains(.strictVersioning)) { finish(nil, NSFileProviderError(.versionNoLongerAvailable)); return }
                    retrievedRange = try minimalAlignedRange(requested: requestedRange, alignment: alignment, fileSize: size)
                    logger.notice("partial fetch domain=\(self.domainIdentifier, privacy: .public) requestedStart=\(requestedRange.location) requestedLength=\(requestedRange.length) alignment=\(alignment) retrievedStart=\(retrievedRange.location) retrievedLength=\(retrievedRange.length) objectSize=\(size) path=\(decoded.path, privacy: .private)")
                    let fetchReply: (NSError?) -> Void = { error in
                        if let error { finish(nil, Self.providerError(error)); return }
                        dataProxy.statItem(domainIdentifier: self.domainIdentifier, path: decoded.path, isDirectory: false) { json, error in
                            if let error { finish(nil, error); return }
                            do {
                                let after = try Self.decodeResponse(json); guard after.ok, let current = after.item else { finish(nil, Self.providerError(after.error)); return }
                                guard !versionChanged(before: metadata.version, after: current.version) else { finish(nil, options.contains(.strictVersioning) ? NSFileProviderError(.versionNoLongerAvailable) : NSError(domain: "org.rclone.cloudmount", code: 4, userInfo: [NSLocalizedDescriptionKey: "item changed during partial fetch"])); return }
                                finish(current, nil)
                            } catch { finish(nil, error) }
                        }
                    }
                    if retrievedRange.location == 0, retrievedRange.length == Int(size) {
                        logger.notice("partial request uses full fetch for complete object size=\(size)")
                        dataProxy.fetchContents(domainIdentifier: self.domainIdentifier, path: decoded.path, operationIdentifier: operationIdentifier, fileHandle: fileHandle, reply: fetchReply)
                    } else {
                        dataProxy.fetchPartialContents(domainIdentifier: self.domainIdentifier, path: decoded.path, operationIdentifier: operationIdentifier, offset: Int64(retrievedRange.location), length: Int64(retrievedRange.length), fileHandle: fileHandle, reply: fetchReply)
                    }
                } catch { finish(nil, error) }
            }
        } catch { completionHandler(nil, nil, emptyRange, [], error is CloudMountIdentifierCodec.CodecError ? NSFileProviderError(.noSuchItem) : error) }
        return progress
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress { completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize)); return Progress(totalUnitCount: 1) }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress { completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize)); return Progress(totalUnitCount: 1) }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress { completionHandler(NSFileProviderError(.cannotSynchronize)); return Progress(totalUnitCount: 1) }
}
