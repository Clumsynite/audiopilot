import AppKit
import SwiftUI

/// AppKit-owned Settings window (SwiftUI's `Settings` scene is unreliable from a menu-bar-only app).
final class SettingsWindow {
    /// Pane shown first (used by the dry-run preview).
    static var initialPane: SettingsPane = .general

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// `activate: false` (previews) shows the window without taking focus from the user.
    func show(activate: Bool = true) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "AudioPilot Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 900, height: 620))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if activate {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }
}
