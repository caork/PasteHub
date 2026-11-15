import Foundation
import GRDB

public enum SyncOpType: String, Codable, Sendable {
    case upsert
    case pin
    case delete
}

public struct SyncOutboxEntry: Sendable, Equatable {
    public var id: Int64
    public var type: SyncOpType
    public var contentHash: String
}

public struct SyncItemSnapshot: Sendable {
    public var item: ClipItem
    public var representations: [ClipRepresentation]
}

/// A clip received from another device, already decrypted.
public struct RemoteClip: Sendable, Equatable {
    public var contentHash: String
    public var kind: ClipKind
    public var preview: String
    public var createdAt: Date
    public var usedAt: Date
    public var pinned: Bool
    public var sourceAppName: String?
    public var originDeviceName: String?
    public var representations: [NewRepresentation]

    public init(
        contentHash: String,
        kind: ClipKind,
        preview: String,
        createdAt: Date,
        usedAt: Date,
        pinned: Bool,
        sourceAppName: String?,
        originDeviceName: String?,
        representations: [NewRepresentation]
    ) {
        self.contentHash = contentHash
        self.kind = kind
        self.preview = preview
        self.createdAt = createdAt
        self.usedAt = usedAt
        self.pinned = pinned
        self.sourceAppName = sourceAppName
        self.originDeviceName = originDeviceName
        self.representations = representations
    }
}

private struct DBSyncOutbox: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncOutbox"
    var id: Int64?
    var type: String
    var contentHash: String
    var createdAt: Date
}

extension ClipStore {
    static let outboxEnabledKey = "outboxEnabled"

    /// Records a local change for upload. A no-op while sync is not configured.
    /// Older pending entries made redundant by this one are dropped.
    static func enqueue(_ db: Database, _ type: SyncOpType, contentHash: String) throws {
        guard try metaValue(db, outboxEnabledKey) == "1" else { return }
        switch type {
        case .delete:
            try db.execute(sql: "DELETE FROM syncOutbox WHERE contentHash = ?", arguments: [contentHash])
        case .upsert, .pin:
            // An upsert carries pin state, so it also replaces pending pins.
            let replaced = type == .upsert ? ["upsert", "pin"] : ["pin"]
            try db.execute(
                sql: "DELETE FROM syncOutbox WHERE contentHash = ? AND type IN (\(replaced.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments([contentHash] + replaced)
            )
        }
        try DBSyncOutbox(id: nil, type: type.rawValue, contentHash: contentHash, createdAt: Date()).insert(db)
        if type != .delete {
            try db.execute(
                sql: "UPDATE clipItem SET syncState = ? WHERE contentHash = ? AND syncState != ?",
                arguments: [ClipSyncState.local.rawValue, contentHash, ClipSyncState.tooLarge.rawValue]
            )
        }
    }

    static func metaValue(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncMeta WHERE key = ?", arguments: [key])
    }

    static func setMetaValue(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute(
                sql: "INSERT INTO syncMeta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        } else {
            try db.execute(sql: "DELETE FROM syncMeta WHERE key = ?", arguments: [key])
        }
    }

    public func syncMetaValue(_ key: String) throws -> String? {
        try db.read { try Self.metaValue($0, key) }
    }

    public func setSyncMetaValue(_ key: String, _ value: String?) throws {
        try db.write { try Self.setMetaValue($0, key, value) }
    }

    /// Turns change recording on or off. Turning it off discards pending uploads.
    public func setSyncOutboxEnabled(_ enabled: Bool) throws {
        try db.write { db in
            try Self.setMetaValue(db, Self.outboxEnabledKey, enabled ? "1" : nil)
            if !enabled {
                try db.execute(sql: "DELETE FROM syncOutbox")
            }
        }
    }

    public func isSyncOutboxEnabled() throws -> Bool {
        try syncMetaValue(Self.outboxEnabledKey) == "1"
    }

    /// Queues every current item for upload, oldest first so the newest ends up on top elsewhere.
    public func enqueueAllForSync() throws {
        try db.write { db in
            let hashes = try String.fetchAll(db, sql: "SELECT contentHash FROM clipItem ORDER BY lastUsedAt ASC")
            for hash in hashes {
                try Self.enqueue(db, .upsert, contentHash: hash)
            }
        }
    }

    public func pendingSyncOutbox(limit: Int = 100) throws -> [SyncOutboxEntry] {
        try db.read { db in
            try DBSyncOutbox.order(Column("id").asc).limit(limit).fetchAll(db).compactMap { row in
                guard let id = row.id, let type = SyncOpType(rawValue: row.type) else { return nil }
                return SyncOutboxEntry(id: id, type: type, contentHash: row.contentHash)
            }
        }
    }

    public func pendingSyncOutboxCount() throws -> Int {
        try db.read { try DBSyncOutbox.fetchCount($0) }
    }

    public func removeSyncOutbox(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            _ = try DBSyncOutbox.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    public func syncSnapshot(contentHash: String) throws -> SyncItemSnapshot? {
        try db.read { db in
            guard let record = try DBClipItem.filter(Column("contentHash") == contentHash).fetchOne(db) else {
                return nil
            }
            let reps = try DBClipRepresentation
                .filter(Column("itemId") == record.id)
                .fetchAll(db)
                .map { ClipRepresentation(itemID: $0.itemId, uti: $0.uti, data: $0.data) }
            return SyncItemSnapshot(item: record.asClipItem(), representations: reps)
        }
    }

    public func setSyncState(contentHash: String, _ state: ClipSyncState) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE clipItem SET syncState = ? WHERE contentHash = ?",
                arguments: [state.rawValue, contentHash]
            )
        }
        notify()
    }

    /// Applies a clip from another device without queuing it for upload again.
    public func applyRemoteUpsert(_ clip: RemoteClip, historyLimit: Int = PasteHubDefaults.historyLimit) throws {
        try db.write { db in
            if var existing = try DBClipItem.filter(Column("contentHash") == clip.contentHash).fetchOne(db) {
                existing.lastUsedAt = max(existing.lastUsedAt, clip.usedAt)
                existing.pinned = clip.pinned
                existing.sourceAppName = existing.sourceAppName ?? clip.sourceAppName
                if existing.syncState == ClipSyncState.local.rawValue {
                    existing.syncState = ClipSyncState.synced.rawValue
                }
                try existing.update(db)
                return
            }
            let id = UUID()
            let record = DBClipItem(
                id: id,
                createdAt: clip.createdAt,
                lastUsedAt: clip.usedAt,
                pinned: clip.pinned,
                kind: clip.kind.rawValue,
                preview: clip.preview,
                contentHash: clip.contentHash,
                sourceBundleID: nil,
                sourceAppName: clip.sourceAppName,
                byteSize: clip.representations.reduce(0) { $0 + $1.data.count },
                originDeviceName: clip.originDeviceName,
                syncState: ClipSyncState.synced.rawValue
            )
            try record.insert(db)
            try Self.insertRepresentations(db, itemID: id, clip.representations)
            try evictIfNeeded(db, limit: historyLimit)
        }
        notify()
    }

    public func applyRemotePin(contentHash: String, pinned: Bool) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE clipItem SET pinned = ? WHERE contentHash = ?",
                arguments: [pinned, contentHash]
            )
        }
        notify()
    }

    public func applyRemoteDelete(contentHash: String) throws {
        try db.write { db in
            _ = try DBClipItem.filter(Column("contentHash") == contentHash).deleteAll(db)
            try db.execute(sql: "DELETE FROM syncOutbox WHERE contentHash = ?", arguments: [contentHash])
        }
        notify()
    }
}
