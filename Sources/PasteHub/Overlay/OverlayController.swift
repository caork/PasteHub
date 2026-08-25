import AppKit
import KeyboardShortcuts
import PasteHubCore
import SwiftUI

@MainActor
final class OverlayController: NSObject {
    private let panel = OverlayPanel()
    private let model: OverlayViewModel
    private let pasteEngine: PasteEngine
    private let hostingView: NSHostingView<OverlayView>
    private var pasteTarget: NSRunningApplication?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var clickMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(store: ClipStore, pasteEngine: PasteEngine) {
        self.model = OverlayViewModel(store: store)
        self.pasteEngine = pasteEngine

        let hosting = NSHostingView(rootView: OverlayView(
            model: model,
            onPaste: { _, _ in },
            onHide: {},
            onContentChange: {}
        ))
        self.hostingView = hosting
        super.init()

        hosting.rootView = OverlayView(
            model: model,
            onPaste: { [weak self] item, plainText in
                self?.paste(item, plainText: plainText)
            },
            onHide: { [weak self] in
                self?.hide()
            },
            onContentChange: { [weak self] in
                self?.updateFramePreservingTop()
            }
        )
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = OverlayMetrics.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        model.onContentChange = { [weak self] in
            self?.updateFramePreservingTop()
        }
    }

    func registerHotKey() {
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            Task { @MainActor in
                self?.handleHotKey()
            }
        }
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        pasteTarget = NSWorkspace.shared.frontmostApplication
        model.prepareForDisplay()
        positionNearMouse()
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    func hide() {
        removeMonitors()
        if panel.isVisible {
            panel.orderOut(nil)
        }
        pasteTarget = nil
    }

    func paste(_ item: ClipItem, plainText: Bool) {
        let target = pasteTarget
        pasteEngine.paste(item, into: target, plainText: plainText)
    }

    private func handleHotKey() {
        if isVisible {
            if let item = model.selectedItem() {
                paste(item, plainText: false)
            } else {
                hide()
            }
        } else {
            show()
        }
    }

    private func preferredSize() -> NSSize {
        NSSize(
            width: OverlayMetrics.width,
            height: OverlayMetrics.height(
                itemCount: model.items.count,
                showAxBanner: !model.accessibilityTrusted
            )
        )
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = preferredSize()
        var x = mouse.x - 16
        var y = mouse.y - size.height - 12
        if y < visible.minY + 8 {
            y = mouse.y + 12
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        syncHostingFrame()
    }

    private func updateFramePreservingTop() {
        guard isVisible else { return }
        let size = preferredSize()
        var frame = panel.frame
        let maxY = frame.maxY
        frame.size = size
        frame.origin.y = maxY - size.height
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(frame, display: true)
        syncHostingFrame()
    }

    private func syncHostingFrame() {
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
    }

    private func installMonitors() {
        removeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handleKey(event) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, !self.panel.isKeyWindow else { return }
            _ = self.handleKey(event)
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // escape
            hide()
            return true
        case 125:
            model.moveSelection(1)
            return true
        case 126:
            model.moveSelection(-1)
            return true
        case 36, 76:
            if let item = model.selectedItem() {
                paste(item, plainText: flags.contains(.shift))
            }
            return true
        case 51:
            if flags.contains(.command) || model.query.isEmpty {
                model.deleteSelected()
                return true
            }
            return false
        case 35:
            if flags.contains(.command) {
                model.togglePinSelected()
                return true
            }
            return false
        default:
            if flags.contains(.command), let number = Self.numberKeyMap[event.keyCode],
               let item = model.item(atVisibleIndex: number - 1)
            {
                paste(item, plainText: flags.contains(.shift))
                return true
            }
            // Let the global hotkey handler own Control+V; keep it out of the search field.
            if event.keyCode == 9, flags.contains(.control), !flags.contains(.command) {
                return true
            }
            return false
        }
    }

    private static let numberKeyMap: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
}
