import AppKit
import AudioPilotCore

/// Actions addressable by a stable ID, shared by the command palette, Spotlight, `audiopilot://run?id=`
/// and device shortcuts. IDs: `mute.toggle`, `auto.toggle`, `mode.toggle`, `overlay.toggle`,
/// `theme:<name>`, `settings`, `about`, `panel`, `palette`, `next:output`, `next:input`,
/// `output:<uid>`, `input:<uid>`.
extension AppModel {
    /// Runs an action. Returns false if the ID is unknown or its device isn't connected.
    @discardableResult
    func perform(_ id: String) -> Bool {
        if let shortcut = DeviceShortcut(key: id) { return perform(shortcut) }
        if id.hasPrefix("profile:"), let uuid = UUID(uuidString: String(id.dropFirst(8))),
           prefs.profiles.contains(where: { $0.id == uuid }) {
            switchProfile(uuid, announce: true)
            return true
        }
        if id.hasPrefix("theme:"), let theme = PanelTheme(rawValue: String(id.dropFirst(6))) {
            setTheme(theme)
            return true
        }
        switch id {
        case "mute.toggle": toggleMute(feedback: true)
        case "mute.on": setMuted(true, feedback: true)
        case "mute.off": setMuted(false, feedback: true)
        case "auto.toggle": setAutoSwitch(!prefs.autoSwitchEnabled)
        case "mode.toggle": setHotKeyMode(prefs.hotkeyMode == .pushToTalk ? .toggle : .pushToTalk)
        case "overlay.toggle": edit { $0.showMutedOverlay.toggle() }
        case "settings": openSettings()
        case "about": openAbout()
        case "panel": openPanel(false)
        case "palette": openPanel(true)
        default: return false
        }
        return true
    }

    @discardableResult
    func perform(_ shortcut: DeviceShortcut) -> Bool {
        switch shortcut {
        case let .next(dir):
            let ordered = devices(dir).map(\.uid)
            let skip: (String) -> Bool = { [unowned self] uid in dir == .input && isBlocked(uid) }
            guard let uid = DeviceCycle.next(after: engine.state.current[dir], in: ordered, skip: skip),
                  let dev = devices(dir).first(where: { $0.uid == uid }) else { return false }
            pick(dir, uid)
            onDeviceFeedback(dir, dev)
            return true
        case let .device(dir, uid):
            guard let dev = devices(dir).first(where: { $0.uid == uid }) else { return false }
            pick(dir, uid)
            onDeviceFeedback(dir, dev)
            return true
        }
    }

    // MARK: Device shortcuts

    /// Registers every shortcut in `prefs.deviceShortcuts` in its own hotkey slot.
    func applyDeviceShortcuts() {
        for slot in deviceSlots.keys {
            hotKey.unregister(slot)
            hotKey.removeHandlers(slot)
        }
        deviceSlots = [:]
        deviceShortcutErrors = [:]
        var next = GlobalHotKey.Slot.firstDynamic
        for (key, spec) in prefs.deviceShortcuts.sorted(by: { $0.key < $1.key }) {
            guard let shortcut = DeviceShortcut(key: key) else { continue }
            let slot = GlobalHotKey.Slot(rawValue: next)
            next += 1
            if spec == prefs.hotkey || spec == prefs.paletteHotkey {
                deviceShortcutErrors[key] = "Already used by AudioPilot."
                continue
            }
            let status = hotKey.register(spec, slot: slot)
            if status == noErr {
                hotKey.setHandlers(slot, press: { [weak self] in self?.perform(shortcut) })
                deviceSlots[slot] = key
            } else {
                deviceShortcutErrors[key] = KeyNames.describe(status)
            }
        }
        refresh()
    }

    /// Sets (or clears, with nil) the shortcut for `key`, then re-registers everything.
    func setDeviceShortcut(_ key: String, _ spec: HotKeySpec?) {
        if let spec, prefs.deviceShortcuts.contains(where: { $0.key != key && $0.value == spec }) {
            deviceShortcutErrors[key] = "Already used by another device shortcut."
            refresh()
            return
        }
        edit { $0.deviceShortcuts[key] = spec }
        applyDeviceShortcuts()
    }

    /// Temporarily releases all device shortcuts (while recording a new one).
    func suspendDeviceShortcuts() {
        deviceSlots.keys.forEach { hotKey.unregister($0) }
    }
}
