import FileProvider
import os

private let enumerationLogger = Logger(subsystem: "org.rclone.cloudmount", category: "file-provider")
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("1".utf8))
    private let domainIdentifier: String; private let path: String
    init(domainIdentifier: String, path: String) { self.domainIdentifier = domainIdentifier; self.path = path }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let connection = CloudMountXPC.dataConnection(); connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in connection.invalidate(); observer.finishEnumeratingWithError(error) }) as? CloudMountDataProtocol else { connection.invalidate(); observer.finishEnumeratingWithError(CocoaError(.xpcConnectionReplyInvalid)); return }
        enumerationLogger.notice("enumerating remote directory path=\(self.path, privacy: .private)")
        proxy.listDirectory(domainIdentifier: domainIdentifier, path: path) { json, error in
            defer { connection.invalidate() }
            if let error { observer.finishEnumeratingWithError(error); return }
            do { let response = try FileProviderExtension.decodeResponse(json); guard response.ok else { observer.finishEnumeratingWithError(FileProviderExtension.providerError(response.error)); return }; observer.didEnumerate((response.items ?? []).map(FileProviderItem.init(metadata:))); enumerationLogger.notice("enumeration completed path=\(self.path, privacy: .private)"); observer.finishEnumerating(upTo: nil) } catch { observer.finishEnumeratingWithError(error) }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) { observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false) }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(Self.anchor) }
}
