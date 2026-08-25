import AppKit
import Carbon.HIToolbox

/// Global ⌥Space hotkey via Carbon RegisterEventHotKey (same mechanism Tama uses).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?

    func register() {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.onHotKey?()
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), nil
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x54434C31), id: 1) // 'TCL1'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
