import Foundation
import GRDB

public final class ClipStore: Sendable {
    private let db: DatabaseQueue

    public init(databaseQueue: DatabaseQueue) throws {
        self.db = databaseQueue
        try migrator.migrate(db)
    }

    public static func openDefault() throws -> ClipStore {
        let root = try applicationSupportDirectory()
        let url = root.appendingPathComponent("pastehub.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return try ClipStore(databaseQueue: queue)
    }

    public static func inMemory() throws -> ClipStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try ClipStore(databaseQueue: DatabaseQueue(configuration: config))
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
                byteSize: draft.byteSize
            )
            try record.insert(db)
            for representation in draft.representations {
                try DBClipRepresentation(
                    id: nil,
                    itemId: draft.id,
                    uti: representation.uti,
                    data: representation.data
                ).insert(db)
            }
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
            _ = try DBClipItem
                .filter(Column("id") == id)
                .updateAll(db, Column("pinned").set(to: pinned))
        }
        notify()
    }

    public func delete(id: UUID) throws {
        try db.write { db in
            _ = try DBClipItem.filter(Column("id") == id).deleteAll(db)
        }
        notify()
    }

    public func deleteUnpinned() throws {
        try db.write { db in
            _ = try DBClipItem.filter(Column("pinned") == false).deleteAll(db)
        }
        notify()
    }

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

    private func evictIfNeeded(_ db: Database, limit: Int) throws {
        let unpinned = try DBClipItem
            .filter(Column("pinned") == false)
            .order(Column("lastUsedAt").asc)
            .fetchAll(db)
        let overflow = unpinned.count - limit
        guard overflow > 0 else { return }
        for record in unpinned.prefix(overflow) {
            try record.delete(db)
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

    private func notify() {
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

    private var migrator: DatabaseMigrator {
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
        return migrator
    }
}

private struct DBClipItem: Codable, FetchableRecord, PersistableRecord {
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
            byteSize: byteSize
        )
    }
}

private struct DBClipRepresentation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipRepresentation"

    var id: Int64?
    var itemId: UUID
    var uti: String
    var data: Data
}
