import AppKit
import ApplicationServices
import os

/// Keeps meeting apps' own mute buttons in step with AudioPilot (needs Accessibility permission).
/// - Zoom: presses "Mute Audio" / "Unmute Audio" in its Meeting menu, so it's state-aware.
/// - Microsoft Teams: sends its ⌘⇧M toggle, only while Teams is using the mic (it can drift if
///   you also mute inside Teams).
enum MeetingSync {
    private static let logger = Logger(subsystem: "com.techenable.audiopilot", category: "meetings")
    static let zoom = "us.zoom.xos"
    static let teams = ["com.microsoft.teams2", "com.microsoft.teams"]

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt to grant Accessibility access.
    static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt (a C global Swift 6 treats as mutable).
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Applies `muted` to running meeting apps. `micUsers` are the bundle IDs currently capturing audio.
    static func apply(muted: Bool, micUsers: [String]) {
        guard trusted else { return }
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { $0.bundleIdentifier == zoom }) {
            pressZoomMenu(app.processIdentifier, muted: muted)
        }
        if let app = running.first(where: { teams.contains($0.bundleIdentifier ?? "") }),
           micUsers.contains(app.bundleIdentifier ?? "") {
            sendTeamsToggle(app.processIdentifier)
        }
    }

    private static func pressZoomMenu(_ pid: pid_t, muted: Bool) {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute),
              let items: [AXUIElement] = attribute(menuBar, kAXChildrenAttribute),
              let meeting = items.first(where: { title($0) == "Meeting" }),
              let menus: [AXUIElement] = attribute(meeting, kAXChildrenAttribute),
              let menu = menus.first,
              let entries: [AXUIElement] = attribute(menu, kAXChildrenAttribute) else { return }
        let wanted = muted ? "mute audio" : "unmute audio"
        guard let entry = entries.first(where: { title($0)?.lowercased() == wanted }) else { return }
        let status = AXUIElementPerformAction(entry, kAXPressAction as CFString)
        if status != .success { logger.error("zoom menu press failed: \(status.rawValue)") }
    }

    private static func sendTeamsToggle(_ pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let m: CGKeyCode = 46
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: down) else { continue }
            event.flags = [.maskCommand, .maskShift]
            event.postToPid(pid)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func title(_ element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute)
    }
}
