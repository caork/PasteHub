import KeyboardShortcuts
import PasteHubCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(PasteHubDefaults.historyLimitKey) private var historyLimit = PasteHubDefaults.defaultHistoryLimit
    @AppStorage(PasteHubDefaults.skipOneTimeCodesKey) private var skipOneTimeCodes = true
    @AppStorage(PasteHubDefaults.clearHistoryOnQuitKey) private var clearHistoryOnQuit = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var accessibilityTrusted = AccessibilityAuthorizer.isTrusted
    @State private var didClear = false

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: launchAtLoginBinding)
                KeyboardShortcuts.Recorder("弹出历史（默认 ⌃V）", name: .togglePanel)
                Stepper(value: $historyLimit, in: 20...1000, step: 10) {
                    Text("普通历史上限：\(historyLimit) 条")
                }
                Toggle("退出时清空未固定历史", isOn: $clearHistoryOnQuit)
            }

            Section("权限") {
                LabeledContent("辅助功能") {
                    Text(accessibilityTrusted ? "已授予" : "未授予")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                }
                Text("没有辅助功能权限时，选中条目只会写回系统剪贴板，还需要再按一次 ⌘V。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("请求权限") {
                        AccessibilityAuthorizer.prompt()
                        accessibilityTrusted = AccessibilityAuthorizer.isTrusted
                    }
                    Button("打开系统设置") {
                        AccessibilityAuthorizer.openSystemSettings()
                    }
                    Button("重新检测") {
                        accessibilityTrusted = AccessibilityAuthorizer.isTrusted
                    }
                }
            }

            Section("隐私") {
                Toggle("不保存验证码 / OTP", isOn: $skipOneTimeCodes)
                Text("默认排除：\(PrivacyFilter.blockedAppNames.joined(separator: "、"))。数据只存在本机，不做同步。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("清空全部历史", role: .destructive) {
                    try? AppEnvironment.shared.store.deleteAll()
                    didClear = true
                }
                if didClear {
                    Text("已清空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let launchError {
                Section {
                    Text(launchError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            accessibilityTrusted = AccessibilityAuthorizer.isTrusted
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLogin = LaunchAtLogin.isEnabled
                    launchError = nil
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                    launchError = "无法设置开机启动：\(error.localizedDescription)。把 App 放到 /Applications 后再试。"
                }
            }
        )
    }
}
