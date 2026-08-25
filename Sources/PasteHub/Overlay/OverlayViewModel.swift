import Foundation
import Observation
import PasteHubCore

@MainActor
@Observable
final class OverlayViewModel {
    var query = ""
    var items: [ClipItem] = []
    var thumbnails: [UUID: Data] = [:]
    var selectedID: UUID?
    var keyboardScrollID: UUID?
    var accessibilityTrusted = AccessibilityAuthorizer.isTrusted
    var onContentChange: (() -> Void)?

    private let store: ClipStore

    var selectedIndex: Int {
        guard let selectedID else { return 0 }
        return items.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    init(store: ClipStore) {
        self.store = store
        NotificationCenter.default.addObserver(
            forName: .pasteHubStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadIfNeeded()
            }
        }
    }

    func prepareForDisplay() {
        query = ""
        accessibilityTrusted = AccessibilityAuthorizer.isTrusted
        reload()
        selectedID = items.first?.id
    }

    func reload() {
        do {
            items = try store.items(matching: query)
            let imageIDs = items.filter { $0.kind == .image }.map(\.id)
            thumbnails = try store.thumbnails(for: imageIDs)
        } catch {
            items = []
            thumbnails = [:]
            NSLog("PasteHub: search failed: \(error)")
        }
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            onContentChange?()
            return
        }
        selectedID = items.first?.id
        onContentChange?()
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), items.count - 1)
        selectedID = items[next].id
        keyboardScrollID = selectedID
    }

    func selectedItem() -> ClipItem? {
        guard let selectedID else { return items.first }
        return items.first(where: { $0.id == selectedID }) ?? items.first
    }

    func item(atVisibleIndex index: Int) -> ClipItem? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func deleteSelected() {
        guard let item = selectedItem() else { return }
        let index = selectedIndex
        do {
            try store.delete(id: item.id)
            reload()
            if items.isEmpty {
                selectedID = nil
            } else {
                selectedID = items[min(index, items.count - 1)].id
            }
        } catch {
            NSLog("PasteHub: delete failed: \(error)")
        }
    }

    func togglePinSelected() {
        guard let item = selectedItem() else { return }
        do {
            try store.setPinned(id: item.id, pinned: !item.pinned)
            reload()
            selectedID = item.id
        } catch {
            NSLog("PasteHub: pin failed: \(error)")
        }
    }

    private func reloadIfNeeded() {
        // Keep the open panel in sync with new copies.
        reload()
    }
}
