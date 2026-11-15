import CryptoKit
import Foundation

/// One entry of the relay's operation log, as sent over the wire. See docs/sync-protocol.md.
public struct WireOp: Codable, Sendable, Equatable {
    public var seq: Int64?
    public var opId: String
    public var deviceId: String
    public var type: SyncOpType
    public var itemKey: String
    public var keep: Bool
    public var sealed: Data
    public var blobIds: [String]?
}

struct PushRequest: Codable { var ops: [WireOp] }
struct PushResponse: Codable {
    struct Result: Codable { var opId: String; var seq: Int64 }
    var results: [Result]
}

struct PullResponse: Codable {
    var ops: [WireOp]
    var resetRequired: Bool
    var hasMore: Bool
}

struct StreamMessage: Codable { var latestSeq: Int64 }

struct SpaceInfo: Codable {
    var latestSeq: Int64
    var horizonSeq: Int64
    var blobBytes: Int64
    var quotaBytes: Int64
}

/// Plaintext inside `WireOp.sealed`. Exactly one of the bodies is set, matching `WireOp.type`.
struct SealedPayload: Codable, Equatable {
    struct Representation: Codable, Equatable {
        var uti: String
        /// Present when the data travels inline.
        var data: Data?
        /// Present when the data lives in an encrypted blob.
        var blob: BlobRef?
    }

    struct BlobRef: Codable, Equatable {
        var id: String
        var key: Data
        var size: Int
    }

    struct Upsert: Codable, Equatable {
        var kind: String
        var preview: String
        var createdAt: Date
        var usedAt: Date
        var pinned: Bool
        var sourceAppName: String?
        var deviceName: String
        var representations: [Representation]
    }

    var contentHash: String
    var upsert: Upsert?
    var pinned: Bool?
}

enum SyncSealError: Error {
    case malformed
}

enum SyncSealer {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    /// Binds the ciphertext to its envelope so the relay cannot move it to another op.
    static func associatedData(opId: String, type: SyncOpType, itemKey: String) -> Data {
        Data("pastehub-op-v1|\(opId)|\(type.rawValue)|\(itemKey)".utf8)
    }

    static func seal(_ payload: SealedPayload, keys: SyncKeys, opId: String, type: SyncOpType, itemKey: String) throws -> Data {
        let plaintext = try encoder.encode(payload)
        return try ChaChaPoly.seal(
            plaintext,
            using: keys.encryptionKey,
            authenticating: associatedData(opId: opId, type: type, itemKey: itemKey)
        ).combined
    }

    static func open(_ op: WireOp, keys: SyncKeys) throws -> SealedPayload {
        let box = try ChaChaPoly.SealedBox(combined: op.sealed)
        let plaintext = try ChaChaPoly.open(
            box,
            using: keys.encryptionKey,
            authenticating: associatedData(opId: op.opId, type: op.type, itemKey: op.itemKey)
        )
        let payload = try decoder.decode(SealedPayload.self, from: plaintext)
        // The item key must be the keyed hash of the content hash inside, or the op was tampered with.
        guard keys.itemKey(forContentHash: payload.contentHash) == op.itemKey else { throw SyncSealError.malformed }
        return payload
    }

    static func sealBlob(_ data: Data) throws -> (ciphertext: Data, key: Data) {
        let key = SymmetricKey(size: .bits256)
        let sealed = try ChaChaPoly.seal(data, using: key).combined
        return (sealed, key.withUnsafeBytes { Data($0) })
    }

    static func openBlob(_ ciphertext: Data, key: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: ciphertext), using: SymmetricKey(data: key))
    }
}
