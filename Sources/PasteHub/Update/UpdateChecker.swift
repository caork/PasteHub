import AppKit
import Foundation
import Observation
import PasteHubCore

@MainActor
@Observable
final class UpdateChecker {
    static let githubOwner = "caork"
    static let githubRepo = "PasteHub"
    static let assetName = "PasteHub.app.zip"
    static let autoCheckInterval: TimeInterval = 60 * 60 * 24

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String, assetURL: URL, pageURL: URL)
        case downloading
        case readyToInstall(appURL: URL, version: String)
        case failed(String)
    }

    var status: Status = .idle
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func startAutomaticChecks() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await checkIfDue()
        }
    }

    func checkIfDue() async {
        guard PasteHubDefaults.autoCheckUpdates else { return }
        if let last = PasteHubDefaults.lastUpdateCheck,
           Date().timeIntervalSince(last) < Self.autoCheckInterval
        {
            return
        }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            PasteHubDefaults.lastUpdateCheck = Date()
            guard AppVersion.isNewer(release.tagName, than: currentVersion) else {
                status = .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
                  let assetURL = URL(string: asset.browserDownloadURL)
            else {
                status = .failed("最新版本没有 \(Self.assetName)")
                return
            }
            let pageURL = URL(string: release.htmlURL) ?? githubReleasesURL
            let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            status = .available(
                version: AppVersion.normalize(release.tagName),
                notes: notes,
                assetURL: assetURL,
                pageURL: pageURL
            )
            if !userInitiated {
                promptToInstall()
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func downloadAndStage() async {
        guard case let .available(_, _, assetURL, _) = status else { return }
        status = .downloading
        do {
            let appURL = try await downloadApp(from: assetURL)
            let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? currentVersion
            status = .readyToInstall(appURL: appURL, version: version)
            confirmInstall(appURL: appURL, version: version)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func applyStagedInstall(appURL: URL) {
        do {
            try UpdateInstaller.apply(newApp: appURL)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    var githubReleasesURL: URL {
        URL(string: "https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases")!
    }

    private func promptToInstall() {
        guard case let .available(version, notes, _, _) = status else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "PasteHub \(version) 可用"
        alert.informativeText = notes.isEmpty ? "当前版本 \(currentVersion)。要下载并安装更新吗？" : notes
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await downloadAndStage() }
        }
    }

    private func confirmInstall(appURL: URL, version: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "安装 PasteHub \(version)？"
        alert.informativeText = "安装时会退出当前进程，然后自动重新打开。"
        alert.addButton(withTitle: "安装并重启")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            applyStagedInstall(appURL: appURL)
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(Self.githubOwner)/\(Self.githubRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("PasteHub/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return GitHubRelease(
                tagName: currentVersion,
                htmlURL: githubReleasesURL.absoluteString,
                body: nil,
                assets: []
            )
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
        return try GitHubRelease.decode(from: data)
    }

    private func downloadApp(from url: URL) async throws -> URL {
        let (tempFile, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
        let cache = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("PasteHub/update", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let zip = cache.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zip.path) {
            try FileManager.default.removeItem(at: zip)
        }
        try FileManager.default.moveItem(at: tempFile, to: zip)

        let extract = cache.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path])

        let app = extract.appendingPathComponent("PasteHub.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError.missingApp
        }
        let bundleID = Bundle(url: app)?.bundleIdentifier
        guard bundleID == Bundle.main.bundleIdentifier else {
            throw UpdateError.wrongBundle
        }
        return app
    }

    private func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.unpackFailed
        }
    }
}

private enum UpdateError: LocalizedError {
    case http(Int)
    case missingApp
    case wrongBundle
    case unpackFailed

    var errorDescription: String? {
        switch self {
        case let .http(code): "GitHub 返回 HTTP \(code)"
        case .missingApp: "压缩包里没有 PasteHub.app"
        case .wrongBundle: "更新包不是 PasteHub"
        case .unpackFailed: "解压更新包失败"
        }
    }
}
