import Foundation
import Testing
@testable import PasteHubCore

struct ClipFactoryTests {
    @Test func previewCollapsesWhitespaceAndTruncates() {
        let preview = ClipFactory.makePreview(from: "  hello   \n world  ", limit: 200)
        #expect(preview == "hello world")

        let long = String(repeating: "ab", count: 200)
        let truncated = ClipFactory.makePreview(from: long, limit: 10)
        #expect(truncated.count == 10)
    }

    @Test func detectsURLAndCode() {
        #expect(ClipFactory.kind(forPlainText: "https://github.com/caork/x", hasRichText: false) == .url)
        #expect(ClipFactory.kind(forPlainText: "hello", hasRichText: true) == .richText)
        #expect(ClipFactory.kind(forPlainText: "hello", hasRichText: false) == .text)
        #expect(ClipFactory.looksLikeCode("func paste(_ item: ClipItem)"))
        #expect(!ClipFactory.isWebURL("not a url"))
    }

    @Test func makeStoresPlainTextAndOptionalRichRepresentations() throws {
        let clip = try #require(ClipFactory.make(
            text: "hello",
            rtf: Data("rtf".utf8),
            html: Data("<b>hello</b>".utf8),
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari"
        ))
        #expect(clip.kind == .richText)
        #expect(clip.preview == "hello")
        #expect(clip.representations.count == 3)
        #expect(clip.contentHash == ContentHasher.sha256(of: "hello"))
        #expect(clip.sourceBundleID == "com.apple.Safari")
    }

    @Test func rejectsWhitespaceOnly() {
        #expect(ClipFactory.make(text: " \n ") == nil)
    }
}
