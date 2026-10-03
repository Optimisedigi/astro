import Foundation

extension SelfTest {
    @MainActor
    static func runAppUpdaterChecks(check: @escaping (Bool, String) -> Void) async {
        let suite = "astro-update-checks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "updates: isolated preferences available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        func fixture(tag: String = "v0.1.2", draft: Bool = false, prerelease: Bool = false,
                     asset: String? = nil) -> Data {
            let body: [String: Any] = [
                "tag_name": tag, "draft": draft, "prerelease": prerelease,
                "assets": [["name": "Astro.dmg", "browser_download_url": asset ??
                    "https://github.com/Optimisedigi/astro/releases/download/\(tag)/Astro.dmg"]],
            ]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
        func response(_ status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: AppUpdater.releasesURL, statusCode: status,
                            httpVersion: nil, headerFields: nil)! // Fixed test URL/status.
        }

        check(AppUpdater.isVersionNewer(remote: "0.1.10", current: "0.1.9"), "updates: versions compare numerically")
        for version in ["0.1.1", "0.1.0", "0.1.2-beta", "../1.2.3", "01.2.3", "1.2.3\n"] {
            check(!AppUpdater.isVersionNewer(remote: version, current: "0.1.1"), "updates: equal, older or invalid version is not an update (\(version.debugDescription))")
        }
        check(AppUpdater.checkInterval == 86_400, "updates: automatic interval is daily")

        var notices: [String] = []
        var opened: [URL] = []
        let updater = AppUpdater(currentVersion: "0.1.1", defaults: defaults, fetch: { request in
            check(request.url == AppUpdater.releasesURL && request.timeoutInterval == 20,
                  "updates: request uses official GitHub endpoint and timeout")
            return (fixture(), response())
        }, openURL: { opened.append($0); return true }, notify: { notices.append($0) })
        await updater.checkForUpdate(automatically: true)
        if case let .available(current, new) = updater.state {
            check(current == "0.1.1" && new == "0.1.2", "updates: newer official installer is available")
        } else { check(false, "updates: newer official installer is available") }
        check(notices == ["0.1.2"], "updates: automatic check emits a notice")
        updater.openDownload()
        check(opened.map(\.absoluteString) == ["https://github.com/Optimisedigi/astro/releases/tag/v0.1.2"],
              "updates: click opens official release page without installing")
        await updater.checkForUpdate(automatically: true)
        check(notices.count == 1, "updates: repeated checks do not repeat the notice")

        var restartNotices = 0
        let restarted = AppUpdater(currentVersion: "0.1.1", defaults: defaults,
                                   fetch: { _ in (fixture(), response()) }, openURL: { _ in true },
                                   notify: { _ in restartNotices += 1 })
        await restarted.checkForUpdate(automatically: true)
        check(restartNotices == 0, "updates: notice deduplication survives app restart")

        for data in [fixture(tag: "v0.1.2-beta"), fixture(draft: true), fixture(prerelease: true),
                     fixture(asset: "https://example.com/Astro.dmg"), Data("not json".utf8)] {
            var didNotify = false
            var didOpen = false
            let invalid = AppUpdater(currentVersion: "0.1.1", defaults: defaults,
                                     fetch: { _ in (data, response()) }, openURL: { _ in didOpen = true; return true },
                                     notify: { _ in didNotify = true })
            await invalid.checkForUpdate(automatically: true)
            invalid.openDownload()
            if case .failed = invalid.state {
                check(!didNotify && !didOpen && invalid.releasePageURL == nil, "updates: invalid releases never notify or open")
            } else { check(false, "updates: invalid releases are rejected") }
        }
        for tag in ["v0.1.1", "v0.1.0"] {
            let current = AppUpdater(currentVersion: "0.1.1", defaults: defaults,
                                     fetch: { _ in (fixture(tag: tag), response()) }, notify: { _ in check(false, "updates: no false update notice") })
            await current.checkForUpdate(automatically: true)
            if case .upToDate = current.state { check(true, "updates: same and older releases are up to date") }
            else { check(false, "updates: same and older releases are up to date") }
        }
        for status in [403, 429, 500] {
            let failed = AppUpdater(currentVersion: "0.1.1", defaults: defaults,
                                    fetch: { _ in (fixture(), response(status)) }, notify: { _ in check(false, "updates: HTTP failures never notify") })
            await failed.checkForUpdate(automatically: true)
            if case .failed = failed.state { check(true, "updates: HTTP \(status) failure is recoverable") }
            else { check(false, "updates: HTTP failure is reported") }
        }
        let offline = AppUpdater(currentVersion: "0.1.1", defaults: defaults,
                                 fetch: { _ in throw URLError(.notConnectedToInternet) })
        await offline.checkForUpdate(automatically: true)
        if case let .failed(message) = offline.state {
            check(message.contains("internet"), "updates: offline checks fail without a false notice")
        } else { check(false, "updates: offline error is reported") }

        var startupRequests = 0
        let startup = AppUpdater(currentVersion: "0.1.2", defaults: defaults,
                                 fetch: { _ in startupRequests += 1; return (fixture(), response()) }, notify: { _ in })
        startup.startAutomaticChecks()
        startup.startAutomaticChecks()
        // Yield to the startup task, with a bounded wait rather than a sleep.
        for _ in 0..<100 where startupRequests == 0 { await Task.yield() }
        startup.stopAutomaticChecks()
        check(startupRequests == 1, "updates: startup checks immediately and scheduling is idempotent")
    }
}
