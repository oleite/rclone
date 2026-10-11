import FileProvider
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(rootName: String) {
        itemIdentifier = .rootContainer; parentItemIdentifier = .rootContainer; filename = rootName
        contentType = .folder; capabilities = [.allowsReading, .allowsContentEnumerating]; documentSize = nil; contentModificationDate = nil
        itemVersion = NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
    }
    init(metadata: CloudMountItemMetadata) {
        itemIdentifier = NSFileProviderItemIdentifier(metadata.itemIdentifier)
        parentItemIdentifier = NSFileProviderItemIdentifier(metadata.parentIdentifier)
        filename = metadata.filename
        contentType = metadata.isDirectory ? .folder : (UTType(filenameExtension: (metadata.filename as NSString).pathExtension) ?? .data)
        capabilities = metadata.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        documentSize = metadata.size.map(NSNumber.init(value:))
        if let value = metadata.modificationTime { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; contentModificationDate = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) } else { contentModificationDate = nil }
        itemVersion = NSFileProviderItemVersion(contentVersion: Data(metadata.contentVersion.utf8), metadataVersion: Data(metadata.metadataVersion.utf8))
    }
}
