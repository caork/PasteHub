import AppKit
import ApplicationServices
import CoreGraphics
import PasteHubCore

@MainActor
final class PasteEngine {
    private let store: ClipStore
    private let watcher: ClipboardWatcher
    weak var overlay: OverlayController?

    /// Left Command device bit. `maskCommand` alone is ignored by some apps.
    private static let leftCommandFlag = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)

    init(store: ClipStore, watcher: ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
    }

    func paste(_ item: ClipItem, into target: NSRunningApplication?, plainText: Bool) {
        let representations: [ClipRepresentation]
        do {
            representations = try store.representations(for: item.id)
        } catch {
            NSLog("PasteHub: failed to load representations: \(error)")
            return
        }
        guard !representations.isEmpty else { return }

        let text = representations
            .first(where: { $0.uti == UTI.utf8PlainText })
            .flatMap { String(data: $0.data, encoding: .utf8) }

        watcher.performSelfWrite {
            PasteboardCodec.write(representations, to: .general, plainText: plainText)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            overlay?.hide()
            await restoreFocus(to: target)
            try? await Task.sleep(for: .milliseconds(120))

            if let text, insertViaAccessibility(text) {
                try? store.markUsed(id: item.id)
                return
            }

            sendCommandV()
            if !AccessibilityAuthorizer.isTrusted {
                pasteViaSystemEvents()
                AccessibilityAuthorizer.requestIfNeeded()
            }
            try? store.markUsed(id: item.id)
        }
    }

    private func restoreFocus(to target: NSRunningApplication?) async {
        guard let target, !target.isTerminated else { return }
        if target.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        NSApp.yieldActivation(to: target)
        _ = target.activate(from: .current, options: [.activateAllWindows])
    }

    /// Insert at the caret of the focused AX element. Works in many AppKit fields; Electron usually fails.
    private func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let copyError = AXUIElementCopyAttributeValue(
            system,
            "AXFocusedUIElement" as CFString,
            &focused
        )
        guard copyError == .success, let focused else { return false }
        let element = focused as! AXUIElement
        let setError = AXUIElementSetAttributeValue(
            element,
            "AXSelectedText" as CFString,
            text as CFString
        )
        return setError == .success
    }

    private func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        for modifierKey: CGKeyCode in [0x3B, 0x3E, 0x3A, 0x3D] {
            if let up = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: false) {
                up.flags = []
                up.post(tap: .cgSessionEventTap)
            }
        }

        let keyCode: CGKeyCode = 0x09
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }
        down.flags = Self.leftCommandFlag
        up.flags = Self.leftCommandFlag
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func pasteViaSystemEvents() {
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("PasteHub: System Events paste failed: \(error)")
        }
    }
}
