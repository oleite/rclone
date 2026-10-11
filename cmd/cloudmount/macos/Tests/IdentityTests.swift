import FileProvider
import Foundation

@main enum IdentityTests {
    static func main() throws {
        let id = "i-01234567-89ab-4cde-8f01-23456789abcd"
        guard CloudMountItemIdentifier.isValid(id) else { fatalError("canonical identity rejected") }
        for value in ["", "i-nope", "f-aGVsbG8", "d-Zm9sZGVy", id.uppercased(), id + "/child", "i-00000000000000000000000000000000"] {
            guard !CloudMountItemIdentifier.isValid(value) else { fatalError("malformed or legacy identifier accepted") }
        }
        guard CloudMountItemIdentifier.root == NSFileProviderItemIdentifier.rootContainer.rawValue else { fatalError("root wire identifier differs from File Provider") }
        for _ in 0..<100 {
            guard CloudMountItemIdentifier.isValid(CloudMountItemIdentifier.make()) else { fatalError("generated identity invalid") }
        }
        print("Identity tests passed")
    }
}
