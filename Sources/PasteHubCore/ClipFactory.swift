import Foundation

public enum ClipFactory {
    public static func makePreview(from text: String, limit: Int = PasteHubDefaults.previewCharacterLimit) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit {
            return collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<end])
    }

    public static func kind(forPlainText text: String, hasRichText: Bool) -> ClipKind {
        if isWebURL(text) {
            return .url
        }
        if hasRichText {
            return .richText
        }
        return .text
    }

    public static func isWebURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return false
        }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func looksLikeCode(_ text: String) -> Bool {
        let markers = ["func ", "class ", "import ", "def ", "=>", "{", "fn ", "package "]
        return markers.contains { text.contains($0) }
    }

    public static func imagePreview(width: Int, height: Int) -> String {
        "图片 \(width)×\(height)"
    }

    /// Screenshots and copied bitmaps often also carry a URL or filename as text.
    public static func shouldCaptureAsImage(text: String?, hasBitmap: Bool) -> Bool {
        guard hasBitmap else { return false }
        guard let text else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if isWebURL(trimmed) { return true }
        if trimmed.count <= 120, !trimmed.contains(where: \.isNewline) { return true }
        return false
    }

    public static func makeImage(
        png: Data,
        thumbnail: Data,
        width: Int,
        height: Int,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) -> NewClip? {
        guard !png.isEmpty, png.count <= PasteHubDefaults.maxImageBytes else { return nil }
        let thumb = thumbnail.isEmpty ? png : thumbnail
        let representations = [
            NewRepresentation(uti: UTI.png, data: png),
            NewRepresentation(uti: UTI.thumbnailPNG, data: thumb),
        ]
        return NewClip(
            kind: .image,
            preview: imagePreview(width: width, height: height),
            contentHash: ContentHasher.sha256(of: png),
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            representations: representations
        )
    }

    public static func make(
        text: String,
        rtf: Data? = nil,
        html: Data? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) -> NewClip? {
        let trimmedCheck = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCheck.isEmpty else { return nil }

        var representations: [NewRepresentation] = [
            NewRepresentation(uti: UTI.utf8PlainText, data: Data(text.utf8)),
        ]
        if let rtf, !rtf.isEmpty {
            representations.append(NewRepresentation(uti: UTI.rtf, data: rtf))
        }
        if let html, !html.isEmpty {
            representations.append(NewRepresentation(uti: UTI.html, data: html))
        }

        return NewClip(
            kind: kind(forPlainText: text, hasRichText: rtf != nil || html != nil),
            preview: makePreview(from: text),
            contentHash: ContentHasher.sha256(of: text),
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            representations: representations
        )
    }
}
