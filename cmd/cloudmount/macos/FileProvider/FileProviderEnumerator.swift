import FileProvider
import os

private let enumerationLogger = Logger(subsystem: "org.rclone.cloudmount", category: "file-provider")

protocol CloudMountEnumerationClient {
    func list(domain: String, parent: String, completion: @escaping (String?, Error?) -> Void)
    func currentAnchor(domain: String, container: String, completion: @escaping (Data?, Error?) -> Void)
    func changes(domain: String, container: String, anchor: Data, limit: Int, completion: @escaping (String?, Error?) -> Void)
    func workingSet(domain: String, page: Data?, limit: Int, completion: @escaping (String?, Error?) -> Void)
}

private final class EnumerationCompletion {
    private let lock = NSLock(); private var completed = false
    func run(_ body: () -> Void) {
        lock.lock(); guard !completed else { lock.unlock(); return }
        completed = true; lock.unlock(); body()
    }
}

final class CloudMountXPCEnumerationClient: CloudMountEnumerationClient {
    private func rpc<Value>(_ call: (CloudMountDataProtocol, @escaping (Value?, Error?) -> Void) -> Void,
                            completion: @escaping (Value?, Error?) -> Void) {
        let connection = CloudMountXPC.dataConnection()
        let gate = EnumerationCompletion()
        let finish: (Value?, Error?) -> Void = { value, error in gate.run {
            connection.invalidationHandler = nil; connection.interruptionHandler = nil
            connection.invalidate(); completion(value, error)
        } }
        connection.interruptionHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }
        connection.invalidationHandler = { finish(nil, NSFileProviderError(.serverUnreachable)) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish(nil, $0) }) as? CloudMountDataProtocol else {
            finish(nil, NSFileProviderError(.serverUnreachable)); return
        }
        call(proxy, finish)
    }
    func list(domain: String, parent: String, completion: @escaping (String?, Error?) -> Void) {
        rpc({ proxy, finish in proxy.listDirectory(domainIdentifier: domain, parentIdentifier: parent) { finish($0, $1) } }, completion: completion)
    }
    func currentAnchor(domain: String, container: String, completion: @escaping (Data?, Error?) -> Void) {
        rpc({ proxy, finish in proxy.currentSyncAnchor(domainIdentifier: domain, containerIdentifier: container) { finish($0, $1) } }, completion: completion)
    }
    func changes(domain: String, container: String, anchor: Data, limit: Int, completion: @escaping (String?, Error?) -> Void) {
        rpc({ proxy, finish in proxy.enumerateChanges(domainIdentifier: domain, containerIdentifier: container, fromAnchor: anchor, limit: limit) { finish($0, $1) } }, completion: completion)
    }
    func workingSet(domain: String, page: Data?, limit: Int, completion: @escaping (String?, Error?) -> Void) {
        rpc({ proxy, finish in proxy.enumerateWorkingSet(domainIdentifier: domain, page: page, limit: limit) { finish($0, $1) } }, completion: completion)
    }
}

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let domainIdentifier: String
    private let parentIdentifier: String
    private let client: CloudMountEnumerationClient
    init(domainIdentifier: String, parentIdentifier: String, client: CloudMountEnumerationClient = CloudMountXPCEnumerationClient()) {
        self.domainIdentifier = domainIdentifier; self.parentIdentifier = parentIdentifier; self.client = client
    }
    func invalidate() {}

    private static func error(_ error: Error) -> Error {
        let value = error as NSError
        if value.domain == "org.rclone.cloudmount", value.code == -1002 { return NSFileProviderError(.syncAnchorExpired) }
        if value.domain == "org.rclone.cloudmount", value.code == 404 { return NSFileProviderError(.noSuchItem) }
        if value.domain == NSFileProviderErrorDomain { return error }
        return NSFileProviderError(.serverUnreachable)
    }
    private static func changesResponse(_ json: String?, error: Error?) throws -> CloudMountChangeResponse {
        if let error { throw Self.error(error) }
        guard let json, let data = json.data(using: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let response = try JSONDecoder().decode(CloudMountChangeResponse.self, from: data)
        guard CloudMountSyncAnchor.decode(response.anchor) != nil,
              response.deleted.allSatisfy(CloudMountItemIdentifier.isValid),
              response.items.allSatisfy({ CloudMountItemIdentifier.isValid($0.itemIdentifier) &&
                  ($0.parentIdentifier == CloudMountItemIdentifier.root || CloudMountItemIdentifier.isValid($0.parentIdentifier)) }) else { throw CocoaError(.fileReadCorruptFile) }
        return response
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let gate = EnumerationCompletion()
        if parentIdentifier == CloudMountItemIdentifier.workingSet {
            let token = page.rawValue == NSFileProviderPage.initialPageSortedByName as Data || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data ? nil : page.rawValue
            client.workingSet(domain: domainIdentifier, page: token, limit: 200) { json, error in gate.run {
                do {
                    let response = try Self.changesResponse(json, error: error)
                    observer.didEnumerate(response.items.map(FileProviderItem.init(metadata:)))
                    observer.finishEnumerating(upTo: response.nextPage.map { NSFileProviderPage($0) })
                } catch { observer.finishEnumeratingWithError(error) }
            } }
        } else {
            enumerationLogger.notice("enumerating remote directory domain=\(self.domainIdentifier, privacy: .public) parent=\(self.parentIdentifier, privacy: .public)")
            client.list(domain: domainIdentifier, parent: parentIdentifier) { json, error in gate.run {
                do {
                    let response = try FileProviderExtension.decodeResponse(json, error: error)
                    guard response.ok else { throw FileProviderExtension.providerError(response.error) }
                    observer.didEnumerate((response.items ?? []).map(FileProviderItem.init(metadata:)))
                    enumerationLogger.notice("enumeration completed parent=\(self.parentIdentifier, privacy: .public)")
                    observer.finishEnumerating(upTo: nil)
                } catch { observer.finishEnumeratingWithError(error) }
            } }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let gate = EnumerationCompletion()
        enumerationLogger.notice("enumerateChanges start domain=\(self.domainIdentifier, privacy: .public) container=\(self.parentIdentifier, privacy: .public)")
        client.changes(domain: domainIdentifier, container: parentIdentifier, anchor: syncAnchor.rawValue, limit: 200) { json, error in gate.run {
            do {
                let response = try Self.changesResponse(json, error: error)
                observer.didUpdate(response.items.map(FileProviderItem.init(metadata:)))
                observer.didDeleteItems(withIdentifiers: response.deleted.map { NSFileProviderItemIdentifier($0) })
                enumerationLogger.notice("enumerateChanges finish domain=\(self.domainIdentifier, privacy: .public) updates=\(response.items.count) deletions=\(response.deleted.count) revision=\(CloudMountSyncAnchor.decode(response.anchor)!.sequence) more=\(response.moreComing)")
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(response.anchor), moreComing: response.moreComing)
            } catch { observer.finishEnumeratingWithError(error) }
        } }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let gate = EnumerationCompletion()
        client.currentAnchor(domain: domainIdentifier, container: parentIdentifier) { data, error in gate.run {
            guard error == nil, let data, CloudMountSyncAnchor.decode(data) != nil else { completionHandler(nil); return }
            completionHandler(NSFileProviderSyncAnchor(data))
        } }
    }
}
