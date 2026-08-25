import AppKit
import Foundation

@MainActor
enum UpdateInstaller {
    static func apply(newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent("PasteHub.app.update")
        let fm = FileManager.default
        if fm.fileExists(atPath: staged.path) {
            try fm.removeItem(at: staged)
        }
        try fm.copyItem(at: newApp, to: staged)

        let script = """
        #!/bin/bash
        set -e
        PID="$1"
        CURRENT="$2"
        STAGED="$3"
        while /bin/kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.4
        rm -rf "$CURRENT"
        mv "$STAGED" "$CURRENT"
        /usr/bin/open "$CURRENT"
        """
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("pastehub-apply-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = scriptURL
        process.arguments = [
            "\(ProcessInfo.processInfo.processIdentifier)",
            current.path,
            staged.path,
        ]
        try process.run()
        NSApp.terminate(nil)
    }
}
