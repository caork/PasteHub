import AppKit
import PasteHubAX

@MainActor
enum AccessibilityAuthorizer {
    private static var didOfferThisSession = false

    static var isTrusted: Bool {
        PasteHubAXIsTrusted(false)
    }

    @discardableResult
    static func prompt() -> Bool {
        PasteHubAXIsTrusted(true)
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func requestIfNeeded() {
        guard !isTrusted else { return }
        _ = prompt()
        if isTrusted { return }
        guard !didOfferThisSession else { return }
        didOfferThisSession = true
        openSystemSettings()
        presentAlert()
    }

    static func requestOnLaunch() {
        guard !isTrusted else { return }
        _ = prompt()
        if isTrusted { return }
        openSystemSettings()
        presentAlert()
    }

    private static func presentAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PasteHub 还不能模拟 ⌘V"
        alert.informativeText = """
        系统里勾选的可能是旧的 PasteHub（dist 目录或 ad-hoc 签名）。
        请只保留并勾选这一份：

        \(Bundle.main.bundlePath)

        勾选后完全退出 PasteHub 再打开。没有这项权限时，点击历史只会写入剪贴板，还需要你再按一次 ⌘V。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "我已勾选，重新检测")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
        NSSound.beep()
    }
}
