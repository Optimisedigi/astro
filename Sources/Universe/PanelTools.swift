import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// User-facing utilities shown in the Tools tab — separate from `AgentTool`
/// (AI tool calling). Ported from tama-agent's PanelTool.
@MainActor
protocol PanelTool: AnyObject {
    var id: String { get }
    var name: String { get }
    /// SF Symbol name for the tool icon.
    var icon: String { get }
    var toolDescription: String { get }
    /// Optional keyboard shortcut hint displayed on the trailing edge.
    var shortcutHint: String? { get }
}

/// A panel tool that acts as an on/off toggle rather than drilling into a subview.
@MainActor
protocol TogglePanelTool: PanelTool {
    var isEnabled: Bool { get }
    func toggle()
    var onStateChanged: (() -> Void)? { get set }
}

/// Registry of available panel tools (ported from tama-agent).
@MainActor
final class PanelToolRegistry {
    static let shared = PanelToolRegistry()

    private(set) var allTools: [PanelTool] = []

    private init() {
        register(ClipboardHistoryTool())
        register(KeepAwakeTool())
        if NightShiftTool.isSupported {
            register(NightShiftTool())
        }
    }

    func register(_ tool: PanelTool) {
        allTools.append(tool)
    }

    func search(query: String) -> [PanelTool] {
        guard !query.isEmpty else { return allTools }
        let lowered = query.lowercased()
        return allTools.filter {
            $0.name.lowercased().contains(lowered)
                || $0.toolDescription.lowercased().contains(lowered)
        }
    }
}

/// Panel tool that provides searchable clipboard history.
@MainActor
final class ClipboardHistoryTool: PanelTool {
    let id = "clipboard-history"
    let name = "Clipboard History"
    let icon = "doc.on.clipboard"
    let toolDescription = "Browse and search your clipboard history"
    let shortcutHint: String? = nil
}

/// Prevents the Mac from sleeping using an IOKit power assertion
/// (ported verbatim from tama-agent).
@MainActor
final class KeepAwakeTool: TogglePanelTool {
    let id = "keep-awake"
    let name = "Keep Awake"
    let icon = "cup.and.heat.waves.fill"
    let toolDescription = "Prevent your Mac from sleeping"
    let shortcutHint: String? = nil

    var onStateChanged: (() -> Void)?

    private(set) var isEnabled = false
    private var assertionID: IOPMAssertionID = 0

    func toggle() {
        isEnabled ? stop() : start()
    }

    private func start() {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Astro Keep Awake" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isEnabled = true
            onStateChanged?()
        }
    }

    private func stop() {
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isEnabled = false
        onStateChanged?()
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}

/// Enables/disables Night Shift via the private CoreBrightness framework,
/// loaded at runtime with dlopen (ported verbatim from tama-agent).
@MainActor
final class NightShiftTool: TogglePanelTool {
    let id = "night-shift"
    let name = "Night Shift"
    let icon = "moon.fill"
    let toolDescription = "Warm your display colors"
    let shortcutHint: String? = nil

    var onStateChanged: (() -> Void)?

    private(set) var isEnabled = false

    private static var clientLoaded = false
    private static var blueLightClient: NSObject?

    /// Whether the hardware supports Night Shift (Blue Light Reduction).
    static var isSupported: Bool {
        ensureClient()
        guard let cls = NSClassFromString("CBBlueLightClient") else { return false }
        let sel = NSSelectorFromString("supportsBlueLightReduction")
        guard (cls as AnyObject).responds(to: sel) else { return true }
        typealias SupportsFn = @convention(c) (AnyObject, Selector) -> Bool
        let imp = unsafeBitCast((cls as AnyObject).method(for: sel), to: SupportsFn.self)
        return imp(cls as AnyObject, sel)
    }

    private static func ensureClient() {
        guard !clientLoaded else { return }
        clientLoaded = true
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY
        ) != nil else { return }
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return }
        blueLightClient = cls.init()
    }

    init() {
        Self.ensureClient()
        isEnabled = Self.readCurrentState()
    }

    func toggle() {
        Self.ensureClient()
        let newState = !isEnabled
        Self.setNightShift(enabled: newState)
        // Update optimistically — the system needs time to propagate the change.
        isEnabled = newState
        onStateChanged?()

        // Verify after the system has had time to update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let actual = Self.readCurrentState()
            if actual != isEnabled {
                isEnabled = actual
                onStateChanged?()
            }
        }
    }

    private static func readCurrentState() -> Bool {
        guard let client = blueLightClient else { return false }
        var statusBytes = [UInt8](repeating: 0, count: 512)
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: sel) else { return false }
        typealias GetStatusFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<UInt8>) -> Bool
        let imp = unsafeBitCast((client as AnyObject).method(for: sel), to: GetStatusFn.self)
        let ok = imp(client, sel, &statusBytes)
        guard ok else { return false }
        // The enabled flag is at byte offset 1.
        return statusBytes[1] != 0
    }

    private static func setNightShift(enabled: Bool) {
        guard let client = blueLightClient else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard client.responds(to: sel) else { return }
        typealias SetEnabledFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let imp = unsafeBitCast((client as AnyObject).method(for: sel), to: SetEnabledFn.self)
        _ = imp(client, sel, enabled)
    }
}

/// Plays the shared button click sound (ported from tama-agent).
/// Uses NSSound for reliable playback in menu-bar apps.
final class ButtonSound: NSObject, NSSoundDelegate, @unchecked Sendable {
    static let shared = ButtonSound()

    private var sound: NSSound?

    override private init() {
        super.init()
        guard let url = Bundle.main.url(forResource: "sound-step", withExtension: "mp3") else { return }
        sound = NSSound(contentsOf: url, byReference: true)
        sound?.delegate = self
    }

    func play() {
        guard let sound else { return }
        // Stop any in-progress playback so we can replay immediately.
        sound.stop()
        sound.play()
    }
}
