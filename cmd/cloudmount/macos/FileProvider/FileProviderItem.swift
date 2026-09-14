import FileProvider
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities

    init(identifier: NSFileProviderItemIdentifier) {
        itemIdentifier = identifier
        if identifier == .rootContainer {
            parentItemIdentifier = .rootContainer
            filename = CloudMountConstants.domainDisplayName
            contentType = .folder
            capabilities = [.allowsReading, .allowsContentEnumerating]
        } else {
            parentItemIdentifier = .rootContainer
            filename = CloudMountConstants.helloFilename
            contentType = .plainText
            capabilities = [.allowsReading]
        }
    }

    var documentSize: NSNumber? {
        itemIdentifier == .rootContainer ? nil : NSNumber(value: CloudMountConstants.syntheticContents.utf8.count)
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}
