import AppKit
import Carbon.HIToolbox
import os

/// Global hotkeys via Carbon RegisterEventHotKey (same mechanism Tama uses):
/// ⌥Space opens the panel as usual; ⇧⌥Space opens it for typing, mic off;
/// ⌃⌥I opens it ready for an image.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    var onHotKey: (() -> Void)?
    var onTypingHotKey: (() -> Void)?
    var onImageHotKey: (() -> Void)?

    /// Carbon IDs for the shortcuts; the handler tells them apart by these.
    static let talkHotKeyID: UInt32 = 1
    static let typingHotKeyID: UInt32 = 2
    static let imageHotKeyID: UInt32 = 3

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    /// Which callback a pressed shortcut runs. Split out so the self-test can
    /// check the routing without pressing keys.
    func handle(hotKeyID: UInt32) {
        os.Logger(subsystem: "com.universe.app", category: "hotkey").info("Shortcut pressed: id \(hotKeyID, privacy: .public)")
        switch hotKeyID {
        case Self.typingHotKeyID: onTypingHotKey?()
        case Self.imageHotKeyID: onImageHotKey?()
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
        let shortcuts = [
            (Self.talkHotKeyID, kVK_Space, optionKey),
            (Self.typingHotKeyID, kVK_Space, optionKey | shiftKey),
            (Self.imageHotKeyID, kVK_ANSI_I, optionKey | controlKey),
        ]
        for (id, key, modifiers) in shortcuts {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x54434C31), id: id) // 'TCL1'
            RegisterEventHotKey(
                UInt32(key),
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
