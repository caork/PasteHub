import AppKit

@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage {
        let key = bundleID ?? ""
        if let cached = cache[key] {
            return cached
        }
        let image: NSImage
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let fallback = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) {
            image = fallback
        } else {
            image = NSImage(size: NSSize(width: OverlayMetrics.iconSize, height: OverlayMetrics.iconSize))
        }
        image.size = NSSize(width: OverlayMetrics.iconSize, height: OverlayMetrics.iconSize)
        cache[key] = image
        return image
    }
}

@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static func string(from date: Date) -> String {
        if abs(Date().timeIntervalSince(date)) < 10 {
            return "刚刚"
        }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
