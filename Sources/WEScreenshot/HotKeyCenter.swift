import Carbon.HIToolbox
import Foundation
import WECore

/// The one global hotkey of the app, registered through Carbon (the only
/// public API that needs no extra permission).
@MainActor
final class HotKeyCenter {
    private static let signature: OSType = 0x5745_5348 // "WESH"
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var paused = false

    /// The combination the app wants to be active (registered unless paused).
    private(set) var current: KeyCombo?

    /// Called on the main thread when the hotkey is pressed.
    var onPress: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == HotKeyCenter.signature, id.id == HotKeyCenter.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Application event handlers run on the main thread; hop to the main actor.
            Task { @MainActor in center.onPress?() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        if status != noErr { NSLog("WE Screenshot: cannot install the hotkey handler (%d)", Int(status)) }
    }

    /// Replaces the registered hotkey. Returns false when macOS refused it (for
    /// example another app owns it); the previous hotkey is gone in that case,
    /// so the caller registers the old one again.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregisterNow()
        current = combo
        guard !paused else { return true }
        return registerNow(combo)
    }

    /// Releases the hotkey and forgets it.
    func unregister() {
        unregisterNow()
        current = nil
    }

    /// Releases the hotkey while the settings window records a new shortcut,
    /// otherwise pressing the old one would start a capture instead.
    func pause() {
        paused = true
        unregisterNow()
    }

    func resume() {
        guard paused else { return }
        paused = false
        if let combo = current { _ = registerNow(combo) }
    }

    private func registerNow(_ combo: KeyCombo) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotKeyCenter.signature, id: HotKeyCenter.hotKeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregisterNow() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }
}
