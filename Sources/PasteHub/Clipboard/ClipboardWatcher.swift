import AppKit
import PasteHubCore

@MainActor
final class ClipboardWatcher: NSObject {
    private let store: ClipStore
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var ignoringSelfWrite = false

    init(store: ClipStore) {
        self.store = store
        super.init()
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.3, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        poll()
    }

    func performSelfWrite(_ body: () -> Void) {
        ignoringSelfWrite = true
        body()
        lastChangeCount = NSPasteboard.general.changeCount
        ignoringSelfWrite = false
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if ignoringSelfWrite || PasteboardCodec.isSelfWrite(pasteboard) {
            return
        }
        ingest(pasteboard)
    }

    private func ingest(_ pasteboard: NSPasteboard) {
        let source = NSWorkspace.shared.frontmostApplication
        let draft = PasteboardCodec.capture(
            pasteboard,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.localizedName
        )
        guard let draft else { return }

        let context = PrivacyFilter.Context(
            text: String(data: draft.representations.first(where: { $0.uti == UTI.utf8PlainText })?.data ?? Data(), encoding: .utf8) ?? draft.preview,
            sourceBundleID: draft.sourceBundleID,
            skipOneTimeCodes: PasteHubDefaults.skipOneTimeCodes
        )
        guard PrivacyFilter.shouldCapture(context) else { return }

        do {
            _ = try store.ingest(draft)
        } catch {
            NSLog("PasteHub: failed to ingest clipboard item: \(error)")
        }
    }
}
