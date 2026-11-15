import PasteHubCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share extension: "PasteHub" in the share sheet saves text, links or an image
/// to history and syncs it to the other devices.
final class ShareViewController: UIViewController {
    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(status: status) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await handle() }
    }

    private func handle() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        var saved = 0
        for provider in providers {
            if let clip = await clip(from: provider), SharedEnvironment.ingest(clip) {
                saved += 1
            }
        }
        guard saved > 0 else {
            status.message = "没有可保存的内容"
            status.done = true
            return
        }
        switch await SharedEnvironment.syncIfConfigured() {
        case nil: status.message = "已保存到 PasteHub（未开启同步）"
        case .success: status.message = "已发送到其他设备"
        case let .failure(error): status.message = "已保存，同步失败：\(error.localizedDescription)"
        }
        status.done = true
        try? await Task.sleep(for: .seconds(0.8))
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func clip(from provider: NSItemProvider) async -> NewClip? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await loadData(provider, type: .image),
           let image = UIImage(data: data)
        {
            return UIPasteboardCodec.makeImageClip(image)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
        {
            return ClipFactory.make(text: url.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
        {
            return ClipFactory.make(text: text)
        }
        return nil
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}

@MainActor
@Observable
final class ShareStatus {
    var message = "正在保存…"
    var done = false
}

struct ShareView: View {
    let status: ShareStatus
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if status.done {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            } else {
                ProgressView()
            }
            Text(status.message).multilineTextAlignment(.center)
            Button("完成", action: close)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
