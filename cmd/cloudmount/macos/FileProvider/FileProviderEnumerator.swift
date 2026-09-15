import FileProvider
import os

private let enumerationLogger = Logger(subsystem: "org.rclone.cloudmount", category: "file-provider")
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("1".utf8))
    private let remote: String; private let path: String
    init(remote: String, path: String) { self.remote = remote; self.path = path }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let connection = CloudMountXPC.connection(); connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in connection.invalidate(); observer.finishEnumeratingWithError(error) }) as? CloudMountAgentProtocol else { connection.invalidate(); observer.finishEnumeratingWithError(CocoaError(.xpcConnectionReplyInvalid)); return }
        enumerationLogger.notice("enumerating remote directory path=\(self.path, privacy: .public)")
        proxy.listDirectory(remote: remote, path: path) { json, error in
            defer { connection.invalidate() }
            if let error { observer.finishEnumeratingWithError(error); return }
            do { let response = try FileProviderExtension.decodeResponse(json); guard response.ok else { observer.finishEnumeratingWithError(FileProviderExtension.providerError(response.error)); return }; observer.didEnumerate((response.items ?? []).map(FileProviderItem.init(metadata:))); enumerationLogger.notice("enumeration completed path=\(self.path, privacy: .public)"); observer.finishEnumerating(upTo: nil) } catch { observer.finishEnumeratingWithError(error) }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) { observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false) }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(Self.anchor) }
}
