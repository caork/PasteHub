import Foundation

public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case image
    case file
    case url
    case color
    case unknown
}

public struct ClipItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var createdAt: Date
    public var lastUsedAt: Date
    public var pinned: Bool
    public var kind: ClipKind
    public var preview: String
    public var contentHash: String
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteSize: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        pinned: Bool = false,
        kind: ClipKind,
        preview: String,
        contentHash: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        byteSize: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
        self.kind = kind
        self.preview = preview
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.byteSize = byteSize
    }
}

public struct ClipRepresentation: Codable, Sendable, Equatable {
    public var itemID: UUID
    public var uti: String
    public var data: Data

    public init(itemID: UUID, uti: String, data: Data) {
        self.itemID = itemID
        self.uti = uti
        self.data = data
    }
}

public struct NewRepresentation: Sendable, Equatable {
    public var uti: String
    public var data: Data

    public init(uti: String, data: Data) {
        self.uti = uti
        self.data = data
    }
}

public struct NewClip: Sendable, Equatable {
    public var id: UUID
    public var kind: ClipKind
    public var preview: String
    public var contentHash: String
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var representations: [NewRepresentation]

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        preview: String,
        contentHash: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        representations: [NewRepresentation]
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.representations = representations
    }

    public var byteSize: Int {
        representations.reduce(0) { $0 + $1.data.count }
    }
}

public enum IngestResult: Sendable, Equatable {
    case inserted(ClipItem)
    case updated(ClipItem)
    case ignored
}

public enum UTI {
    public static let utf8PlainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
}

public extension Notification.Name {
    static let pasteHubStoreDidChange = Notification.Name("PasteHub.storeDidChange")
}
