import CryptoKit
import Foundation

public enum SyncLimits {
    /// Clips whose representations (excluding the thumbnail) exceed this stay on the device.
    public static let maxClipBytes = 5 * 1024 * 1024
    /// Representations up to this size travel inside the encrypted op instead of as a blob.
    public static let inlineRepresentationBytes = 32 * 1024
}

public enum SyncKeyError: Error, Equatable, LocalizedError {
    case missingPrefix
    case invalidEncoding
    case wrongLength

    public var errorDescription: String? {
        switch self {
        case .missingPrefix: "同步密钥应以 \(SyncKeys.prefix) 开头"
        case .invalidEncoding: "同步密钥格式不正确"
        case .wrongLength: "同步密钥长度不正确"
        }
    }
}

/// Keys derived from one sync key string. The derivation must match
/// `Server/internal/syncserver/keys.go`: HKDF-SHA256, salt "PasteHub sync v1".
public struct SyncKeys: Sendable {
    public static let prefix = "phs1_"
    private static let salt = Data("PasteHub sync v1".utf8)

    /// Bearer token sent to the server. The server stores only its SHA-256.
    public let authToken: Data
    /// Encrypts op payloads.
    let encryptionKey: SymmetricKey
    /// Keys the item identifier so the server can deduplicate without seeing content hashes.
    let itemKeyMAC: SymmetricKey

    public init(syncKey: String) throws {
        try self.init(master: Self.parse(syncKey))
    }

    init(master: Data) {
        let ikm = SymmetricKey(data: master)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt, info: Data(info.utf8), outputByteCount: 32)
        }
        authToken = derive("auth").withUnsafeBytes { Data($0) }
        encryptionKey = derive("enc")
        itemKeyMAC = derive("mac")
    }

    public var authTokenHex: String { authToken.hexString }

    /// Server-side identifier of the sync space this key unlocks.
    public var spaceID: String { Data(SHA256.hash(data: authToken)).hexString }

    public func itemKey(forContentHash contentHash: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(contentHash.utf8), using: itemKeyMAC)).hexString
    }

    public static func parse(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw SyncKeyError.missingPrefix }
        var body = String(trimmed.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body.append("=") }
        guard let master = Data(base64Encoded: body) else { throw SyncKeyError.invalidEncoding }
        guard master.count == 32 else { throw SyncKeyError.wrongLength }
        return master
    }

    public static func format(master: Data) -> String {
        prefix + master.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValid(_ raw: String) -> Bool {
        (try? parse(raw)) != nil
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
