import AppKit
import KeyboardShortcuts

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "PasteHub")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "PasteHub"
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: "显示剪贴板历史",
            action: #selector(showOverlay),
            keyEquivalent: ""
        )
        showItem.target = self
        showItem.setShortcut(for: .togglePanel)
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 PasteHub",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func showOverlay() {
        AppEnvironment.shared.toggleOverlay()
    }

    @objc private func openSettings() {
        AppEnvironment.shared.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
