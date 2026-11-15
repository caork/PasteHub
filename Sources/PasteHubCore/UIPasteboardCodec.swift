#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// iOS counterpart of `PasteboardCodec`: converts between UIPasteboard / UIImage and clips.
public enum UIPasteboardCodec {
    public static func capture(_ pasteboard: UIPasteboard) -> NewClip? {
        if pasteboard.hasImages, let image = pasteboard.image, let clip = makeImageClip(image) {
            return clip
        }
        if let text = pasteboard.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipFactory.make(
                text: text,
                rtf: pasteboard.data(forPasteboardType: UTType.rtf.identifier),
                html: pasteboard.data(forPasteboardType: UTType.html.identifier)
            )
        }
        if let url = pasteboard.url {
            return ClipFactory.make(text: url.absoluteString)
        }
        return nil
    }

    public static func makeImageClip(_ image: UIImage, sourceAppName: String? = nil) -> NewClip? {
        guard let png = image.pngData() else { return nil }
        let pixelWidth = Int((image.size.width * image.scale).rounded())
        let pixelHeight = Int((image.size.height * image.scale).rounded())
        return ClipFactory.makeImage(
            png: png,
            thumbnail: thumbnailPNG(for: image) ?? png,
            width: max(1, pixelWidth),
            height: max(1, pixelHeight),
            sourceAppName: sourceAppName
        )
    }

    public static func thumbnailPNG(for image: UIImage) -> Data? {
        let maxEdge = CGFloat(PasteHubDefaults.thumbnailMaxEdge)
        let longest = max(image.size.width * image.scale, image.size.height * image.scale, 1)
        let scale = min(maxEdge / longest, 1)
        let size = CGSize(
            width: max(1, (image.size.width * image.scale * scale).rounded()),
            height: max(1, (image.size.height * image.scale * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Writes a stored clip to the pasteboard. Returns the resulting change count.
    @discardableResult
    public static func write(_ representations: [ClipRepresentation], to pasteboard: UIPasteboard, plainText: Bool = false) -> Int {
        var item: [String: Any] = [:]
        for rep in representations where rep.uti != UTI.thumbnailPNG {
            if plainText, rep.uti != UTI.utf8PlainText { continue }
            if rep.uti == UTI.utf8PlainText, let text = String(data: rep.data, encoding: .utf8) {
                item[UTType.utf8PlainText.identifier] = text
            } else {
                item[rep.uti] = rep.data
            }
        }
        pasteboard.setItems(item.isEmpty ? [] : [item])
        return pasteboard.changeCount
    }
}
#endif
