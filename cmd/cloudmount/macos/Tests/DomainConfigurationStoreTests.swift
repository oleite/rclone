import Foundation

@main
enum DomainConfigurationStoreTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("domains.json")
        let store = DomainConfigurationStore(fileURL: file)

        require(try !store.isConfigured(domainIdentifier: "one"), "missing configuration was not empty")
        try store.configure(domainIdentifier: "one", remote: "/private/example")
        require(try store.isConfigured(domainIdentifier: "one"), "mapping was not added")
        require(try store.remote(domainIdentifier: "one") == "/private/example", "mapping lookup failed")
        require(try DomainConfigurationStore(fileURL: file).remote(domainIdentifier: "one") == "/private/example", "fresh store did not reload mapping")

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "mapping permissions are not 0600")
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        require(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["domains.json"], "atomic write left temporary files")

        try store.remove(domainIdentifier: "one")
        require(try !DomainConfigurationStore(fileURL: file).isConfigured(domainIdentifier: "one"), "mapping was not removed")

        try Data("not-json".utf8).write(to: file)
        do { _ = try store.isConfigured(domainIdentifier: "one"); fatalError("malformed configuration was accepted") }
        catch DomainConfigurationStoreError.malformedConfiguration {}

        try Data(#"{"version":2,"domains":{}}"#.utf8).write(to: file)
        do { _ = try store.isConfigured(domainIdentifier: "one"); fatalError("future version was accepted") }
        catch DomainConfigurationStoreError.unsupportedVersion(2) {}

        print("DomainConfigurationStore tests passed")
    }
}
