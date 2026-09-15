import FileProvider
import UniformTypeIdentifiers

enum CloudMountIdentifierCodec {
    enum CodecError: Error { case malformed }
    static func encode(path: String, isDirectory: Bool) -> NSFileProviderItemIdentifier {
        let encoded = Data(path.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier((isDirectory ? "d-" : "f-") + encoded)
    }
    static func decode(_ identifier: NSFileProviderItemIdentifier) throws -> (path: String, isDirectory: Bool) {
        let raw = identifier.rawValue
        let isDirectory: Bool
        if raw.hasPrefix("d-") { isDirectory = true } else if raw.hasPrefix("f-") { isDirectory = false } else { throw CodecError.malformed }
        let payload = String(raw.dropFirst(2))
        guard !payload.isEmpty, payload.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw CodecError.malformed }
        var encoded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8), !path.isEmpty else { throw CodecError.malformed }
        guard encode(path: path, isDirectory: isDirectory) == identifier else { throw CodecError.malformed }
        return (path, isDirectory)
    }
}

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
    init(metadata: CloudMountMetadata) {
        itemIdentifier = CloudMountIdentifierCodec.encode(path: metadata.path, isDirectory: metadata.isDirectory)
        let parent = (metadata.path as NSString).deletingLastPathComponent
        parentItemIdentifier = parent.isEmpty ? .rootContainer : CloudMountIdentifierCodec.encode(path: parent, isDirectory: true)
        filename = metadata.filename
        contentType = metadata.isDirectory ? .folder : (UTType(filenameExtension: (metadata.filename as NSString).pathExtension) ?? .data)
        capabilities = metadata.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        documentSize = metadata.size.map(NSNumber.init(value:))
        if let value = metadata.modificationTime { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; contentModificationDate = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) } else { contentModificationDate = nil }
        let version = Data(metadata.version.utf8); itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
    }
}
