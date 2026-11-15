import Foundation
import Testing
@testable import PasteHubCore

struct SyncKeysTests {
    /// Same vector as Server/internal/syncserver/server_test.go.
    @Test func derivationMatchesServerVector() throws {
        let master = Data((0 ..< 32).map { UInt8($0) })
        let key = SyncKeys.format(master: master)
        #expect(key == "phs1_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let keys = try SyncKeys(syncKey: "  \(key)\n")
        #expect(keys.authTokenHex == "e188906dd6ba8958e69a3602d9eaddb8f3b71009b0af21968888534dbdeae9ac")
        #expect(keys.spaceID == "3daffc343e5db52234b7bcf89e438735a40b0edf745d415f509915159295b880")
    }

    @Test func rejectsMalformedKeys() {
        #expect(throws: SyncKeyError.missingPrefix) { try SyncKeys.parse("abc") }
        #expect(throws: SyncKeyError.wrongLength) { try SyncKeys.parse("phs1_AAEC") }
        #expect(!SyncKeys.isValid(""))
    }

    @Test func itemKeyIsKeyedAndStable() throws {
        let a = try SyncKeys(syncKey: SyncKeys.format(master: Data(repeating: 1, count: 32)))
        let b = try SyncKeys(syncKey: SyncKeys.format(master: Data(repeating: 2, count: 32)))
        let hash = ContentHasher.sha256(of: "hello")
        #expect(a.itemKey(forContentHash: hash) == a.itemKey(forContentHash: hash))
        #expect(a.itemKey(forContentHash: hash) != b.itemKey(forContentHash: hash))
        #expect(a.itemKey(forContentHash: hash) != hash)
    }

    @Test func normalizesServerAddresses() {
        #expect(SyncConfiguration.normalizeServerURL("paste.example.com/")?.absoluteString == "https://paste.example.com")
        #expect(SyncConfiguration.normalizeServerURL("http://127.0.0.1:9021")?.absoluteString == "http://127.0.0.1:9021")
        #expect(SyncConfiguration.normalizeServerURL("ftp://x") == nil)
        #expect(SyncConfiguration.normalizeServerURL("  ") == nil)
    }
}

struct SyncSealerTests {
    let keys = try! SyncKeys(syncKey: SyncKeys.format(master: Data(repeating: 9, count: 32)))

    @Test func roundTripAndTamperDetection() throws {
        let hash = ContentHasher.sha256(of: "secret")
        let itemKey = keys.itemKey(forContentHash: hash)
        var payload = SealedPayload(contentHash: hash)
        payload.pinned = true
        let sealed = try SyncSealer.seal(payload, keys: keys, opId: "op-1", type: .pin, itemKey: itemKey)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("secret"))

        let op = WireOp(seq: 1, opId: "op-1", deviceId: "d", type: .pin, itemKey: itemKey, keep: true, sealed: sealed, blobIds: nil)
        #expect(try SyncSealer.open(op, keys: keys) == payload)

        var moved = op
        moved.opId = "op-2"
        #expect(throws: (any Error).self) { try SyncSealer.open(moved, keys: keys) }

        let other = try SyncKeys(syncKey: SyncKeys.format(master: Data(repeating: 8, count: 32)))
        #expect(throws: (any Error).self) { try SyncSealer.open(op, keys: other) }
    }

    @Test func blobRoundTrip() throws {
        let data = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        let sealed = try SyncSealer.sealBlob(data)
        #expect(sealed.ciphertext != data)
        #expect(try SyncSealer.openBlob(sealed.ciphertext, key: sealed.key) == data)
    }
}

