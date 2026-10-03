import AppKit
import Foundation
import os

enum UpdateState {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(currentVersion: String, newVersion: String)
    case failed(String)
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }
}

/// Checks release metadata only. Installing downloaded code is deliberately left
/// to the user and macOS Gatekeeper; never mount or replace bundles from a feed.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()
    static let releasesURL = URL(string: "https://api.github.com/repos/Optimisedigi/astro/releases/latest")! // Fixed app-owned URL.
    static let checkInterval: TimeInterval = 24 * 60 * 60
    private(set) var state: UpdateState = .idle
    private(set) var releasePageURL: URL?
    let currentVersion: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private let notify: @MainActor (String) -> Void
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var automaticCheck: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.universe.app", category: "updater")
    private static let noticeKey = "astroLastNotifiedUpdateVersion"

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
         defaults: UserDefaults = .standard,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         notify: @escaping @MainActor (String) -> Void = { version in
             NotchNotificationPresenter.showAgentReply(message: "Astro \(version) is available. Click to download from GitHub.") {
                 Task { @MainActor in AppUpdater.shared.openDownload() }
             }
         }) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        self.openURL = openURL
        self.notify = notify
    }

    func startAutomaticChecks() {
        guard timer == nil else { return }
        runAutomaticCheck()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runAutomaticCheck() }
        }
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        automaticCheck?.cancel()
        automaticCheck = nil
    }

    private func runAutomaticCheck() {
        automaticCheck = Task { [weak self] in
            guard let self else { return }
            await self.checkForUpdate(automatically: true)
        }
    }

    func checkForUpdate(automatically: Bool = false) async {
        if case .checking = state { return }
        await performCheck(automatically: automatically)
    }

    private func performCheck(automatically: Bool) async {
        let previousState = state
        let previousPage = releasePageURL
        state = .checking
        releasePageURL = nil
        let started = Date()
        do {
            guard Self.versionParts(currentVersion) != nil else { throw CheckError.invalid("The installed app has an invalid version.") }
            var request = URLRequest(url: Self.releasesURL)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Astro/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == Self.releasesURL else {
                throw CheckError.invalid("The update server returned an unexpected response.")
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 403 || http.statusCode == 429 {
                    throw CheckError.invalid("GitHub is rate limiting update checks. Try again later.")
                }
                throw CheckError.invalid("Could not check GitHub releases (HTTP \(http.statusCode)).")
            }
            guard data.count <= 1_048_576 else { throw CheckError.invalid("The release response is too large.") }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard !release.draft, !release.prerelease, Self.versionParts(version) != nil else {
                throw CheckError.invalid("The update feed did not return a stable version.")
            }
            if Self.isVersionNewer(remote: version, current: currentVersion) {
                let assetURL = "https://github.com/Optimisedigi/astro/releases/download/\(release.tagName)/Astro.dmg"
                guard release.assets.contains(where: { $0.name == "Astro.dmg" && $0.browserDownloadURL == assetURL }),
                      let page = URL(string: "https://github.com/Optimisedigi/astro/releases/tag/\(release.tagName)") else {
                    throw CheckError.invalid("The release has no official Astro installer.")
                }
                releasePageURL = page
                state = .available(currentVersion: currentVersion, newVersion: version)
                if automatically, defaults.string(forKey: Self.noticeKey) != version {
                    notify(version)
                    defaults.set(version, forKey: Self.noticeKey)
                }
            } else {
                state = .upToDate(currentVersion: currentVersion)
            }
            logger.info("Update check succeeded current=\(self.currentVersion) remote=\(version) elapsed=\(Date().timeIntervalSince(started))")
        } catch is CancellationError {
            state = previousState
            releasePageURL = previousPage
        } catch {
            if Task.isCancelled {
                state = previousState
                releasePageURL = previousPage
                return
            }
            let message: String
            if let urlError = error as? URLError {
                message = urlError.code == .notConnectedToInternet ? "No internet connection. Try again when online." : "Could not reach GitHub. Try again later."
            } else if let checkError = error as? CheckError {
                message = checkError.localizedDescription
            } else {
                message = "Could not read the GitHub release information. Try again later."
            }
            state = .failed(message)
            logger.error("Update check failed current=\(self.currentVersion) error=\(message) elapsed=\(Date().timeIntervalSince(started))")
        }
    }

    /// Opens only the validated, app-owned release page. No downloads or shell.
    func openDownload() {
        guard case .available = state, let page = releasePageURL else { return }
        let started = Date()
        let opened = openURL(page)
        logger.info("Open release page opened=\(opened) elapsed=\(Date().timeIntervalSince(started))")
        if !opened { state = .failed("Could not open the browser. Try again.") }
    }

    static func isVersionNewer(remote: String, current: String) -> Bool {
        guard let remoteParts = versionParts(remote), let currentParts = versionParts(current) else { return false }
        return currentParts.lexicographicallyPrecedes(remoteParts)
    }

    private static func versionParts(_ version: String) -> [Int]? {
        guard version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    private enum CheckError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }
}
