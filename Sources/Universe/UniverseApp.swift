import SwiftUI

@main
struct UniverseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The menubar item is an `NSStatusItem` owned by `StatusItemController`,
    /// not a `MenuBarExtra`, so a single click can interrupt speech or capture.
    /// This scene exists only because `App` requires one; it shows nothing.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        NotchCallButton.hide()
        VirtualNotch.hide()
        ClipboardMonitor.shared.stop()
        // Release the microphone on the way out, or macOS leaves the recording
        // indicator lit until the process is fully reaped.
        VoiceService.shared.stopListening()
        SpeechService.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            Task {
                let passed = await SelfTest.run()
                // exit() skips the UserDefaults flush, which left the microphone
                // off after install-time --selftest wrote kokoroVoiceEnabled=false.
                UserDefaults.standard.synchronize()
                exit(passed ? 0 : 1)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-states") {
            guard i + 1 < CommandLine.arguments.count else {
                print("usage: Universe --render-states <dir>")
                exit(2)
            }
            exit(RenderStates.run(directory: CommandLine.arguments[i + 1]) ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--dictation-check") {
            guard i + 2 < CommandLine.arguments.count else {
                print("usage: Universe --dictation-check <audio file> <output file>")
                exit(2)
            }
            exit(LiveDictation.runCheck(audioPath: CommandLine.arguments[i + 1],
                                        outputPath: CommandLine.arguments[i + 2]) ? 0 : 1)
        }
        guard claimSingleInstance() else { return }

        migrateLegacyDataDirectory()
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
        StatusItemController.shared.install()
        HotKeyManager.shared.onHotKey = {
            PanelController.shared.toggle()
        }
        HotKeyManager.shared.register()
        ScheduleStore.shared.start()
        ClipboardMonitor.shared.start()

        /* Draw a virtual notch so screen recordings (which don't capture the
           hardware notch) still show the silhouette behind notch toasts. */
        VirtualNotch.show()
        NotchCallButton.show()

        /* Without a Dock icon or a launch window, double-clicking the app looks like
           nothing happened. Show the panel so launching has a visible result — except
           when macOS started us at login, where a panel appearing would be a jump scare. */
        if !launchedAsLoginItem {
            PanelController.shared.show()
            // First launch: walk through permissions before the user can ask anything.
            if !OnboardingModel().hasCompletedOnboarding {
                PanelController.shared.openSheet(.onboarding)
            }
        }
    }

    /// Clicking the app in Finder, the Dock, or Spotlight while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelController.shared.show()
        return true
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Two copies of the same bundle ID can run from different paths (a stale
    /// DerivedData build and /Applications), which means two menubar icons and a
    /// hotkey that only reaches one of them.
    ///
    /// The installed copy always wins. Handing off to whoever started first let a
    /// day-old debug build silently swallow every launch of a freshly installed
    /// app — the user saw stale UI and an ad-hoc signature no matter how many
    /// times they reinstalled.
    private func claimSingleInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }

        let selfIsInstalled = Self.isInstalledCopy(Bundle.main.bundleURL)
        // Evict any running copy this one outranks, so the winner is alone.
        var evicted: [NSRunningApplication] = []
        for other in others {
            let otherIsInstalled = other.bundleURL.map(Self.isInstalledCopy) ?? false
            if Self.shouldYield(selfIsInstalled: selfIsInstalled, otherIsInstalled: otherIsInstalled) {
                other.activate()
                NSApp.terminate(nil)
                return false
            }
            other.terminate()
            evicted.append(other)
        }
        Self.waitForExit(of: evicted)
        return true
    }

    /// Blocks until the evicted copies are really gone.
    ///
    /// `terminate()` only *requests* a quit. Continuing straight into launch means
    /// registering the ⌥Space hotkey while the rival still holds it — registration
    /// fails silently and is never retried, leaving the winner with a dead hotkey:
    /// exactly the symptom evicting the rival was meant to cure.
    nonisolated private static func waitForExit(of apps: [NSRunningApplication],
                                                timeout: TimeInterval = 2) {
        // Never wait on — or kill — ourselves. A self-reference here would turn a
        // launch race into the app force-quitting itself.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rivals = apps.filter { $0.processIdentifier != ownPID }
        guard !rivals.isEmpty else { return }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, rivals.contains(where: { !$0.isTerminated }) {
            // Spin the runloop rather than sleeping: AppKit delivers the
            // termination notifications that flip `isTerminated`.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        for app in rivals where !app.isTerminated {
            NSLog("Universe: rival instance (pid \(app.processIdentifier)) ignored quit; forcing")
            app.forceTerminate()
        }
    }

    /// Test hook: exercises the eviction wait without launching a second copy.
    nonisolated static func waitForExitForTests(of apps: [NSRunningApplication], timeout: TimeInterval) {
        waitForExit(of: apps, timeout: timeout)
    }

    /// A copy living in /Applications is the one the user actually installed.
    nonisolated static func isInstalledCopy(_ bundleURL: URL) -> Bool {
        bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    /// Whether a starting instance should defer to an already-running one.
    /// Only ever yield to a copy that is at least as authoritative as this one:
    /// an installed build must never stand down for a build-folder build.
    nonisolated static func shouldYield(selfIsInstalled: Bool, otherIsInstalled: Bool) -> Bool {
        if selfIsInstalled == otherIsInstalled { return true } // identical rank: first one wins
        return otherIsInstalled                               // only yield upward
    }

    /// The app was renamed from TamaClone; move existing sessions, schedules and
    /// workspace files across so the rename doesn't look like data loss.
    ///
    /// Merges item by item rather than moving the whole directory: the new folder
    /// may already exist (a store touched disk first), and a blanket "skip if it
    /// exists" would strand the old data forever. Existing files always win, so
    /// this is safe to run on every launch and never overwrites newer state.
    private func migrateLegacyDataDirectory() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacy = base.appendingPathComponent("TamaClone", isDirectory: true)
        let current = base.appendingPathComponent("Universe", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }

        do {
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: legacy.path) {
                let from = legacy.appendingPathComponent(name)
                let to = current.appendingPathComponent(name)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try fm.moveItem(at: from, to: to)
            }
            // Only remove the old folder once everything has been claimed.
            if (try fm.contentsOfDirectory(atPath: legacy.path)).isEmpty {
                try fm.removeItem(at: legacy)
            }
        } catch {
            NSLog("Universe: could not migrate legacy data directory: \(error.localizedDescription)")
        }
    }
}
