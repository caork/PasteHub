import Foundation
import Testing
@testable import PasteHubCore

struct GitHubReleaseTests {
    @Test func decodesGitHubLatestReleasePayload() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/caork/PasteHub/releases/tag/v0.2.0",
          "body": "notes",
          "assets": [
            {
              "name": "PasteHub.app.zip",
              "label": null,
              "browser_download_url": "https://github.com/caork/PasteHub/releases/download/v0.2.0/PasteHub.app.zip"
            }
          ]
        }
        """
        let release = try GitHubRelease.decode(from: Data(json.utf8))
        #expect(release.tagName == "v0.2.0")
        #expect(release.htmlURL.contains("releases/tag/v0.2.0"))
        #expect(release.body == "notes")
        #expect(release.assets.first?.name == "PasteHub.app.zip")
        #expect(release.assets.first?.browserDownloadURL.contains("PasteHub.app.zip") == true)
    }

    @Test func acceptsNullBody() throws {
        let json = """
        {"tag_name":"0.1.0","html_url":"https://example.com","body":null,"assets":[]}
        """
        let release = try GitHubRelease.decode(from: Data(json.utf8))
        #expect(release.body == nil)
        #expect(release.assets.isEmpty)
    }
}
