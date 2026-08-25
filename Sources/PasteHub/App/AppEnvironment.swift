import AppKit
import Foundation
import KeyboardShortcuts
import PasteHubCore

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.control]))
}

enum PasteHubHotKey {
    private static let migratedControlVKey = "hotkeyMigratedToControlV"

    static func migrateLegacyShortcutIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedControlVKey) else { return }
        let controlV = KeyboardShortcuts.Shortcut(.v, modifiers: [.control])
        let legacy = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
        let current = KeyboardShortcuts.getShortcut(for: .togglePanel)
        if current == nil || current == legacy {
            KeyboardShortcuts.setShortcut(controlV, for: .togglePanel)
        }
        UserDefaults.standard.set(true, forKey: migratedControlVKey)
    }
}

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let store: ClipStore
    let watcher: ClipboardWatcher
    let pasteEngine: PasteEngine
    let overlay: OverlayController
    let updater = UpdateChecker()

    private init() {
        do {
            store = try ClipStore.openDefault()
        } catch {
            fatalError("Failed to open PasteHub database: \(error)")
        }
        watcher = ClipboardWatcher(store: store)
        pasteEngine = PasteEngine(store: store, watcher: watcher)
        overlay = OverlayController(store: store, pasteEngine: pasteEngine)
        pasteEngine.overlay = overlay
    }

    func start() {
        PasteHubHotKey.migrateLegacyShortcutIfNeeded()
        watcher.start()
        overlay.registerHotKey()
        updater.startAutomaticChecks()
    }

    func prepareToQuit() {
        overlay.hide()
        if PasteHubDefaults.clearHistoryOnQuit {
            try? store.deleteUnpinned()
        }
    }

    func toggleOverlay() {
        overlay.toggle()
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    func checkForUpdates() {
        SettingsWindowController.shared.show()
        Task { await updater.checkForUpdates(userInitiated: true) }
    }
}
