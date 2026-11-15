import PasteHubCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var serverAddress = SharedEnvironment.settings.serverAddress
    @State private var syncKey = SharedEnvironment.settings.syncKey
    @State private var deviceName = SharedEnvironment.settings.deviceName
    @State private var autoCapture = SharedEnvironment.autoCaptureOnForeground
    @State private var isSaving = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址", text: $serverAddress, prompt: Text("https://paste.example.com"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("同步密钥 phs1_…", text: $syncKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("设备名称", text: $deviceName, prompt: Text(SharedEnvironment.defaultDeviceName))
                    Button(isSaving ? "正在连接…" : "保存并连接") { Task { await save() } }
                        .disabled(isSaving || serverAddress.isEmpty || syncKey.isEmpty)
                    if model.isSyncConfigured {
                        Button("关闭同步", role: .destructive) { disconnect() }
                    }
                    if let message {
                        Text(message).foregroundStyle(messageIsError ? .red : .green)
                    }
                } header: {
                    Text("远端同步")
                } footer: {
                    Text("填好服务器地址和同步密钥后才会同步。所有设备填同一个密钥即可互通；内容在本机加密，服务器看不到明文。超过 5 MB 的内容只保存在本机。")
                }

                Section {
                    Toggle("回到 App 时读取剪贴板", isOn: $autoCapture)
                        .onChange(of: autoCapture) { _, value in SharedEnvironment.autoCaptureOnForeground = value }
                } header: {
                    Text("采集")
                } footer: {
                    Text("开启后每次回到 PasteHub 都会读取一次剪贴板。想避免系统询问，可在「设置 → PasteHub → 从其他 App 粘贴」里选择「允许」。也可以用快捷指令「发送到 PasteHub」，配合「轻点背面」一键发送。")
                }

                Section("PasteHub 键盘") {
                    Text("在「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」中添加 PasteHub，并打开「允许完全访问」，即可在任意 App 里插入同步过来的内容。")
                        .font(.callout)
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard let url = SyncConfiguration.normalizeServerURL(serverAddress) else {
            show("服务器地址无效", error: true)
            return
        }
        let key = syncKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try SyncKeys(syncKey: key)
            let probe = try SyncEngine(
                store: ClipStore.inMemory(),
                configuration: SyncConfiguration(serverURL: url, syncKey: key, deviceName: deviceName)
            )
            try await probe.verifyConnection()
        } catch {
            show(error.localizedDescription, error: true)
            return
        }
        SharedEnvironment.settings.serverAddress = url.absoluteString
        SharedEnvironment.settings.syncKey = key
        SharedEnvironment.settings.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        serverAddress = url.absoluteString
        show("已连接", error: false)
        await model.sync()
    }

    private func disconnect() {
        SharedEnvironment.settings.syncKey = ""
        syncKey = ""
        if let store = SharedEnvironment.store {
            try? SyncEngine.deactivate(store: store)
        }
        show("已关闭同步", error: false)
        Task { await model.sync() }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
