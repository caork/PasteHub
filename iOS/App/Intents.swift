import AppIntents
import PasteHubCore
import UIKit

/// Shortcuts action: "发送到 PasteHub". Pair it with Shortcuts' "Get Clipboard"
/// and bind the shortcut to Back Tap for a one-gesture iPhone → Mac copy.
struct SendTextToPasteHub: AppIntent {
    static let title: LocalizedStringResource = "发送文本到 PasteHub"
    static let description = IntentDescription("保存文本到 PasteHub 历史，并同步到其他设备。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let clip = ClipFactory.make(text: text) else {
            return .result(dialog: "内容为空")
        }
        guard SharedEnvironment.ingest(clip) else {
            return .result(dialog: "已跳过（隐私过滤）")
        }
        return .result(dialog: await SendResult.dialog())
    }
}

struct SendImageToPasteHub: AppIntent {
    static let title: LocalizedStringResource = "发送图片到 PasteHub"
    static let description = IntentDescription("保存图片到 PasteHub 历史，并同步到其他设备。超过 5 MB 的图片只保存在本机。")
    static let openAppWhenRun = false

    @Parameter(title: "图片")
    var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uiImage = UIImage(data: image.data), let clip = UIPasteboardCodec.makeImageClip(uiImage) else {
            return .result(dialog: "无法读取图片")
        }
        SharedEnvironment.ingest(clip)
        return .result(dialog: await SendResult.dialog())
    }
}

struct SendClipboardToPasteHub: AppIntent {
    static let title: LocalizedStringResource = "发送剪贴板到 PasteHub"
    static let description = IntentDescription("读取当前剪贴板，保存并同步到其他设备。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let clip = UIPasteboardCodec.capture(.general) else {
            return .result(dialog: "剪贴板是空的")
        }
        guard SharedEnvironment.ingest(clip) else {
            return .result(dialog: "已跳过（隐私过滤）")
        }
        SharedEnvironment.lastCapturedChangeCount = UIPasteboard.general.changeCount
        return .result(dialog: await SendResult.dialog())
    }
}

@MainActor
enum SendResult {
    static func dialog() async -> IntentDialog {
        switch await SharedEnvironment.syncIfConfigured() {
        case nil:
            return "已保存到 PasteHub（未开启同步）"
        case .success:
            return "已发送"
        case let .failure(error):
            return "已保存，同步失败：\(error.localizedDescription)"
        }
    }
}

struct PasteHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendClipboardToPasteHub(),
            phrases: ["用 \(.applicationName) 发送剪贴板", "Send clipboard to \(.applicationName)"],
            shortTitle: "发送剪贴板",
            systemImageName: "doc.on.clipboard"
        )
    }
}
