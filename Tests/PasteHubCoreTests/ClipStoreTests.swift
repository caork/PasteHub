import Foundation
import Testing
@testable import PasteHubCore

struct ClipStoreTests {
    @Test func insertFetchAndSearch() throws {
        let store = try ClipStore.inMemory()
        let first = try #require(ClipFactory.make(text: "https://github.com/caork/pasteHub"))
        let second = try #require(ClipFactory.make(text: "func paste(_ item: ClipItem)"))
        _ = try store.ingest(first)
        _ = try store.ingest(second)

        let all = try store.items(matching: "")
        #expect(all.count == 2)
        #expect(all[0].preview.contains("func paste"))

        let searched = try store.items(matching: "github")
        #expect(searched.count == 1)
        #expect(searched[0].kind == .url)
    }

    @Test func duplicateHashUpdatesLastUsedInsteadOfInserting() throws {
        let store = try ClipStore.inMemory()
        let first = try #require(ClipFactory.make(text: "same"))
        _ = try store.ingest(first)
        Thread.sleep(forTimeInterval: 0.01)
        let second = try #require(ClipFactory.make(text: "same", sourceAppName: "Safari"))
        let result = try store.ingest(second)

        #expect(try store.itemCount() == 1)
        guard case let .updated(item) = result else {
            Issue.record("expected updated ingest")
            return
        }
        #expect(item.sourceAppName == "Safari")
        #expect(item.lastUsedAt >= item.createdAt)
    }

    @Test func pinSurvivesEviction() throws {
        let store = try ClipStore.inMemory()
        let keep = try #require(ClipFactory.make(text: "pinned forever"))
        guard case let .inserted(pinnedItem) = try store.ingest(keep, historyLimit: 2) else {
            Issue.record("expected insert")
            return
        }
        try store.setPinned(id: pinnedItem.id, pinned: true)

        _ = try store.ingest(try #require(ClipFactory.make(text: "one")), historyLimit: 2)
        _ = try store.ingest(try #require(ClipFactory.make(text: "two")), historyLimit: 2)
        _ = try store.ingest(try #require(ClipFactory.make(text: "three")), historyLimit: 2)

        let items = try store.items(matching: "")
        #expect(items.contains { $0.id == pinnedItem.id && $0.pinned })
        #expect(!items.contains { $0.preview == "one" })
        #expect(try store.itemCount() == 3)
    }

    @Test func deleteAndRepresentationsRoundTrip() throws {
        let store = try ClipStore.inMemory()
        let draft = try #require(ClipFactory.make(text: "payload", rtf: Data("rtf".utf8)))
        guard case let .inserted(item) = try store.ingest(draft) else {
            Issue.record("expected insert")
            return
        }
        let reps = try store.representations(for: item.id)
        #expect(reps.contains { $0.uti == UTI.utf8PlainText })
        #expect(reps.contains { $0.uti == UTI.rtf })
        #expect(try store.plainText(for: item.id) == "payload")

        try store.delete(id: item.id)
        #expect(try store.itemCount() == 0)
        #expect(try store.representations(for: item.id).isEmpty)
    }

    @Test func deleteUnpinnedKeepsPins() throws {
        let store = try ClipStore.inMemory()
        guard case let .inserted(pinned) = try store.ingest(try #require(ClipFactory.make(text: "keep"))) else {
            Issue.record("expected insert")
            return
        }
        try store.setPinned(id: pinned.id, pinned: true)
        _ = try store.ingest(try #require(ClipFactory.make(text: "drop")))
        try store.deleteUnpinned()
        let remaining = try store.items(matching: "")
        #expect(remaining.map(\.preview) == ["keep"])
    }
}
