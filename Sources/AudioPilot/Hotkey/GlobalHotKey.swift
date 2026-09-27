import Carbon
import AudioPilotCore

/// System-wide hotkeys via Carbon `RegisterEventHotKey`, which needs no Accessibility permission
/// and reports key-up too (for push-to-talk). Each hotkey has a slot so several can coexist.
final class GlobalHotKey {
    /// Identifies one registered hotkey. Fixed slots for app-wide actions; device shortcuts get dynamic ones.
    struct Slot: Hashable {
        let rawValue: UInt32
        static let mute = Slot(rawValue: 1)
        static let palette = Slot(rawValue: 2)
        static let firstDynamic: UInt32 = 100
    }

    struct Handlers {
        var press: (() -> Void)?
        var release: (() -> Void)?
    }

    private var handlers: [Slot: Handlers] = [:]
    private var refs: [Slot: EventHotKeyRef] = [:]
    private(set) var registered: [Slot: HotKeySpec] = [:]
    private var handlerRef: EventHandlerRef?

    func setHandlers(_ slot: Slot, press: (() -> Void)?, release: (() -> Void)? = nil) {
        handlers[slot] = Handlers(press: press, release: release)
    }

    /// Registers `spec` in `slot`, replacing what was there. On failure the previous hotkey is restored.
    @discardableResult
    func register(_ spec: HotKeySpec, slot: Slot) -> OSStatus {
        installHandler()
        let previous = registered[slot]
        unregister(slot)
        let status = registerRaw(spec, slot: slot)
        if status != noErr, let previous {
            _ = registerRaw(previous, slot: slot)
        }
        return status
    }

    func unregister(_ slot: Slot) {
        if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        refs[slot] = nil
        registered[slot] = nil
    }

    func unregisterAll() {
        Array(refs.keys).forEach(unregister)
    }

    func removeHandlers(_ slot: Slot) {
        handlers[slot] = nil
    }

    private func registerRaw(_ spec: HotKeySpec, slot: Slot) -> OSStatus {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4175_5069, id: slot.rawValue) // 'AuPi'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot] = ref
            registered[slot] = spec
        }
        return status
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    fileprivate func handle(kind: UInt32, id: UInt32) {
        guard let h = handlers[Slot(rawValue: id)] else { return }
        if kind == UInt32(kEventHotKeyPressed) { h.press?() } else { h.release?() }
    }
}

private nonisolated func hotKeyEventHandler(_: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let kind = GetEventKind(event)
    let id = hotKeyID.id
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.handle(kind: kind, id: id) }
    return noErr
}
