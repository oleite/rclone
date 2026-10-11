import FileProvider
import Foundation

@main enum FileProviderIdentityTests {
    static func main() throws {
        let identifier = "i-01234567-89ab-4cde-8f01-23456789abcd"
        let parent = "i-abcdef01-2345-4678-9abc-def012345678"
        let metadata = CloudMountItemMetadata(itemIdentifier: identifier, parentIdentifier: parent, filename: "renamed.exr", isDirectory: false,
                                              size: 17, modificationTime: nil, contentVersion: "content-stays", metadataVersion: "metadata-changes")
        let item = FileProviderItem(metadata: metadata)
        guard item.itemIdentifier.rawValue == identifier, item.parentItemIdentifier.rawValue == parent,
              item.itemVersion.contentVersion == Data("content-stays".utf8), item.itemVersion.metadataVersion == Data("metadata-changes".utf8) else {
            fatalError("provider derives identity or conflates versions")
        }
        let directory = FileProviderItem(metadata: CloudMountItemMetadata(itemIdentifier: identifier, parentIdentifier: CloudMountItemIdentifier.root,
                                                                         filename: "folder", isDirectory: true, size: nil, modificationTime: nil,
                                                                         contentVersion: "directory", metadataVersion: "name"))
        guard directory.itemIdentifier.rawValue == identifier, directory.parentItemIdentifier == .rootContainer else { fatalError("directory/root identity changed") }
        let response = CloudMountItemResponse(ok: true, items: [metadata], item: nil, error: nil)
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let decoded = try FileProviderExtension.decodeResponse(json)
        guard decoded.items?.first?.itemIdentifier == identifier else { fatalError("wire identity lost") }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let keys = Set((object["items"] as! [[String: Any]])[0].keys)
        guard !keys.contains("path"), !keys.contains("backendID"), !keys.contains("remote") else { fatalError("private backend fields leaked") }
        for raw in ["f-YQ", "d-ZGly", "bogus", "i-not-a-uuid"] {
            do { _ = try FileProviderExtension.requireIdentifier(NSFileProviderItemIdentifier(raw)); fatalError("legacy identifier accepted") }
            catch { guard (error as NSError).code == NSFileProviderError.noSuchItem.rawValue else { fatalError("invalid identifier wrong error") } }
        }
        do {
            _ = try FileProviderExtension.decodeResponse(nil, error: NSError(domain: "org.rclone.cloudmount", code: 404))
            fatalError("missing catalog ID did not fail")
        } catch {
            guard (error as NSError).domain == NSFileProviderErrorDomain,
                  (error as NSError).code == NSFileProviderError.noSuchItem.rawValue else { fatalError("missing catalog ID did not map to noSuchItem") }
        }
        print("FileProvider identity tests passed: opaque IDs/parents, distinct versions, private wire payload")
    }
}
