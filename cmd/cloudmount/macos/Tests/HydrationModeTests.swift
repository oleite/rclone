import FileProvider
import Foundation
import ObjectiveC

@main enum HydrationModeTests {
    static func main() {
        // File Provider discovers partial hydration through Objective-C conformance.
        guard class_conformsToProtocol(FileProviderExtension.self, NSFileProviderReplicatedExtension.self) else {
            fputs("FAIL: production extension does not advertise full hydration\n", stderr)
            exit(1)
        }
        guard !class_conformsToProtocol(FileProviderExtension.self, NSFileProviderPartialContentFetching.self) else {
            fputs("FAIL: production extension advertises partial hydration\n", stderr)
            exit(1)
        }
        print("HydrationMode tests passed: production advertises full hydration only")
    }
}
