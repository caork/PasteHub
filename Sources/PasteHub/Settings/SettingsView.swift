import KeyboardShortcuts
import PasteHubCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(PasteHubDefaults.historyLimitKey) private var historyLimit = PasteHubDefaults.defaultHistoryLimit
    @AppStorage(PasteHubDefaults.skipOneTimeCodesKey) private var skipOneTimeCodes = true
    @AppStorage(PasteHubDefaults.clearHistoryOnQuitKey) private var clearHistoryOnQuit = false
    @AppStorage(PasteHubDefaults.autoCheckUpdatesKey) private var autoCheckUpdates = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var accessibilityTrusted = AccessibilityAuthorizer.isTrusted
    @State private var didClear = false
    @Bindable private var updater = AppEnvironment.shared.updater

    var body: some View {
        Form {
            generalSection
            updateSection
            permissionSection
            privacySection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            accessibilityTrusted = AccessibilityAuthorizer.isTrusted
        }
    }

    private var generalSection: some View {
        Section("通用") {
            Toggle("登录时启动", isOn: launchAtLoginBinding)
            Text(LaunchAtLogin.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if LaunchAtLogin.status == .requiresApproval {
                Button("打开登录项设置") {
                    LaunchAtLogin.openLoginItemsSettings()
                }
            }
            if let launchError {
                Text(launchError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            KeyboardShortcuts.Recorder("弹出历史", name: .togglePanel)
            Stepper(value: $historyLimit, in: 20...1000, step: 10) {
                Text("普通历史上限：\(historyLimit) 条")
            }
            Toggle("退出时清空未固定历史", isOn: $clearHistoryOnQuit)
        }
    }

    private var updateSection: some View {
        Section("更新") {
            LabeledContent("当前版本", value: updater.currentVersion)
            Toggle("自动检查更新", isOn: $autoCheckUpdates)
            Text("从 GitHub Releases 检查。有新版本时会询问是否下载安装。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("检查更新") {
                    Task { await updater.checkForUpdates(userInitiated: true) }
                }
                .disabled(isBusy)
                Button("打开 Releases") {
                    NSWorkspace.shared.open(updater.githubReleasesURL)
                }
            }
            updateStatusView
            if case let .available(version, _, _, _) = updater.status {
                Button("下载并安装 \(version)") {
                    Task { await updater.downloadAndStage() }
                }
            }
            if case let .readyToInstall(url, version) = updater.status {
                Button("安装 \(version) 并重启") {
                    updater.applyStagedInstall(appURL: url)
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updater.status {
        case .idle:
            EmptyView()
        case .checking:
            Text("正在检查…")
                .foregroundStyle(.secondary)
        case .upToDate:
            Text("已是最新版本")
                .foregroundStyle(.secondary)
        case let .available(version, notes, _, _):
            Text("发现 \(version)")
                .foregroundStyle(.green)
            if !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        case .downloading:
            Text("正在下载…")
                .foregroundStyle(.secondary)
        case let .readyToInstall(_, version):
            Text("\(version) 已下载，可以安装")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private var permissionSection: some View {
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
                    _ = AccessibilityAuthorizer.prompt()
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
    }

    private var privacySection: some View {
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
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("GitHub", value: "caork/PasteHub")
            Button("打开项目主页") {
                if let url = URL(string: "https://github.com/caork/PasteHub") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var isBusy: Bool {
        switch updater.status {
        case .checking, .downloading: true
        default: false
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
                    if LaunchAtLogin.status == .requiresApproval {
                        LaunchAtLogin.openLoginItemsSettings()
                        launchError = "请在「登录项」里允许 PasteHub。"
                    }
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                    launchError = "无法设置开机启动：\(error.localizedDescription)。建议把 App 放到 /Applications 后再试。"
                }
            }
        )
    }
}
