import Foundation

public enum SyncStatus: Sendable, Equatable {
    case syncing
    case idle(lastSync: Date)
    case failed(String)
}

public struct SyncReport: Sendable, Equatable {
    public var pushed = 0
    public var pulled = 0
    public var undecryptable = 0
    /// Content hash of the newest clip received from another device in this run, if any.
    public var newestRemoteContentHash: String?
    /// False on the first pull after setup, when the whole history arrives at once.
    public var wasIncremental = false
}

/// Moves changes between the local `ClipStore` and the remote relay.
///
/// - `syncOnce()` pushes the outbox and pulls new ops; iOS calls it on foreground,
///   keyboard appearance and from intents.
/// - `runLive()` keeps a WebSocket open and syncs whenever the relay reports new ops; macOS uses it.
public actor SyncEngine {
    public let configuration: SyncConfiguration
    public nonisolated let deviceID: String

    private let store: ClipStore
    private let keys: SyncKeys
    private let client: SyncClient
    private let historyLimit: @Sendable () -> Int
    private let statusHandler: @Sendable (SyncStatus) -> Void
    private let remoteHandler: @Sendable (SyncReport) -> Void

    private var isRunning = false
    private var rerunRequested = false
    private var pushTask: Task<Void, Never>?

    private var cursorKey: String { "cursor:\(keys.spaceID)" }

    public init(
        store: ClipStore,
        configuration: SyncConfiguration,
        session: URLSession = .shared,
        historyLimit: @escaping @Sendable () -> Int = { PasteHubDefaults.historyLimit },
        statusHandler: @escaping @Sendable (SyncStatus) -> Void = { _ in },
        remoteHandler: @escaping @Sendable (SyncReport) -> Void = { _ in }
    ) throws {
        self.store = store
        self.configuration = configuration
        self.keys = try SyncKeys(syncKey: configuration.syncKey)
        self.client = SyncClient(baseURL: configuration.serverURL, token: keys.authTokenHex, session: session)
        self.historyLimit = historyLimit
        self.statusHandler = statusHandler
        self.remoteHandler = remoteHandler

        if let existing = try store.syncMetaValue("deviceID") {
            deviceID = existing
        } else {
            let id = UUID().uuidString
            try store.setSyncMetaValue("deviceID", id)
            deviceID = id
        }

        // Start recording local changes, and upload existing history the first time this key is used.
        try store.setSyncOutboxEnabled(true)
        if try store.syncMetaValue("enqueuedSpace") != keys.spaceID {
            try store.enqueueAllForSync()
            try store.setSyncMetaValue("enqueuedSpace", keys.spaceID)
        }
    }

    /// Stops recording local changes. Call when the user removes the sync configuration.
    public static func deactivate(store: ClipStore) throws {
        try store.setSyncOutboxEnabled(false)
        try store.setSyncMetaValue("enqueuedSpace", nil)
    }

    /// Checks that the server is reachable and accepts the key.
    public func verifyConnection() async throws {
        _ = try await client.space()
    }

    /// Pushes pending local changes and pulls remote ones. Concurrent calls coalesce into one extra run.
    @discardableResult
    public func syncOnce() async throws -> SyncReport {
        if isRunning {
            rerunRequested = true
            return SyncReport()
        }
        isRunning = true
        defer { isRunning = false }
        statusHandler(.syncing)
        do {
            var report = SyncReport()
            repeat {
                rerunRequested = false
                let next = try await runPass()
                report.pushed += next.pushed
                report.pulled += next.pulled
                report.undecryptable += next.undecryptable
                report.wasIncremental = report.wasIncremental || next.wasIncremental
                report.newestRemoteContentHash = next.newestRemoteContentHash ?? report.newestRemoteContentHash
            } while rerunRequested
            statusHandler(.idle(lastSync: Date()))
            if report.pulled > 0 { remoteHandler(report) }
            return report
        } catch {
            statusHandler(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Schedules a push shortly after local changes, batching bursts of edits.
    public func scheduleSync(after delay: Duration = .milliseconds(400)) {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            _ = try? await self.syncOnce()
        }
    }

    /// Keeps a WebSocket open and syncs on every notification. Returns when the task is cancelled.
    public func runLive() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            do {
                try await syncOnce()
                try await listen()
                backoff = 2
            } catch is CancellationError {
                return
            } catch {
                statusHandler(.failed(error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 60)
        }
    }

    private func listen() async throws {
        let task = client.streamTask()
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        try await withTaskCancellationHandler {
            while true {
                let message = try await task.receive()
                let data: Data? = switch message {
                case let .data(d): d
                case let .string(s): Data(s.utf8)
                @unknown default: nil
                }
                guard let data, let event = try? JSONDecoder().decode(StreamMessage.self, from: data) else { continue }
                let cursor = Int64(try store.syncMetaValue(cursorKey) ?? "0") ?? 0
                if event.latestSeq > cursor {
                    try await syncOnce()
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Passes

    private func runPass() async throws -> SyncReport {
        var report = SyncReport()
        report.pushed = try await pushOutbox()
        try await pull(into: &report)
        return report
    }

    private func pushOutbox() async throws -> Int {
        var pushed = 0
        while true {
            let entries = try store.pendingSyncOutbox(limit: 50)
            guard !entries.isEmpty else { return pushed }
            var ops: [WireOp] = []
            var sentHashes: [(SyncOpType, String)] = []
            for entry in entries {
                // Entries whose item vanished or is too large produce no op and are simply dropped.
                if let op = try await makeOp(for: entry) {
                    ops.append(op)
                    sentHashes.append((entry.type, entry.contentHash))
                }
            }
            if !ops.isEmpty {
                _ = try await client.push(ops)
                for (type, hash) in sentHashes where type != .delete {
                    if try store.item(withContentHash: hash)?.syncState == .local {
                        try store.setSyncState(contentHash: hash, .synced)
                    }
                }
            }
            try store.removeSyncOutbox(ids: entries.map(\.id))
            pushed += ops.count
        }
    }

    private func makeOp(for entry: SyncOutboxEntry) async throws -> WireOp? {
        let opId = UUID().uuidString
        let itemKey = keys.itemKey(forContentHash: entry.contentHash)
        var payload = SealedPayload(contentHash: entry.contentHash)
        var keep = false
        var blobIDs: [String] = []

        switch entry.type {
        case .delete:
            break
        case .pin:
            guard let item = try store.item(withContentHash: entry.contentHash) else { return nil }
            payload.pinned = item.pinned
            keep = item.pinned
        case .upsert:
            guard let snapshot = try store.syncSnapshot(contentHash: entry.contentHash) else { return nil }
            let contentBytes = snapshot.representations
                .filter { $0.uti != UTI.thumbnailPNG }
                .reduce(0) { $0 + $1.data.count }
            if contentBytes > SyncLimits.maxClipBytes {
                try store.setSyncState(contentHash: entry.contentHash, .tooLarge)
                return nil
            }
            var reps: [SealedPayload.Representation] = []
            for rep in snapshot.representations {
                if rep.data.count <= SyncLimits.inlineRepresentationBytes {
                    reps.append(.init(uti: rep.uti, data: rep.data))
                } else {
                    let sealed = try SyncSealer.sealBlob(rep.data)
                    let blobID = UUID().uuidString
                    try await client.putBlob(id: blobID, data: sealed.ciphertext)
                    blobIDs.append(blobID)
                    reps.append(.init(uti: rep.uti, blob: .init(id: blobID, key: sealed.key, size: rep.data.count)))
                }
            }
            let item = snapshot.item
            payload.upsert = .init(
                kind: item.kind.rawValue,
                preview: item.preview,
                createdAt: item.createdAt,
                usedAt: item.lastUsedAt,
                pinned: item.pinned,
                sourceAppName: item.sourceAppName,
                deviceName: configuration.deviceName,
                representations: reps
            )
            keep = item.pinned
        }

        let sealed = try SyncSealer.seal(payload, keys: keys, opId: opId, type: entry.type, itemKey: itemKey)
        return WireOp(
            seq: nil, opId: opId, deviceId: deviceID, type: entry.type, itemKey: itemKey,
            keep: keep, sealed: sealed, blobIds: blobIDs.isEmpty ? nil : blobIDs
        )
    }

    private func pull(into report: inout SyncReport) async throws {
        var cursor = Int64(try store.syncMetaValue(cursorKey) ?? "0") ?? 0
        report.wasIncremental = cursor > 0
        var didReset = false
        while true {
            let page = try await client.pull(after: cursor)
            if page.resetRequired {
                guard !didReset else { throw SyncClientError.invalidResponse }
                didReset = true
                cursor = 0
                report.wasIncremental = false
                continue
            }
            for op in page.ops {
                if op.deviceId != deviceID {
                    do {
                        if let hash = try await apply(op) {
                            report.newestRemoteContentHash = hash
                        }
                        report.pulled += 1
                    } catch SyncClientError.http(status: 404, message: _) {
                        // A blob already removed by compaction; a newer op for the item follows.
                        report.undecryptable += 1
                    } catch let error as SyncClientError {
                        throw error
                    } catch let error as URLError {
                        throw error
                    } catch {
                        // Ops sealed with a different key, or corrupted, are skipped rather than blocking the log.
                        report.undecryptable += 1
                    }
                }
                if let seq = op.seq { cursor = max(cursor, seq) }
            }
            try store.setSyncMetaValue(cursorKey, String(cursor))
            if !page.hasMore { return }
        }
    }

    /// Applies one remote op; returns the content hash when it delivered a clip.
    private func apply(_ op: WireOp) async throws -> String? {
        let payload = try SyncSealer.open(op, keys: keys)
        switch op.type {
        case .delete:
            try store.applyRemoteDelete(contentHash: payload.contentHash)
            return nil
        case .pin:
            guard let pinned = payload.pinned else { throw SyncSealError.malformed }
            try store.applyRemotePin(contentHash: payload.contentHash, pinned: pinned)
            return nil
        case .upsert:
            guard let upsert = payload.upsert else { throw SyncSealError.malformed }
            var reps: [NewRepresentation] = []
            if try store.item(withContentHash: payload.contentHash) == nil {
                for rep in upsert.representations {
                    if let data = rep.data {
                        reps.append(NewRepresentation(uti: rep.uti, data: data))
                    } else if let blob = rep.blob {
                        let ciphertext = try await client.getBlob(id: blob.id)
                        reps.append(NewRepresentation(uti: rep.uti, data: try SyncSealer.openBlob(ciphertext, key: blob.key)))
                    }
                }
            }
            try store.applyRemoteUpsert(
                RemoteClip(
                    contentHash: payload.contentHash,
                    kind: ClipKind(rawValue: upsert.kind) ?? .unknown,
                    preview: upsert.preview,
                    createdAt: upsert.createdAt,
                    usedAt: upsert.usedAt,
                    pinned: upsert.pinned,
                    sourceAppName: upsert.sourceAppName,
                    originDeviceName: upsert.deviceName,
                    representations: reps
                ),
                historyLimit: historyLimit()
            )
            return payload.contentHash
        }
    }
}
