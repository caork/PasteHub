import PasteHubCore
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if !model.isSyncConfigured {
                    Section {
                        Button("设置远端同步服务器") { showingSettings = true }
                    } footer: {
                        Text("填好服务器地址和同步密钥后，iPhone 与 Mac 的剪贴板历史会互相同步。")
                    }
                }
                ForEach(model.items) { item in
                    ClipRow(item: item, thumbnail: model.thumbnails[item.id])
                        .contentShape(Rectangle())
                        .onTapGesture { model.copy(item) }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) { model.delete(item) }
                        }
                        .swipeActions(edge: .leading) {
                            Button(item.pinned ? "取消固定" : "固定") { model.togglePin(item) }
                                .tint(.orange)
                        }
                        .contextMenu {
                            Button("复制") { model.copy(item) }
                            if item.kind != .image {
                                Button("复制为纯文本") { model.copy(item, plainText: true) }
                            }
                            Button(item.pinned ? "取消固定" : "固定") { model.togglePin(item) }
                            Button("删除", role: .destructive) { model.delete(item) }
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView(
                        "还没有历史",
                        systemImage: "doc.on.clipboard",
                        description: Text("点右上角的「粘贴」保存当前剪贴板，或在 Mac 上复制内容后下拉同步。")
                    )
                }
            }
            .searchable(text: $model.query, prompt: "搜索历史")
            .refreshable { await model.sync() }
            .navigationTitle("PasteHub")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PasteButton(supportedContentTypes: [.image, .url, .plainText]) { providers in
                        model.ingest(providers: providers)
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .safeAreaInset(edge: .bottom) {
                SyncStatusLabel(state: model.syncState)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 60)
                        .task {
                            try? await Task.sleep(for: .seconds(1.2))
                            model.toast = nil
                        }
                }
            }
        }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let thumbnail: Data?

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.isEmpty ? "（空）" : item.preview)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if item.pinned {
                        Image(systemName: "pin.fill").foregroundStyle(.orange)
                    }
                    if let origin = item.originDeviceName {
                        Label(origin, systemImage: "laptopcomputer.and.iphone")
                    }
                    if item.syncState == .tooLarge {
                        Label("超过 5 MB，未同步", systemImage: "icloud.slash")
                    }
                    Text(item.lastUsedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .image, let thumbnail, let image = UIImage(data: thumbnail) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch item.kind {
        case .url: "link"
        case .image: "photo"
        case .richText: "doc.richtext"
        default: "text.alignleft"
        }
    }
}

struct SyncStatusLabel: View {
    let state: AppModel.SyncState

    var body: some View {
        switch state {
        case .off:
            Text("未开启同步").font(.caption).foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) { ProgressView(); Text("正在同步…") }.font(.caption)
        case let .idle(date):
            Text("已同步 · \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
    }
}
