import Foundation

public enum PasteHubDefaults {
    public static let historyLimitKey = "historyLimit"
    public static let skipOneTimeCodesKey = "skipOneTimeCodes"
    public static let clearHistoryOnQuitKey = "clearHistoryOnQuit"
    public static let autoCheckUpdatesKey = "autoCheckUpdates"
    public static let lastUpdateCheckKey = "lastUpdateCheck"

    public static let defaultHistoryLimit = 200
    public static let overlayItemLimit = 50
    public static let previewCharacterLimit = 200
    public static let maxTextBytes = 1_048_576
    public static let maxImageBytes = 10 * 1024 * 1024
    public static let maxStoreBytes = 200 * 1024 * 1024
    public static let thumbnailMaxEdge = 96

    public static func register() {
        UserDefaults.standard.register(defaults: [
            historyLimitKey: defaultHistoryLimit,
            skipOneTimeCodesKey: true,
            clearHistoryOnQuitKey: false,
            autoCheckUpdatesKey: true,
        ])
    }

    public static var historyLimit: Int {
        let value = UserDefaults.standard.object(forKey: historyLimitKey) as? Int ?? defaultHistoryLimit
        return min(max(value, 20), 1000)
    }

    public static var skipOneTimeCodes: Bool {
        UserDefaults.standard.object(forKey: skipOneTimeCodesKey) as? Bool ?? true
    }

    public static var clearHistoryOnQuit: Bool {
        UserDefaults.standard.bool(forKey: clearHistoryOnQuitKey)
    }

    public static var autoCheckUpdates: Bool {
        if UserDefaults.standard.object(forKey: autoCheckUpdatesKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoCheckUpdatesKey)
    }

    public static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastUpdateCheckKey) }
    }
}
