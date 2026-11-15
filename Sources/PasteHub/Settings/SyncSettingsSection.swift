import PasteHubCore
import SwiftUI

/// "远端同步" settings: server address + sync key. Sync is off until both are saved.
struct SyncSettingsSection: View {
    @Bindable private var sync = AppEnvironment.shared.sync
    @State private var serverAddress = ""
    @State private var syncKey = ""
    @State private var deviceName = ""
    @State private var autoCopy = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        Section("远端同步") {
            TextField("服务器地址", text: $serverAddress, prompt: Text("https://paste.example.com"))
            SecureField("同步密钥", text: $syncKey, prompt: Text("phs1_…"))
            TextField("设备名称", text: $deviceName, prompt: Text(SyncController.defaultDeviceName))
            Toggle("收到其他设备的新内容时，自动写入本机剪贴板", isOn: $autoCopy)
                .onChange(of: autoCopy) { _, value in sync.settings.autoCopyRemote = value }

            Text("填好服务器地址和同步密钥后才会同步。所有设备填同一个密钥即可互通；内容在本机加密，服务器看不到明文。超过 5 MB 的内容只保存在本机。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button(sync.isConfigured ? "保存并重新连接" : "保存并连接") {
                    Task { await save() }
                }
                .disabled(isSaving || serverAddress.isEmpty || syncKey.isEmpty)
                if sync.isConfigured {
                    Button("立即同步") { sync.syncNow() }
                    Button("关闭同步", role: .destructive) {
                        sync.disconnect()
                        syncKey = ""
                    }
                }
                if isSaving {
                    ProgressView().controlSize(.small)
                }
            }
            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            statusRow
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch sync.state {
        case .off:
            LabeledContent("状态", value: "未开启")
        case .connecting:
            LabeledContent("状态", value: "正在连接…")
        case .syncing:
            LabeledContent("状态", value: "正在同步…")
        case let .idle(date):
            LabeledContent("状态") {
                Text("已同步 · \(date.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.green)
            }
        case let .failed(message):
            LabeledContent("状态") {
                Text(message).foregroundStyle(.orange)
            }
        }
        if sync.isConfigured, sync.pendingCount > 0 {
            LabeledContent("待上传", value: "\(sync.pendingCount) 条")
        }
    }

    private func load() {
        serverAddress = sync.settings.serverAddress
        syncKey = sync.settings.syncKey
        deviceName = sync.settings.deviceName
        autoCopy = sync.settings.autoCopyRemote
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await sync.save(serverAddress: serverAddress, syncKey: syncKey, deviceName: deviceName)
            serverAddress = sync.settings.serverAddress
        } catch {
            saveError = error.localizedDescription
        }
    }
}
