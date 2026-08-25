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
