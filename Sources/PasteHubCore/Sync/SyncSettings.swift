import Foundation
import Security

/// The user-entered remote sync server configuration. Sync runs only when both
/// the server address and the sync key are present and valid.
public struct SyncConfiguration: Sendable, Equatable {
    public var serverURL: URL
    public var syncKey: String
    public var deviceName: String

    public init(serverURL: URL, syncKey: String, deviceName: String) {
        self.serverURL = serverURL
        self.syncKey = syncKey
        self.deviceName = deviceName
    }

    /// Accepts "paste.example.com", "https://paste.example.com/" and similar input.
    public static func normalizeServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

/// Persists the sync configuration: server address and device name in
/// UserDefaults, the sync key in the Keychain.
public struct SyncSettingsStore: Sendable {
    public static let serverURLKey = "syncServerURL"
    public static let deviceNameKey = "syncDeviceName"
    public static let autoCopyRemoteKey = "syncAutoCopyRemote"

    private let defaultsSuite: String?
    private let keychain: SyncKeychain

    /// - Parameters:
    ///   - defaultsSuite: App Group suite on iOS; nil for `UserDefaults.standard`.
    ///   - keychainAccessGroup: App Group identifier on iOS so extensions can read the key.
    public init(defaultsSuite: String? = nil, keychainAccessGroup: String? = nil) {
        self.defaultsSuite = defaultsSuite
        self.keychain = SyncKeychain(accessGroup: keychainAccessGroup)
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public var serverAddress: String {
        get { defaults.string(forKey: Self.serverURLKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.serverURLKey) }
    }

    public var deviceName: String {
        get { defaults.string(forKey: Self.deviceNameKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.deviceNameKey) }
    }

    public var autoCopyRemote: Bool {
        get { defaults.bool(forKey: Self.autoCopyRemoteKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoCopyRemoteKey) }
    }

    public var syncKey: String {
        get { keychain.read() ?? "" }
        nonmutating set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { keychain.delete() } else { keychain.write(trimmed) }
        }
    }

    /// The active configuration, or nil when sync is not set up.
    public func configuration(defaultDeviceName: String) -> SyncConfiguration? {
        guard let url = SyncConfiguration.normalizeServerURL(serverAddress) else { return nil }
        let key = syncKey
        guard SyncKeys.isValid(key) else { return nil }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncConfiguration(serverURL: url, syncKey: key, deviceName: name.isEmpty ? defaultDeviceName : name)
    }
}

struct SyncKeychain: Sendable {
    static let service = "com.kaitaocao.PasteHub.sync"
    static let account = "syncKey"
    let accessGroup: String?

    private func query(includeGroup: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        if includeGroup, let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// Unsigned simulator builds lack the access-group entitlement; fall back to the default group there.
    private func withGroupFallback<T>(_ body: (_ includeGroup: Bool) -> (OSStatus, T)) -> (OSStatus, T) {
        let result = body(accessGroup != nil)
        if result.0 == errSecMissingEntitlement, accessGroup != nil {
            return body(false)
        }
        return result
    }

    func read() -> String? {
        let (status, value): (OSStatus, String?) = withGroupFallback { includeGroup in
            var q = query(includeGroup: includeGroup)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            return (status, (item as? Data).flatMap { String(data: $0, encoding: .utf8) })
        }
        return status == errSecSuccess ? value : nil
    }

    func write(_ value: String) {
        let data = Data(value.utf8)
        _ = withGroupFallback { includeGroup -> (OSStatus, Void) in
            let q = query(includeGroup: includeGroup)
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = q
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return (status, ())
        }
    }

    func delete() {
        _ = withGroupFallback { includeGroup -> (OSStatus, Void) in
            (SecItemDelete(query(includeGroup: includeGroup) as CFDictionary), ())
        }
    }
}
