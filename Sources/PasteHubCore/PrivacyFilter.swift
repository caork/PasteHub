import Foundation

public enum PrivacyFilter {
    public struct Context: Sendable {
        public var text: String
        public var sourceBundleID: String?
        public var skipOneTimeCodes: Bool
        public var kind: ClipKind

        public init(text: String, sourceBundleID: String?, skipOneTimeCodes: Bool, kind: ClipKind = .text) {
            self.text = text
            self.sourceBundleID = sourceBundleID
            self.skipOneTimeCodes = skipOneTimeCodes
            self.kind = kind
        }
    }

    /// Password managers and OS password UI. MVP keeps this list code-defined.
    public static let blockedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.1password.1password8",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.authy.authy-mac",
    ]

    public static let blockedAppNames: [String] = [
        "1Password",
        "Bitwarden",
        "KeePassXC",
        "LastPass",
        "Passwords",
        "Authy",
    ]

    public static func shouldCapture(_ context: Context) -> Bool {
        if let bundleID = context.sourceBundleID, blockedBundleIDs.contains(bundleID) {
            return false
        }
        if context.kind == .image {
            return true
        }
        let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if context.text.utf8.count > PasteHubDefaults.maxTextBytes { return false }
        if context.skipOneTimeCodes, looksLikeOneTimeCode(trimmed) {
            return false
        }
        return true
    }

    public static func looksLikeOneTimeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.wholeMatch(of: /^[0-9]{6,8}$/) != nil {
            return true
        }
        if trimmed.contains("验证码") || trimmed.contains("校验码") {
            return true
        }
        let lowered = trimmed.lowercased()
        return lowered.range(
            of: #"\b(otp|totp|2fa|verification code|one-time code|one time code)\b"#,
            options: .regularExpression
        ) != nil
    }
}
