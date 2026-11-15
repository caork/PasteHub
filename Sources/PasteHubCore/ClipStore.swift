import Foundation
import GRDB

public final class ClipStore: Sendable {
    let db: any DatabaseWriter

    public init(database: any DatabaseWriter) throws {
        self.db = database
        try Self.migrator.migrate(database)
    }

    public convenience init(databaseQueue: DatabaseQueue) throws {
        try self.init(database: databaseQueue)
    }

    public static func openDefault() throws -> ClipStore {
        let root = try applicationSupportDirectory()
        return try open(at: root.appendingPathComponent("pastehub.sqlite"), sharedAcrossProcesses: false)
    }

    /// Opens a store at `url`. Use `sharedAcrossProcesses` when an app and its
    /// extensions use the same file (iOS App Group): it switches to a WAL
    /// `DatabasePool`, which tolerates concurrent readers in other processes.
    public static func open(at url: URL, sharedAcrossProcesses: Bool) throws -> ClipStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        let database: any DatabaseWriter
        if sharedAcrossProcesses {
            database = try DatabasePool(path: url.path, configuration: config)
        } else {
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            database = try DatabaseQueue(path: url.path, configuration: config)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try ClipStore(database: database)
    }

    public static func inMemory() throws -> ClipStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try ClipStore(database: DatabaseQueue(configuration: config))
    }

    public func ingest(_ draft: NewClip, historyLimit: Int = PasteHubDefaults.historyLimit) throws -> IngestResult {
        let result = try db.write { db -> IngestResult in
            if var existing = try DBClipItem
                .filter(Column("contentHash") == draft.contentHash)
                .fetchOne(db)
            {
                existing.lastUsedAt = Date()
                existing.sourceBundleID = draft.sourceBundleID ?? existing.sourceBundleID
                existing.sourceAppName = draft.sourceAppName ?? existing.sourceAppName
                try existing.update(db)
                try Self.enqueue(db, .upsert, contentHash: existing.contentHash)
                return .updated(existing.asClipItem())
            }

            let now = Date()
            let record = DBClipItem(
                id: draft.id,
                createdAt: now,
                lastUsedAt: now,
                pinned: false,
                kind: draft.kind.rawValue,
                preview: draft.preview,
                contentHash: draft.contentHash,
                sourceBundleID: draft.sourceBundleID,
                sourceAppName: draft.sourceAppName,
                byteSize: draft.byteSize,
                originDeviceName: nil,
                syncState: ClipSyncState.local.rawValue
            )
            try record.insert(db)
            try Self.insertRepresentations(db, itemID: draft.id, draft.representations)
            try Self.enqueue(db, .upsert, contentHash: draft.contentHash)
            try evictIfNeeded(db, limit: historyLimit)
            return .inserted(record.asClipItem())
        }
        notify()
        return result
    }

    public func items(matching query: String, limit: Int = PasteHubDefaults.overlayItemLimit) throws -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.read { db in
            var request = DBClipItem.order(Column("pinned").desc, Column("lastUsedAt").desc)
            if !trimmed.isEmpty {
                let escaped = escapeLike(trimmed)
                request = request.filter(Column("preview").like("%\(escaped)%", escape: "\\"))
            }
            return try request.limit(limit).fetchAll(db).map { $0.asClipItem() }
        }
    }

    public func item(withContentHash contentHash: String) throws -> ClipItem? {
        try db.read { db in
            try DBClipItem.filter(Column("contentHash") == contentHash).fetchOne(db)?.asClipItem()
        }
    }

    public func representations(for id: UUID) throws -> [ClipRepresentation] {
        try db.read { db in
            try DBClipRepresentation
                .filter(Column("itemId") == id)
                .fetchAll(db)
                .map { ClipRepresentation(itemID: $0.itemId, uti: $0.uti, data: $0.data) }
        }
    }

    public func plainText(for id: UUID) throws -> String? {
        let reps = try representations(for: id)
        if let utf8 = reps.first(where: { $0.uti == UTI.utf8PlainText }) {
            return String(data: utf8.data, encoding: .utf8)
        }
        return nil
    }

    public func thumbnails(for ids: [UUID]) throws -> [UUID: Data] {
        guard !ids.isEmpty else { return [:] }
        return try db.read { db in
            let rows = try DBClipRepresentation
                .filter(Column("uti") == UTI.thumbnailPNG)
                .filter(ids.contains(Column("itemId")))
                .fetchAll(db)
            var result: [UUID: Data] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                result[row.itemId] = row.data
            }
            return result
        }
    }

    public func setPinned(id: UUID, pinned: Bool) throws {
        try db.write { db in
            guard var record = try DBClipItem.fetchOne(db, key: id) else { return }
            record.pinned = pinned
            try record.update(db)
            try Self.enqueue(db, .pin, contentHash: record.contentHash)
        }
        notify()
    }

    public func delete(id: UUID) throws {
        try db.write { db in
            guard let record = try DBClipItem.fetchOne(db, key: id) else { return }
            try record.delete(db)
            try Self.enqueue(db, .delete, contentHash: record.contentHash)
        }
        notify()
    }

    /// Clears unpinned history on this device only; other devices keep theirs.
    public func deleteUnpinned() throws {
        try db.write { db in
            _ = try DBClipItem.filter(Column("pinned") == false).deleteAll(db)
        }
        notify()
    }

    /// Clears all history on this device only; other devices keep theirs.
    public func deleteAll() throws {
        try db.write { db in
            _ = try DBClipItem.deleteAll(db)
        }
        notify()
    }

    public func markUsed(id: UUID) throws {
        try db.write { db in
            _ = try DBClipItem
                .filter(Column("id") == id)
                .updateAll(db, Column("lastUsedAt").set(to: Date()))
        }
        notify()
    }

    public func itemCount() throws -> Int {
        try db.read { db in
            try DBClipItem.fetchCount(db)
        }
    }

    func evictIfNeeded(_ db: Database, limit: Int) throws {
        let unpinned = try DBClipItem
            .filter(Column("pinned") == false)
            .order(Column("lastUsedAt").asc)
            .fetchAll(db)
        let overflow = unpinned.count - limit
        if overflow > 0 {
            for record in unpinned.prefix(overflow) {
                try record.delete(db)
            }
        }

        var totalBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM clipItem") ?? 0
        guard totalBytes > PasteHubDefaults.maxStoreBytes else { return }
        let oldest = try DBClipItem
            .filter(Column("pinned") == false)
            .order(Column("lastUsedAt").asc)
            .fetchAll(db)
        for record in oldest {
            guard totalBytes > PasteHubDefaults.maxStoreBytes else { break }
            totalBytes -= record.byteSize
            try record.delete(db)
        }
    }

    static func insertRepresentations(_ db: Database, itemID: UUID, _ representations: [NewRepresentation]) throws {
        for representation in representations {
            try DBClipRepresentation(
                id: nil,
                itemId: itemID,
                uti: representation.uti,
                data: representation.data
            ).insert(db)
        }
    }

    func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pasteHubStoreDidChange, object: nil)
        }
    }

    private func escapeLike(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func applicationSupportDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("PasteHub", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clipItem") { t in
                t.column("id", .blob).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("kind", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("contentHash", .text).notNull().unique()
                t.column("sourceBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("byteSize", .integer).notNull()
            }
            try db.create(index: "clipItem_lastUsed", on: "clipItem", columns: ["pinned", "lastUsedAt"])
            try db.create(table: "clipRepresentation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemId", .blob).notNull().indexed()
                t.column("uti", .text).notNull()
                t.column("data", .blob).notNull()
                t.uniqueKey(["itemId", "uti"])
                t.foreignKey(["itemId"], references: "clipItem", columns: ["id"], onDelete: .cascade)
            }
        }
        migrator.registerMigration("v2-sync") { db in
            try db.alter(table: "clipItem") { t in
                t.add(column: "originDeviceName", .text)
                t.add(column: "syncState", .text).notNull().defaults(to: ClipSyncState.local.rawValue)
            }
            try db.create(table: "syncOutbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "syncMeta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return migrator
    }
}

struct DBClipItem: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipItem"

    var id: UUID
    var createdAt: Date
    var lastUsedAt: Date
    var pinned: Bool
    var kind: String
    var preview: String
    var contentHash: String
    var sourceBundleID: String?
    var sourceAppName: String?
    var byteSize: Int
    var originDeviceName: String?
    var syncState: String

    func asClipItem() -> ClipItem {
        ClipItem(
            id: id,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            pinned: pinned,
            kind: ClipKind(rawValue: kind) ?? .unknown,
            preview: preview,
            contentHash: contentHash,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            byteSize: byteSize,
            originDeviceName: originDeviceName,
            syncState: ClipSyncState(rawValue: syncState) ?? .local
        )
    }
}

struct DBClipRepresentation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipRepresentation"

    var id: Int64?
    var itemId: UUID
    var uti: String
    var data: Data
}
