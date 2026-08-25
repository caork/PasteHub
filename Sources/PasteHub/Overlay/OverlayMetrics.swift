import CoreGraphics

enum OverlayMetrics {
    static let width: CGFloat = 292
    static let cornerRadius: CGFloat = 16
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 32
    static let footerHeight: CGFloat = 18
    static let axBannerHeight: CGFloat = 16
    static let chromePadding: CGFloat = 8
    static let maxVisibleRows = 7
    static let minHeight: CGFloat = 108
    static let iconSize: CGFloat = 16

    static func height(itemCount: Int, showAxBanner: Bool) -> CGFloat {
        let rows = itemCount == 0 ? 3 : min(max(itemCount, 1), maxVisibleRows)
        var height = chromePadding + headerHeight + footerHeight + CGFloat(rows) * rowHeight
        if showAxBanner {
            height += axBannerHeight
        }
        return max(height, minHeight)
    }
}
