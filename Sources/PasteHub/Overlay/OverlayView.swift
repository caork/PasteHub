import AppKit
import KeyboardShortcuts
import PasteHubCore
import SwiftUI

struct OverlayView: View {
    @Bindable var model: OverlayViewModel
    var onPaste: (ClipItem, Bool) -> Void
    var onHide: () -> Void
    var onContentChange: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            header
            content
            footer
        }
        .padding(6)
        .frame(width: OverlayMetrics.width, height: panelHeight, alignment: .top)
        .modifier(OverlayChrome())
        .onChange(of: model.query) { _, _ in
            model.reload()
            onContentChange()
        }
        .onChange(of: model.items.count) { _, _ in
            onContentChange()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Text(shortcutBadge)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !model.accessibilityTrusted {
                Button {
                    AccessibilityAuthorizer.requestIfNeeded()
                } label: {
                    Text("需要辅助功能才能直接粘贴，点击授权")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
        }
    }

    private var panelHeight: CGFloat {
        OverlayMetrics.height(itemCount: model.items.count, showAxBanner: !model.accessibilityTrusted)
    }

    private var listHeight: CGFloat {
        let rows = model.items.isEmpty ? 3 : min(max(model.items.count, 1), OverlayMetrics.maxVisibleRows)
        return CGFloat(rows) * OverlayMetrics.rowHeight
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            Text(model.query.isEmpty ? "复制文本或图片后会出现在这里" : "没有匹配项")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: listHeight, maxHeight: listHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                onPaste(item, false)
                            } label: {
                                ClipRowView(
                                    item: item,
                                    index: index,
                                    isSelected: item.id == model.selectedID,
                                    thumbnail: model.thumbnails[item.id]
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { model.selectedID = item.id }
                            }
                            .contextMenu {
                                Button("粘贴") { onPaste(item, false) }
                                if item.kind != .image {
                                    Button("粘贴为纯文本") { onPaste(item, true) }
                                }
                                Button(item.pinned ? "取消固定" : "固定") {
                                    model.selectedID = item.id
                                    model.togglePinSelected()
                                }
                                Button("删除", role: .destructive) {
                                    model.selectedID = item.id
                                    model.deleteSelected()
                                }
                            }
                            .id(item.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: listHeight)
                .onChange(of: model.keyboardScrollID) { _, newValue in
                    if let newValue {
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerHint("↑↓")
            footerHint("↩ 粘贴")
            footerHint("⌫")
            footerHint("esc")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func footerHint(_ text: String) -> some View {
        Text(text)
    }

    private var shortcutBadge: String {
        KeyboardShortcuts.getShortcut(for: .togglePanel)?.description ?? "⌃V"
    }
}

private struct ClipRowView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let thumbnail: Data?

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                leadingIcon
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.orange)
                        .offset(x: 3, y: -3)
                }
            }
            .frame(width: leadingSize, height: leadingSize)

            Text(item.preview.isEmpty ? "(empty)" : item.preview)
                .font(item.kind == .image
                    ? .system(size: 12)
                    : (ClipFactory.looksLikeCode(item.preview)
                        ? .system(size: 12, design: .monospaced)
                        : .system(size: 12)))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            Text(RelativeTime.string(from: item.lastUsedAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: OverlayMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
        )
    }

    private var leadingSize: CGFloat {
        item.kind == .image ? OverlayMetrics.thumbnailSize : OverlayMetrics.iconSize
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if item.kind == .image, let thumbnail, let image = NSImage(data: thumbnail) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: OverlayMetrics.thumbnailSize, height: OverlayMetrics.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if item.kind == .image {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: OverlayMetrics.thumbnailSize, height: OverlayMetrics.thumbnailSize)
        } else {
            Image(nsImage: AppIconCache.icon(for: item.sourceBundleID))
                .resizable()
                .frame(width: OverlayMetrics.iconSize, height: OverlayMetrics.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}

private struct OverlayChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .continuous)
            )
        } else {
            content.background { VisualEffectBackground() }
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = OverlayMetrics.cornerRadius
        view.layer?.cornerCurve = .continuous
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
