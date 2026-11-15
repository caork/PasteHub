import PasteHubCore
import SwiftUI
import UIKit

/// PasteHub keyboard: browse clipboard history (including clips synced from
/// the Mac) and insert them into any app. Needs "Allow Full Access" for the
/// shared database and network sync.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.insertText = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        model.deleteBackward = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.insertReturn = { [weak self] in self?.textDocumentProxy.insertText("\n") }
        model.hasFullAccess = hasFullAccess

        let host = UIHostingController(rootView: KeyboardView(model: model, nextKeyboard: makeNextKeyboardButton()))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 280),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        model.refresh()
        Task { await model.sync() }
    }

    private func makeNextKeyboardButton() -> NextKeyboardButton {
        NextKeyboardButton(needsInputModeSwitchKey: needsInputModeSwitchKey) { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        }
    }
}

@MainActor
@Observable
final class KeyboardModel {
    var items: [ClipItem] = []
    var thumbnails: [UUID: Data] = [:]
    var hint: String?
    var hasFullAccess = false
    var isSyncing = false

    var insertText: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var insertReturn: () -> Void = {}

    func refresh() {
        guard hasFullAccess, let store = SharedEnvironment.store else { return }
        // Keep memory low: the extension only needs the recent list and small thumbnails.
        items = (try? store.items(matching: "", limit: 40)) ?? []
        thumbnails = (try? store.thumbnails(for: items.filter { $0.kind == .image }.map(\.id))) ?? [:]
    }

    func sync() async {
        guard hasFullAccess else { return }
        isSyncing = true
        await SharedEnvironment.syncIfConfigured()
        isSyncing = false
        refresh()
    }

    func use(_ item: ClipItem) {
        guard let store = SharedEnvironment.store else { return }
        if item.kind == .image {
            SharedEnvironment.copyToPasteboard(item)
            hint = "图片已复制，长按输入框选择「粘贴」"
        } else if let text = try? store.plainText(for: item.id) {
            insertText(text)
            try? store.markUsed(id: item.id)
        }
    }
}

struct NextKeyboardButton: UIViewRepresentable {
    let needsInputModeSwitchKey: Bool
    let configure: (UIButton) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        configure(button)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

struct KeyboardView: View {
    @Bindable var model: KeyboardModel
    let nextKeyboard: NextKeyboardButton

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullAccess {
                Text("请在「设置 → 通用 → 键盘 → PasteHub」中打开「允许完全访问」，才能读取历史和同步。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                Text(model.isSyncing ? "正在同步…" : "还没有历史")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.items) { item in
                            Button { model.use(item) } label: { KeyboardRow(item: item, thumbnail: model.thumbnails[item.id]) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
            if let hint = model.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }
            HStack(spacing: 12) {
                if nextKeyboard.needsInputModeSwitchKey {
                    nextKeyboard.frame(width: 44, height: 40)
                }
                if model.isSyncing {
                    ProgressView()
                }
                Spacer()
                keyButton(systemImage: "delete.left") { model.deleteBackward() }
                keyButton(systemImage: "return") { model.insertReturn() }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private func keyButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 52, height: 40)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct KeyboardRow: View {
    let item: ClipItem
    let thumbnail: Data?

    var body: some View {
        HStack(spacing: 8) {
            if item.kind == .image, let thumbnail, let image = UIImage(data: thumbnail) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(item.preview).lineLimit(2).font(.callout)
            Spacer(minLength: 4)
            if let origin = item.originDeviceName {
                Text(origin).font(.caption2).foregroundStyle(.secondary)
            }
            if item.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