struct SyncOutboxTests {
    @Test func outboxIsSilentUntilEnabled() throws {
        let store = try ClipStore.inMemory()
        _ = try store.ingest(try #require(ClipFactory.make(text: "before")))
        #expect(try store.pendingSyncOutboxCount() == 0)

        try store.setSyncOutboxEnabled(true)
        guard case let .inserted(item) = try store.ingest(try #require(ClipFactory.make(text: "after"))) else {
            Issue.record("expected insert")
            return
        }
        try store.setPinned(id: item.id, pinned: true)
        try store.setPinned(id: item.id, pinned: false)
        let entries = try store.pendingSyncOutbox()
        #expect(entries.map(\.type) == [.upsert, .pin])

        try store.delete(id: item.id)
        #expect(try store.pendingSyncOutbox().map(\.type) == [.delete])

        try store.setSyncOutboxEnabled(false)
        #expect(try store.pendingSyncOutboxCount() == 0)
    }

    @Test func remoteChangesAreNotEchoed() throws {
        let store = try ClipStore.inMemory()
        try store.setSyncOutboxEnabled(true)
        let hash = ContentHasher.sha256(of: "from phone")
        try store.applyRemoteUpsert(RemoteClip(
            contentHash: hash, kind: .text, preview: "from phone",
            createdAt: Date(), usedAt: Date(), pinned: true, sourceAppName: nil,
            originDeviceName: "iPhone", representations: [NewRepresentation(uti: UTI.utf8PlainText, data: Data("from phone".utf8))]
        ))
        try store.applyRemotePin(contentHash: hash, pinned: false)
        #expect(try store.pendingSyncOutboxCount() == 0)
        let item = try #require(try store.item(withContentHash: hash))
        #expect(item.originDeviceName == "iPhone")
        #expect(item.syncState == .synced)
        #expect(!item.pinned)

        try store.applyRemoteDelete(contentHash: hash)
        #expect(try store.itemCount() == 0)
        #expect(try store.pendingSyncOutboxCount() == 0)
    }

    @Test func remoteUpsertNeverMovesLastUsedBackwards() throws {
        let store = try ClipStore.inMemory()
        _ = try store.ingest(try #require(ClipFactory.make(text: "shared")))
        let local = try #require(try store.item(withContentHash: ContentHasher.sha256(of: "shared")))
        try store.applyRemoteUpsert(RemoteClip(
            contentHash: local.contentHash, kind: .text, preview: "shared",
            createdAt: .distantPast, usedAt: .distantPast, pinned: false, sourceAppName: nil,
            originDeviceName: "Mac", representations: []
        ))
        #expect(try store.item(withContentHash: local.contentHash)?.lastUsedAt == local.lastUsedAt)
        #expect(try store.itemCount() == 1)
    }
}

/// Runs only when Scripts/sync-e2e.sh provides a live relay.
struct SyncEndToEndTests {
    static let serverURL = ProcessInfo.processInfo.environment["PASTEHUB_SYNC_TEST_URL"]
    static let syncKey = ProcessInfo.processInfo.environment["PASTEHUB_SYNC_TEST_KEY"]
    static var enabled: Bool { serverURL != nil && syncKey != nil }

    func makeDevice(_ name: String) throws -> (ClipStore, SyncEngine) {
        let store = try ClipStore.inMemory()
        let config = SyncConfiguration(
            serverURL: try #require(SyncConfiguration.normalizeServerURL(Self.serverURL!)),
            syncKey: Self.syncKey!,
            deviceName: name
        )
        return (store, try SyncEngine(store: store, configuration: config, historyLimit: { 200 }))
    }

    @Test(.enabled(if: SyncEndToEndTests.enabled))
    func twoDevicesConverge() async throws {
        let (mac, macSync) = try makeDevice("Mac")
        let (phone, phoneSync) = try makeDevice("iPhone")

        // Text plus pin travels inline.
        let marker = "e2e \(UUID().uuidString)"
        guard case let .inserted(text) = try mac.ingest(try #require(ClipFactory.make(text: marker, html: Data("<b>\(marker)</b>".utf8)))) else {
            Issue.record("expected insert")
            return
        }
        try mac.setPinned(id: text.id, pinned: true)

        // A 200 KB image goes through an encrypted blob.
        let png = Data((0 ..< 200_000).map { _ in UInt8.random(in: 0 ... 255) })
        let image = try #require(ClipFactory.makeImage(png: png, thumbnail: Data(repeating: 1, count: 100), width: 10, height: 10))
        _ = try mac.ingest(image)

        // A 6 MB image stays local.
        let huge = try #require(ClipFactory.makeImage(png: Data(repeating: 3, count: 6 * 1024 * 1024), thumbnail: Data([1]), width: 1, height: 1))
        _ = try mac.ingest(huge)

        let pushed = try await macSync.syncOnce()
        #expect(pushed.pushed >= 3)
        #expect(try mac.item(withContentHash: huge.contentHash)?.syncState == .tooLarge)
        #expect(try mac.item(withContentHash: text.contentHash)?.syncState == .synced)

        let pulled = try await phoneSync.syncOnce()
        #expect(pulled.undecryptable == 0)
        let remoteText = try #require(try phone.item(withContentHash: text.contentHash))
        #expect(remoteText.pinned)
        #expect(remoteText.originDeviceName == "Mac")
        #expect(try phone.plainText(for: remoteText.id) == marker)
        #expect(try phone.representations(for: remoteText.id).contains { $0.uti == UTI.html })

        let remoteImage = try #require(try phone.item(withContentHash: image.contentHash))
        #expect(try phone.representations(for: remoteImage.id).first { $0.uti == UTI.png }?.data == png)
        #expect(try phone.item(withContentHash: huge.contentHash) == nil)

        // Changes made on the phone flow back and are not echoed to the phone again.
        try phone.delete(id: remoteImage.id)
        _ = try phone.ingest(try #require(ClipFactory.make(text: "\(marker) from phone")))
        try await phoneSync.syncOnce()
        try await macSync.syncOnce()
        #expect(try mac.item(withContentHash: image.contentHash) == nil)
        #expect(try mac.item(withContentHash: ContentHasher.sha256(of: "\(marker) from phone"))?.originDeviceName == "iPhone")
        #expect(try phone.pendingSyncOutboxCount() == 0)
    }

    @Test(.enabled(if: SyncEndToEndTests.enabled))
    func unknownKeyIsRejected() async throws {
        let store = try ClipStore.inMemory()
        let config = SyncConfiguration(
            serverURL: try #require(SyncConfiguration.normalizeServerURL(Self.serverURL!)),
            syncKey: SyncKeys.format(master: Data(repeating: 0xAB, count: 32)),
            deviceName: "Intruder"
        )
        let engine = try SyncEngine(store: store, configuration: config)
        await #expect(throws: SyncClientError.unauthorized) { try await engine.verifyConnection() }
    }
}
