import CryptoKit
import Foundation

public enum ContentHasher {
    public static func sha256(of string: String) -> String {
        sha256(of: Data(string.utf8))
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
