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
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
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
}
