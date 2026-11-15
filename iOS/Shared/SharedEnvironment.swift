import Foundation
import PasteHubCore
import UIKit

/// State shared by the app, keyboard and share extension through the App Group.
@MainActor
enum SharedEnvironment {
    nonisolated static let appGroup = "group.com.kaitaocao.PasteHub"

    nonisolated static let settings = SyncSettingsStore(defaultsSuite: appGroup, keychainAccessGroup: appGroup)

    nonisolated static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    nonisolated static let store: ClipStore? = {
        do {
            let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try ClipStore.open(
                at: directory.appendingPathComponent("pastehub.sqlite"),
                sharedAcrossProcesses: true
            )
        } catch {
            NSLog("PasteHub: failed to open shared store: \(error)")
            return nil
        }
    }()

    static var defaultDeviceName: String {
        // iOS 16+ returns a generic model name without a special entitlement.
        UIDevice.current.model
    }

    nonisolated static var historyLimit: Int {
        let value = defaults.object(forKey: PasteHubDefaults.historyLimitKey) as? Int ?? PasteHubDefaults.defaultHistoryLimit
        return min(max(value, 20), 1000)
    }

    /// Pasteboard change count written by PasteHub itself, so auto-capture skips it.
    static var ownPasteboardChangeCount: Int {
        get { defaults.integer(forKey: "ownPasteboardChangeCount") }
        set { defaults.set(newValue, forKey: "ownPasteboardChangeCount") }
    }

    static var lastCapturedChangeCount: Int {
        get { defaults.integer(forKey: "lastCapturedChangeCount") }
        set { defaults.set(newValue, forKey: "lastCapturedChangeCount") }
    }

    static var autoCaptureOnForeground: Bool {
        get { defaults.bool(forKey: "autoCaptureOnForeground") }
        set { defaults.set(newValue, forKey: "autoCaptureOnForeground") }
    }

    /// Creates an engine for the current configuration, or nil when sync is not set up.
    static func makeEngine(statusHandler: @escaping @Sendable (SyncStatus) -> Void = { _ in }) -> SyncEngine? {
        guard let store, let configuration = settings.configuration(defaultDeviceName: defaultDeviceName) else {
            return nil
        }
        return try? SyncEngine(
            store: store,
            configuration: configuration,
            historyLimit: { SharedEnvironment.historyLimit },
            statusHandler: statusHandler
        )
    }

    /// Runs one push + pull if sync is configured. Errors are reported, not thrown.
    @discardableResult
    static func syncIfConfigured() async -> Result<SyncReport, Error>? {
        guard let engine = makeEngine() else { return nil }
        do {
            return .success(try await engine.syncOnce())
        } catch {
            return .failure(error)
        }
    }

    /// Stores a clip captured on this device, honouring the privacy filter.
    @discardableResult
    static func ingest(_ clip: NewClip) -> Bool {
        guard let store else { return false }
        let text = clip.representations.first { $0.uti == UTI.utf8PlainText }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? clip.preview
        let context = PrivacyFilter.Context(
            text: text,
            sourceBundleID: nil,
            skipOneTimeCodes: PasteHubDefaults.skipOneTimeCodes,
            kind: clip.kind
        )
        guard PrivacyFilter.shouldCapture(context) else { return false }
        return (try? store.ingest(clip, historyLimit: historyLimit)) != nil
    }

    static func copyToPasteboard(_ item: ClipItem, plainText: Bool = false) {
        guard let store, let reps = try? store.representations(for: item.id), !reps.isEmpty else { return }
        ownPasteboardChangeCount = UIPasteboardCodec.write(reps, to: .general, plainText: plainText)
        try? store.markUsed(id: item.id)
    }
}
