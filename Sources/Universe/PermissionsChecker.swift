import AVFoundation
import AppKit
import CoreGraphics
import Speech
import UserNotifications

/// Live status of every macOS permission Universe needs, plus a deep link to the
/// exact System Settings pane that grants it.
///
/// macOS has no API to *grant* a permission — only to request one (which shows the
/// system prompt once, ever) or to send the user to Settings. So each row either
/// triggers the real request or opens the right pane; nothing here can silently
/// escalate privilege.
@MainActor
final class PermissionsChecker: ObservableObject {
    enum Status: Equatable {
        case granted
        case denied
        /// macOS exposes no way to read this one; the user has to look.
        case unknown
        /// Optional extras that are present rather than authorized.
        case ready(String)

        var isSatisfied: Bool {
            switch self {
            case .granted, .ready: return true
            case .denied, .unknown: return false
            }
        }
    }

    struct Permission: Identifiable {
        let id: Kind
        let title: String
        let reason: String
        var status: Status
        var optional = false

        var kind: Kind { id }
    }

    enum Kind: String, CaseIterable {
        case accessibility, fullDisk, microphone, speech, appManagement, screenRecording, notifications, browser
    }

    @Published private(set) var permissions: [Permission] = []
    @Published private(set) var isRefreshing = false

    private var accessibilityObserver: NSObjectProtocol?

    init() {
        permissions = Self.blueprint
        observeAccessibilityChanges()
        Task { await refresh() }
    }

    /// Fixed statuses, so `--render-states` can gate each visual state deterministically
    /// (a live checker resolves asynchronously and would render as all-unknown).
    init(fixed: [Kind: Status]) {
        permissions = Self.blueprint.map { row in
            var row = row
            if let status = fixed[row.kind] { row.status = status }
            return row
        }
    }

    deinit {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
    }

