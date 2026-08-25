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

    @Test func capturesScreenshotsAndImageURLsAsImages() {
        #expect(ClipFactory.shouldCaptureAsImage(text: nil, hasBitmap: true))
        #expect(ClipFactory.shouldCaptureAsImage(text: "https://example.com/a.png", hasBitmap: true))
        #expect(ClipFactory.shouldCaptureAsImage(text: "Screenshot 2026-08-25.png", hasBitmap: true))
        #expect(!ClipFactory.shouldCaptureAsImage(text: "a long paragraph\nwith two lines of real text", hasBitmap: true))
        #expect(!ClipFactory.shouldCaptureAsImage(text: "hello", hasBitmap: false))
    }

    @Test func makeImageStoresPngAndThumbnail() throws {
        let png = Data(repeating: 1, count: 32)
        let thumb = Data(repeating: 2, count: 8)
        let clip = try #require(ClipFactory.makeImage(
            png: png,
            thumbnail: thumb,
            width: 1280,
            height: 720,
            sourceAppName: "Safari"
        ))
        #expect(clip.kind == .image)
        #expect(clip.preview == "图片 1280×720")
        #expect(clip.contentHash == ContentHasher.sha256(of: png))
        #expect(clip.representations.contains { $0.uti == UTI.png && $0.data == png })
        #expect(clip.representations.contains { $0.uti == UTI.thumbnailPNG && $0.data == thumb })
    }

    @Test func rejectsHugeImages() {
        let huge = Data(repeating: 1, count: PasteHubDefaults.maxImageBytes + 1)
        #expect(ClipFactory.makeImage(png: huge, thumbnail: Data([1]), width: 10, height: 10) == nil)
    }
}
