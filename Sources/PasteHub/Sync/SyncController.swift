import AppKit
import Observation
import PasteHubCore

/// Owns the sync engine on macOS. Sync runs only while a remote server and
/// sync key are configured; otherwise PasteHub stays fully local.
@MainActor
@Observable
final class SyncController {
    enum State: Equatable {
        case off
        case connecting
        case syncing
        case idle(Date)
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var pendingCount = 0

    let settings = SyncSettingsStore()

    private let store: ClipStore
    private let watcher: ClipboardWatcher
    private var engine: SyncEngine?
    private var liveTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    static var defaultDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    init(store: ClipStore, watcher: ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
    }

    var isConfigured: Bool { engine != nil }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .pasteHubStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
        reload()
    }

    /// Re-reads the configuration and (re)starts or stops sync accordingly.
    func reload() {
        liveTask?.cancel()
        liveTask = nil
        engine = nil

        guard let configuration = settings.configuration(defaultDeviceName: Self.defaultDeviceName) else {
            try? SyncEngine.deactivate(store: store)
            state = .off
            pendingCount = 0
            return
        }
        do {
            let engine = try SyncEngine(
                store: store,
                configuration: configuration,
                statusHandler: { [weak self] status in
                    Task { @MainActor in self?.apply(status) }
                },
                remoteHandler: { [weak self] report in
                    Task { @MainActor in self?.handleRemote(report) }
                }
            )
            self.engine = engine
            state = .connecting
            liveTask = Task { await engine.runLive() }
        } catch {
            state = .failed(error.localizedDescription)
        }
        refreshPendingCount()
    }

    /// Saves a new configuration after checking the server accepts it.
    func save(serverAddress: String, syncKey: String, deviceName: String) async throws {
        guard let url = SyncConfiguration.normalizeServerURL(serverAddress) else {
            throw SyncSetupError.invalidServer
        }
        let key = syncKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try SyncKeys(syncKey: key)
        let probe = try SyncEngine(
            store: ClipStore.inMemory(),
            configuration: SyncConfiguration(serverURL: url, syncKey: key, deviceName: deviceName)
        )
        try await probe.verifyConnection()

        settings.serverAddress = url.absoluteString
        settings.syncKey = key
        settings.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }

    func disconnect() {
        settings.syncKey = ""
        reload()
    }

    func syncNow() {
        guard let engine else { return }
        Task { try? await engine.syncOnce() }
    }

    private func storeDidChange() {
        refreshPendingCount()
        // Remote changes also post this notification; only local edits leave work in the outbox.
        if let engine, pendingCount > 0 {
            Task { await engine.scheduleSync() }
        }
    }

    private func refreshPendingCount() {
        pendingCount = (try? store.pendingSyncOutboxCount()) ?? 0
    }

    private func apply(_ status: SyncStatus) {
        guard engine != nil else { return }
        switch status {
        case .syncing: state = .syncing
        case let .idle(date): state = .idle(date)
        case let .failed(message): state = .failed(message)
        }
        refreshPendingCount()
    }

    /// Optionally puts the newest clip from another device on this Mac's clipboard.
    private func handleRemote(_ report: SyncReport) {
        guard settings.autoCopyRemote, report.wasIncremental,
              let hash = report.newestRemoteContentHash,
              let item = try? store.item(withContentHash: hash),
              let reps = try? store.representations(for: item.id), !reps.isEmpty
        else { return }
        watcher.performSelfWrite {
            PasteboardCodec.write(reps, to: .general, plainText: false)
        }
    }
}

enum SyncSetupError: LocalizedError {
    case invalidServer

    var errorDescription: String? {
        switch self {
        case .invalidServer: "服务器地址无效，示例：https://paste.example.com"
        }
    }
}