    /// `AXIsProcessTrusted()` keeps returning its cached value inside a running
    /// process, so a user who grants Accessibility sees the row stay "denied" and
    /// concludes the app needs a restart. macOS broadcasts this notification when
    /// any app's Accessibility state changes; re-checking on it makes the row live
    /// (matches tama-agent).
    private func observeAccessibilityChanges() {
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Small delay so the AX daemon has finalised the change before we re-query.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self else { return }
                Task { @MainActor in await self.refresh() }
            }
        }
    }

    /// Everything not satisfied, so onboarding can say what is still missing.
    var outstanding: [Permission] { permissions.filter { !$0.optional && !$0.status.isSatisfied } }
    var allRequiredGranted: Bool { outstanding.isEmpty }

    private static var blueprint: [Permission] {
        [
            .init(id: .accessibility, title: "Accessibility", reason: "Required for the global hotkey (⌥Space).", status: .unknown),
            .init(id: .fullDisk, title: "Full Disk Access", reason: "Required to read, write, and edit files.", status: .unknown),
            .init(id: .microphone, title: "Microphone", reason: "Required for voice input.", status: .unknown),
            .init(id: .speech, title: "Speech Recognition", reason: "Required for voice-to-text transcription.", status: .unknown),
            .init(id: .appManagement, title: "App Management", reason: "Allows managing the bundled browser.", status: .unknown, optional: true),
            .init(id: .screenRecording, title: "Screen Recording", reason: "Required for the screenshot tool to capture your screen.", status: .unknown),
            .init(id: .notifications, title: "Notifications", reason: "Required for reminders and routine alerts.", status: .unknown),
            .init(id: .browser, title: "Browser (Optional)", reason: "Used for web tasks.", status: .unknown, optional: true),
        ]
    }

    func refresh() async {
        isRefreshing = true
        let notifications = await notificationStatus()
        var next = Self.blueprint
        for index in next.indices {
            next[index].status = next[index].kind == .notifications ? notifications : status(for: next[index].kind)
        }
        permissions = next
        isRefreshing = false
    }

    private func status(for kind: Kind) -> Status {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .fullDisk:
            return Self.hasFullDiskAccess ? .granted : .denied
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .appManagement:
            return Self.hasAppManagement ? .granted : .denied
        case .screenRecording:
            return Self.hasScreenRecording ? .granted : .denied
        case .notifications:
            return .unknown // resolved asynchronously in refresh()
        case .browser:
            guard let name = Self.detectedBrowser else { return .denied }
            return .ready("\(name) detected.")
        }
    }

    private func notificationStatus() async -> Status {
        // UNUserNotificationCenter traps without a bundle (selftest / CLI runs).
        guard Bundle.main.bundleIdentifier != nil else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    /// Reading the *system* TCC database is the reliable probe: it fails without
    /// Full Disk Access rather than prompting. The per-user copy is readable
    /// without FDA, so probing that reports a false "granted" (matches tama-agent).
    private static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// `CGPreflightScreenCaptureAccess()` caches its answer for the lifetime of the
    /// process, so once it says false the row stays stuck on "denied" until the app
    /// restarts — even after the user grants it. Only apps with Screen Recording can
    /// read another process's window title, so probing for one reflects the live TCC
    /// state (matches tama-agent).
    private static var hasScreenRecording: Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return CGPreflightScreenCaptureAccess()
        }
        var sawForeignWindow = false
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            // System-owned windows expose titles regardless of TCC state.
            if let owner = window[kCGWindowOwnerName as String] as? String,
               ["Window Server", "Dock", "SystemUIServer"].contains(owner) { continue }
            sawForeignWindow = true
            if window[kCGWindowName as String] is String { return true }
        }
        // Nothing to compare against: fall back to the (possibly stale) preflight.
        return sawForeignWindow ? false : CGPreflightScreenCaptureAccess()
    }

    /// No API reports App Management, so try the thing it governs: writing inside a
    /// .app bundle. Runs in our own Application Support folder and cleans up after
    /// itself (matches tama-agent).
    private static var hasAppManagement: Bool {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Universe/.appmanagement-check", isDirectory: true)
        let contents = root.appendingPathComponent("Test.app/Contents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data().write(to: contents.appendingPathComponent("Info.plist"))
            return true
        } catch {
            return false
        }
    }

    private static var detectedBrowser: String? {
        let candidates = [
            ("com.google.Chrome", "Google Chrome"),
            ("com.apple.Safari", "Safari"),
            ("company.thebrowser.Browser", "Arc"),
            ("org.mozilla.firefox", "Firefox"),
        ]
        for (bundleID, name) in candidates
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return name
        }
        return nil
    }

    // MARK: - Acting on a row

    /// Requests the permission where macOS allows it, otherwise opens the pane.
    func grant(_ kind: Kind) {
        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in await self.refresh() }
            }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in await self.refresh() }
            }
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in await self.refresh() }
            }
        case .accessibility:
            // Prompts once, then falls through to the pane on later attempts.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            openSettings(for: kind)
            // AXIsProcessTrusted() caches within a process; poll until the user
            // grants and the value flips, or 15s elapses.
            Task {
                for _ in 0..<15 {
                    try? await Task.sleep(for: .seconds(1))
                    if AXIsProcessTrusted() {
                        await refresh()
                        return
                    }
                }
                await refresh()
            }
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            openSettings(for: kind)
        case .fullDisk:
            // Trigger the TCC prompt by reading a protected path. Without this
            // the app never appears in the Full Disk Access list.
            _ = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Mail")
            openSettings(for: kind)
            // Poll until the probe succeeds or 15s elapses.
            Task {
                for _ in 0..<15 {
                    try? await Task.sleep(for: .seconds(1))
                    if Self.hasFullDiskAccess {
                        await refresh()
                        return
                    }
                }
                await refresh()
            }
        case .appManagement, .browser:
            openSettings(for: kind)
        }
    }

    func openSettings(for kind: Kind) {
        guard let url = URL(string: Self.settingsURL(for: kind)) else { return }
        NSWorkspace.shared.open(url)
    }

    static func settingsURL(for kind: Kind) -> String {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch kind {
        case .accessibility: return base + "Privacy_Accessibility"
        case .fullDisk: return base + "Privacy_AllFiles"
        case .microphone: return base + "Privacy_Microphone"
        case .speech: return base + "Privacy_SpeechRecognition"
        case .appManagement: return base + "Privacy_AppBundles"
        case .screenRecording: return base + "Privacy_ScreenCapture"
        case .notifications: return "x-apple.systempreferences:com.apple.preference.notifications"
        case .browser: return "https://www.google.com/chrome/"
        }
    }
}
