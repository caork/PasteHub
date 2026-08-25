import Foundation
import Testing
@testable import PasteHubCore

struct AppVersionTests {
    @Test func stripsVPrefixAndCompares() {
        #expect(AppVersion.normalize("v0.2.0") == "0.2.0")
        #expect(AppVersion.compare("0.2.0", "0.1.0") == .orderedDescending)
        #expect(AppVersion.compare("v0.2.0", "0.2.0") == .orderedSame)
        #expect(AppVersion.isNewer("0.2.1", than: "0.2.0"))
        #expect(!AppVersion.isNewer("0.2.0", than: "0.2.0"))
        #expect(AppVersion.isNewer("0.10.0", than: "0.9.9"))
        #expect(!AppVersion.isNewer("0.1.9", than: "0.2.0"))
    }
}
