import PasteHubCore
import SwiftUI

@main
struct PasteHubApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Simulator testing: `SIMCTL_CHILD_PASTEHUB_SYNC_SERVER=... xcrun simctl launch ...`
        let env = ProcessInfo.processInfo.environment
        if let server = env["PASTEHUB_SYNC_SERVER"], let key = env["PASTEHUB_SYNC_KEY"] {
            SharedEnvironment.settings.serverAddress = server
            SharedEnvironment.settings.syncKey = key
            SharedEnvironment.settings.deviceName = env["PASTEHUB_SYNC_DEVICE"] ?? ""
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            HistoryView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.becameActive() }
            }
        }
    }
}
