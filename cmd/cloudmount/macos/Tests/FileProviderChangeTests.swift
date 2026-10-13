import FileProvider
import Foundation

@main enum FileProviderChangeTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("fixture-domain"), displayName: "Fixture")
        let extensionInstance = FileProviderExtension(domain: domain)
        _ = try extensionInstance.enumerator(for: .workingSet, request: NSFileProviderRequest())
        let client = FixtureClient()
        let enumerator = FileProviderEnumerator(domainIdentifier: "fixture-domain", parentIdentifier: CloudMountItemIdentifier.workingSet, client: client)
        var received: Data?
        enumerator.currentSyncAnchor { received = $0?.rawValue }
        require(received == Data("2:00000000-0000-0000-0000-000000000001:7".utf8), "constant/non-durable anchor")
        let observer = ChangeObserver()
        enumerator.enumerateChanges(for: observer, from: NSFileProviderSyncAnchor(client.oldAnchor))
        require(observer.updates.map(\.itemIdentifier.rawValue) == [client.item.itemIdentifier], "update lost opaque identity")
        require(observer.deletions.map(\.rawValue) == ["i-00000000-0000-0000-0000-000000000003"], "deletion translation wrong")
        require(observer.anchor == client.newAnchor && observer.moreComing == true && observer.finishes == 1, "page/one-shot completion wrong")
        client.failure = NSError(domain: "org.rclone.cloudmount", code: -1002)
        let expired = ChangeObserver()
        enumerator.enumerateChanges(for: expired, from: NSFileProviderSyncAnchor(client.oldAnchor))
        require((expired.error as NSError?)?.code == NSFileProviderError.Code.syncAnchorExpired.rawValue, "expired anchor not mapped")
        client.failure = CocoaError(.xpcConnectionReplyInvalid)
        let disconnected = ChangeObserver()
        enumerator.enumerateChanges(for: disconnected, from: NSFileProviderSyncAnchor(client.oldAnchor))
        require((disconnected.error as NSError?)?.code == NSFileProviderError.Code.serverUnreachable.rawValue, "XPC error not useful")
        client.failure = nil
        let items = ItemsObserver()
        enumerator.enumerateItems(for: items, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        require(items.items.count == 1 && items.next?.rawValue == Data("fixture-page".utf8), "working set initial pagination lost")
        let second = ItemsObserver()
        enumerator.enumerateItems(for: second, startingAt: NSFileProviderPage(Data("fixture-page".utf8)))
        require(second.next == nil && second.items.isEmpty, "working set continuation incorrect")
        client.anchor = Data("1".utf8)
        received = nil
        enumerator.currentSyncAnchor { received = $0?.rawValue }
        require(received == nil, "malformed server anchor propagated")
        print("FileProvider change tests passed: working set, durable anchor, updates/deletions, pages, errors, one-shot replies")
    }
}

private final class FixtureClient: CloudMountEnumerationClient {
    let oldAnchor = Data("2:00000000-0000-0000-0000-000000000001:6".utf8)
    let newAnchor = Data("2:00000000-0000-0000-0000-000000000001:7".utf8)
    let item = CloudMountItemMetadata(itemIdentifier: "i-00000000-0000-0000-0000-000000000002", parentIdentifier: CloudMountItemIdentifier.root,
        filename: "fixture.txt", isDirectory: false, size: 20, modificationTime: nil, contentVersion: "new", metadataVersion: "metadata")
    var anchor = Data("2:00000000-0000-0000-0000-000000000001:7".utf8)
    var failure: Error?
    func list(domain: String, parent: String, completion: @escaping (String?, Error?) -> Void) { fatalError("working set used backend List") }
    func currentAnchor(domain: String, container: String, completion: @escaping (Data?, Error?) -> Void) { completion(anchor, failure) }
    func changes(domain: String, container: String, anchor: Data, limit: Int, completion: @escaping (String?, Error?) -> Void) {
        guard domain == "fixture-domain", container == CloudMountItemIdentifier.workingSet, anchor == oldAnchor else { completion(nil, CocoaError(.fileReadCorruptFile)); return }
        if let failure { completion(nil, failure); return }
        let value = CloudMountChangeResponse(items: [item], deleted: ["i-00000000-0000-0000-0000-000000000003"], anchor: newAnchor, moreComing: true, nextPage: nil)
        completion(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self), nil)
        completion(nil, CocoaError(.xpcConnectionReplyInvalid))
    }
    func workingSet(domain: String, page: Data?, limit: Int, completion: @escaping (String?, Error?) -> Void) {
        let value = CloudMountChangeResponse(items: page == nil ? [item] : [], deleted: [], anchor: newAnchor, moreComing: false,
                                            nextPage: page == nil ? Data("fixture-page".utf8) : nil)
        completion(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self), nil)
    }
}
private final class ChangeObserver: NSObject, NSFileProviderChangeObserver {
    var updates: [NSFileProviderItem] = []; var deletions: [NSFileProviderItemIdentifier] = []
    var anchor: Data?; var moreComing: Bool?; var error: Error?; var finishes = 0
    func didUpdate(_ updatedItems: [NSFileProviderItem]) { updates += updatedItems }
    func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) { deletions += identifiers }
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) { self.anchor = anchor.rawValue; self.moreComing = moreComing; finishes += 1 }
    func finishEnumeratingWithError(_ error: Error) { self.error = error; finishes += 1 }
}
private final class ItemsObserver: NSObject, NSFileProviderEnumerationObserver {
    var items: [NSFileProviderItem] = []; var next: NSFileProviderPage?; var error: Error?
    func didEnumerate(_ items: [NSFileProviderItem]) { self.items += items }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { next = nextPage }
    func finishEnumeratingWithError(_ error: Error) { self.error = error }
}
