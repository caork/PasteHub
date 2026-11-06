import AppKit
import Foundation
import Testing
@testable import PasteHubCore

struct PasteboardCodecTests {
    @Test(arguments: [false, true])
    func writesUnicodeTextWithOptionalRichFormats(plainText: Bool) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let text = "中文 clipboard 👋\nsecond line\t123"
        let html = Data("<p>中文 clipboard 👋</p>".utf8)
        let id = UUID()
        let representations = [
            ClipRepresentation(itemID: id, uti: UTI.utf8PlainText, data: Data(text.utf8)),
            ClipRepresentation(itemID: id, uti: UTI.html, data: html),
        ]

        PasteboardCodec.write(representations, to: board, plainText: plainText)

        #expect(board.string(forType: .string) == text)
        #expect(board.data(forType: .html) == (plainText ? nil : html))
        #expect(PasteboardCodec.isSelfWrite(board))
        #expect(PasteboardCodec.capture(board, sourceBundleID: nil, sourceAppName: nil) == nil)
    }
}
