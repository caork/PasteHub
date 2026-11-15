import Observation
import PasteHubCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum SyncState: Equatable {
        case off
        case syncing
        case idle(Date)
        case failed(String)
    }

    var query = "" { didSet { refresh() } }
    private(set) var items: [ClipItem] = []
    private(set) var thumbnails: [UUID: Data] = [:]
    private(set) var syncState: SyncState = .off
    var toast: String?

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .pasteHubStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    var isSyncConfigured: Bool {
        SharedEnvironment.settings.configuration(defaultDeviceName: SharedEnvironment.defaultDeviceName) != nil
    }

    func refresh() {
        guard let store = SharedEnvironment.store else { return }
        items = (try? store.items(matching: query, limit: 300)) ?? []
        let imageIDs = items.filter { $0.kind == .image }.map(\.id)
        thumbnails = (try? store.thumbnails(for: imageIDs)) ?? [:]
    }

    func becameActive() async {
        if SharedEnvironment.autoCaptureOnForeground {
            captureGeneralPasteboardIfChanged()
        }
        await sync()
    }

    func sync() async {
        guard let engine = SharedEnvironment.makeEngine() else {
            syncState = .off
            refresh()
            return
        }
        syncState = .syncing
        do {
            try await engine.syncOnce()
            syncState = .idle(Date())
        } catch {
            syncState = .failed(error.localizedDescription)
        }
        refresh()
    }

    func copy(_ item: ClipItem, plainText: Bool = false) {
        SharedEnvironment.copyToPasteboard(item, plainText: plainText)
        toast = "已复制"
    }

    func togglePin(_ item: ClipItem) {
        try? SharedEnvironment.store?.setPinned(id: item.id, pinned: !item.pinned)
        Task { await sync() }
    }

    func delete(_ item: ClipItem) {
        try? SharedEnvironment.store?.delete(id: item.id)
        Task { await sync() }
    }

    /// Reads UIPasteboard when it changed since the last capture. May show the system paste prompt.
    func captureGeneralPasteboardIfChanged() {
        let board = UIPasteboard.general
        let count = board.changeCount
        guard count != SharedEnvironment.lastCapturedChangeCount,
              count != SharedEnvironment.ownPasteboardChangeCount
        else { return }
        SharedEnvironment.lastCapturedChangeCount = count
        guard board.hasStrings || board.hasImages || board.hasURLs,
              let clip = UIPasteboardCodec.capture(board)
        else { return }
        SharedEnvironment.ingest(clip)
    }

    /// Handles content from SwiftUI's PasteButton, which never triggers the paste prompt.
    func ingest(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                _ = provider.loadObject(ofClass: UIImage.self) { image, _ in
                    guard let image = image as? UIImage else { return }
                    let data = image.pngData()
                    Task { @MainActor in
                        if let data, let image = UIImage(data: data), let clip = UIPasteboardCodec.makeImageClip(image) {
                            self.finishIngest(clip)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in
                        if let clip = ClipFactory.make(text: text) { self.finishIngest(clip) }
                    }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let clip = ClipFactory.make(text: url.absoluteString) { self.finishIngest(clip) }
                    }
                }
            }
        }
    }

    private func finishIngest(_ clip: NewClip) {
        if SharedEnvironment.ingest(clip) {
            SharedEnvironment.lastCapturedChangeCount = UIPasteboard.general.changeCount
            toast = "已保存"
            Task { await sync() }
        } else {
            toast = "已跳过（隐私过滤）"
        }
    }
}
