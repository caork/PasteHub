import AppKit
import Foundation

public enum PasteboardCodec {
    public static let selfWriteType = NSPasteboard.PasteboardType("com.kaitaocao.PasteHub.self-write")

    public static func capture(
        _ pasteboard: NSPasteboard,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> NewClip? {
        if pasteboard.string(forType: selfWriteType) != nil {
            return nil
        }

        let text = pasteboard.string(forType: .string)
        if let imageClip = captureImage(
            pasteboard,
            text: text,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        ) {
            return imageClip
        }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ClipFactory.make(
            text: text,
            rtf: pasteboard.data(forType: .rtf),
            html: pasteboard.data(forType: .html),
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
    }

    public static func write(
        _ representations: [ClipRepresentation],
        to pasteboard: NSPasteboard,
        plainText: Bool
    ) {
        pasteboard.clearContents()
        for representation in representations {
            if representation.uti == UTI.thumbnailPNG {
                continue
            }
            if plainText, representation.uti != UTI.utf8PlainText {
                continue
            }
            let type = NSPasteboard.PasteboardType(representation.uti)
            if type == .string || representation.uti == UTI.utf8PlainText,
               let text = String(data: representation.data, encoding: .utf8)
            {
                pasteboard.setString(text, forType: .string)
            } else {
                pasteboard.setData(representation.data, forType: type)
            }
        }
        pasteboard.setString("1", forType: selfWriteType)
    }

    public static func isSelfWrite(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.string(forType: selfWriteType) != nil
    }

    private static func captureImage(
        _ pasteboard: NSPasteboard,
        text: String?,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> NewClip? {
        guard let bitmap = bitmapPNG(from: pasteboard) else { return nil }
        guard ClipFactory.shouldCaptureAsImage(text: text, hasBitmap: true) else { return nil }
        let thumbnail = makeThumbnailPNG(from: bitmap.image) ?? bitmap.png
        return ClipFactory.makeImage(
            png: bitmap.png,
            thumbnail: thumbnail,
            width: bitmap.width,
            height: bitmap.height,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
    }

    private static func bitmapPNG(from pasteboard: NSPasteboard) -> (png: Data, image: NSImage, width: Int, height: Int)? {
        let jpegType = NSPasteboard.PasteboardType(UTI.jpeg)
        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) {
            let size = pixelSize(of: image)
            return (png, image, size.width, size.height)
        }
        if let jpeg = pasteboard.data(forType: jpegType), let image = NSImage(data: jpeg), let png = pngData(from: image) {
            let size = pixelSize(of: image)
            return (png, image, size.width, size.height)
        }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff), let png = pngData(from: image) {
            let size = pixelSize(of: image)
            return (png, image, size.width, size.height)
        }
        if let image = NSImage(pasteboard: pasteboard), let png = pngData(from: image) {
            let size = pixelSize(of: image)
            guard size.width > 0, size.height > 0 else { return nil }
            return (png, image, size.width, size.height)
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        let size = image.size
        return (max(1, Int(size.width.rounded())), max(1, Int(size.height.rounded())))
    }

    private static func makeThumbnailPNG(from image: NSImage) -> Data? {
        let pixels = pixelSize(of: image)
        let longest = max(pixels.width, pixels.height)
        let maxEdge = PasteHubDefaults.thumbnailMaxEdge
        let scale = min(CGFloat(maxEdge) / CGFloat(max(longest, 1)), 1)
        let width = max(1, Int((CGFloat(pixels.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(pixels.height) * scale).rounded()))
        let thumb = NSImage(size: NSSize(width: width, height: height))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        thumb.unlockFocus()
        return pngData(from: thumb)
    }
}
