import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (same mechanism Tama uses):
/// ⌥Space opens the panel as usual; ⇧⌥Space opens it for typing, mic off.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    var onHotKey: (() -> Void)?
    var onTypingHotKey: (() -> Void)?

    /// Carbon IDs for the two shortcuts; the handler tells them apart by these.
    static let talkHotKeyID: UInt32 = 1
    static let typingHotKeyID: UInt32 = 2

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    /// Which callback a pressed shortcut runs. Split out so the self-test can
    /// check the routing without pressing keys.
    func handle(hotKeyID: UInt32) {
        switch hotKeyID {
        case Self.typingHotKeyID: onTypingHotKey?()
        default: onHotKey?()
        }
    }

    func register() {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            guard status == noErr else { return status }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.handle(hotKeyID: pressed.id)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        for (id, modifiers) in [(Self.talkHotKeyID, optionKey), (Self.typingHotKeyID, optionKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x54434C31), id: id) // 'TCL1'
            RegisterEventHotKey(
                UInt32(kVK_Space),
                UInt32(modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if let ref { hotKeyRefs.append(ref) }
        }
    }

    func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs = []
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
