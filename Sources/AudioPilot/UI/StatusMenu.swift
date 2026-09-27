import AppKit
import AudioPilotCore

/// The menu bar item. Left click opens the glass panel, right click (or ⌃-click) shows a quick menu,
/// ⌥-click toggles mute.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    var openSettings: (() -> Void)?
    var togglePanel: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.engine.observe { [weak self] in self?.updateIcon() }
        model.mute.observe { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    /// The button's frame in screen coordinates, for positioning the panel.
    var buttonFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            if let button = item.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            }
        } else if flags.contains(.option) {
            model.toggleMute(feedback: true)
        } else {
            togglePanel?()
        }
    }

    func updateIcon() {
        guard let button = item.button else { return }
        let image: NSImage?
        var alpha: CGFloat = 1
        if model.mute.isMuted {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [.systemRed]))
            image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
        } else if !model.mute.unmutable.isEmpty {
            image = (NSImage(systemSymbolName: "mic.badge.xmark", accessibilityDescription: "Some microphones can't be muted")
                ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil))
            image?.isTemplate = true
        } else {
            let paused = !model.prefs.autoSwitchEnabled
            image = NSImage(systemSymbolName: paused ? "mic" : "mic.fill", accessibilityDescription: "Microphone on")
            image?.isTemplate = true
            alpha = paused ? 0.5 : 1
        }
        button.image = image
        button.alphaValue = alpha
        // e.g. "AudioPilot — All microphones muted" + one line per mic, marking the active one.
        button.toolTip = (["AudioPilot — \(model.muteHeadline)"] + model.muteDetailLines).joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = model.prefs
        let muted = model.mute.isMuted

        let muteItem = ActionItem(muted ? "Unmute Microphone" : "Mute Microphone") { [weak self] in
            self?.model.mute.toggle()
        }
        muteItem.image = NSImage(systemSymbolName: muted ? "mic.fill" : "mic.slash.fill", accessibilityDescription: nil)
        menu.addItem(muteItem)
        menu.addItem(.disabled("Shortcut: \(KeyNames.string(prefs.hotkey))\(prefs.hotkeyMode == .pushToTalk ? " (hold to talk)" : "")"))

        if !model.mute.unmutable.isEmpty {
            menu.addItem(.disabled("⚠︎ Can't mute: " + model.mute.unmutable.values.sorted().joined(separator: ", ")))
        }
        if !model.mute.cantHold.isEmpty {
            menu.addItem(.disabled("⚠︎ Another app keeps unmuting: " + model.mute.cantHold.map(model.name).sorted().joined(separator: ", ")))
        }
        if model.isMuteKeyRunning {
            menu.addItem(.disabled("⚠︎ MuteKey is running — hotkey/mute may conflict"))
        }

        for dir in [Direction.output, .input] {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: dir == .output ? "Output" : "Input"))
            let state = model.engine.state
            let devices = state.connected.filter { $0.qualifies(for: dir) }
            let order = prefs.priority(dir)
            let sorted = devices.sorted { (order.firstIndex(of: $0.uid) ?? .max, $0.name) < (order.firstIndex(of: $1.uid) ?? .max, $1.name) }
            for dev in sorted {
                var title = model.label(dev)
                if dir == .input, DevicePolicy.isBlockedMic(dev.uid, in: state) {
                    title += "  (Bluetooth mic blocked — click to allow)"
                }
                let entry = ActionItem(title) { [weak self] in
                    self?.model.engine.send(.userPicked(dir, dev.uid))
                }
                entry.state = state.current[dir] == dev.uid ? .on : .off
                entry.indentationLevel = 1
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let auto = ActionItem("Auto-switch Devices") { [weak self] in
            guard let self else { return }
            model.engine.send(.setAutoSwitch(!model.prefs.autoSwitchEnabled))
        }
        auto.state = prefs.autoSwitchEnabled ? .on : .off
        menu.addItem(auto)

        let recentItem = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let recent = model.engine.recent
        if recent.isEmpty { sub.addItem(.disabled("Nothing yet")) }
        recent.forEach { sub.addItem(.disabled($0)) }
        recentItem.submenu = sub
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let settings = ActionItem("Settings…") { [weak self] in self?.openSettings?() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = ActionItem("Quit AudioPilot") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }
}

/// Target object that runs a closure; retained by the menu item via `representedObject`.
final class ClosureTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }
}

/// NSMenuItem that runs a closure.
func ActionItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
    let target = ClosureTarget(handler)
    let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    return item
}

extension NSMenuItem {
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
