import Foundation

public enum PasteHubDefaults {
    public static let historyLimitKey = "historyLimit"
    public static let skipOneTimeCodesKey = "skipOneTimeCodes"
    public static let clearHistoryOnQuitKey = "clearHistoryOnQuit"

    public static let defaultHistoryLimit = 200
    public static let overlayItemLimit = 50
    public static let previewCharacterLimit = 200
    public static let maxTextBytes = 1_048_576

    public static func register() {
        UserDefaults.standard.register(defaults: [
            historyLimitKey: defaultHistoryLimit,
            skipOneTimeCodesKey: true,
            clearHistoryOnQuitKey: false,
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
}
