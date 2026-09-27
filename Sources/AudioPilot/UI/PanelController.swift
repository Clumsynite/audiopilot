import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app (like Spotlight).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the glass panel under the menu bar icon. Handles sizing, dismissal and palette keys.
final class PanelController: NSObject, NSWindowDelegate {
    static let cornerRadius: CGFloat = 18

    private let model: AppModel
    let ui: PanelUIState
    private var panel: FloatingPanel?
    private var hosting: NSHostingView<PanelRoot>?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    /// Returns the status item button's frame in screen coordinates, if visible.
    var anchorProvider: () -> NSRect? = { nil }

    var isVisible: Bool { panel?.isVisible ?? false }
    /// Called with true when the panel opens and false when it closes.
    var onVisibilityChange: (Bool) -> Void = { _ in }
    /// Dry-run previews keep the panel open regardless of clicks elsewhere.
    var pinned = false

    init(model: AppModel) {
        self.model = model
        self.ui = PanelUIState(model: model)
        super.init()
        ui.dismiss = { [weak self] in self?.close() }
    }

    func toggle() {
        isVisible ? close() : show(palette: false)
    }

    func show(palette: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if palette { ui.openPalette() } else { ui.closePalette() }
        model.refresh()
        model.refreshBluetooth()
        computeAnchor()
        resize()
        panel.alphaValue = 0
        // Previews must never take keyboard focus from whatever the user is typing in.
        if pinned { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        installMonitors()
        onVisibilityChange(true)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        ui.closePalette()
        onVisibilityChange(false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !pinned { close() }
    }

    // MARK: Building

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let root = PanelRoot(model: model, ui: ui) { [weak self] _ in
            DispatchQueue.main.async { self?.resize() }
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting

        panel.contentView = Self.glassContainer(hosting: hosting)
        return panel
    }

    /// Liquid Glass window backing on macOS 26, a vibrant material before that.
    private static func glassContainer(hosting: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    // MARK: Layout

    private func computeAnchor() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        // Only trust the status item frame when it's really in a menu bar (it can be hidden
        // behind the notch or not laid out yet).
        let inMenuBar: (NSRect) -> Bool = { rect in
            NSScreen.screens.contains { s in
                rect.width > 0 && s.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) && rect.maxY >= s.visibleFrame.maxY - 2
            }
        }
        if let rect = anchorProvider(), inMenuBar(rect) {
            anchorTop = rect.minY - 6
            anchorMidX = rect.midX
        } else if let screen {
            anchorTop = screen.visibleFrame.maxY - 8
            anchorMidX = screen.visibleFrame.maxX - 200
        }
    }

    /// Keeps the top edge pinned under the menu bar while the content height changes.
    private func resize() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorMidX, y: anchorTop)) } ?? NSScreen.main
        var x = anchorMidX - size.width / 2
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchorTop - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Keyboard & dismissal

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return handleKey(event) ? nil : event
        }
        // Mouse monitors for other apps need no permission; they catch clicks outside the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.pinned == false { self?.close() } }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: // esc
            if ui.showPalette && !ui.query.isEmpty { ui.query = "" }
            else if ui.showPalette { ui.closePalette() }
            else { close() }
            return true
        case 126 where ui.showPalette: ui.move(-1); return true // up
        case 125 where ui.showPalette: ui.move(1); return true // down
        case 36, 76: // return
            if ui.showPalette { ui.runSelected(); return true }
            return false
        default: break
        }
        if cmd {
            switch chars {
            case "k": ui.showPalette ? ui.closePalette() : ui.openPalette(); return true
            case ",": close(); model.openSettings(); return true
            case "q": NSApp.terminate(nil); return true
            case "w": close(); return true
            default: return false
            }
        }
        // Typing anywhere in the panel starts a search.
        if !ui.showPalette, !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
           let typed = event.characters, typed.count == 1, typed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            ui.openPalette(query: typed)
            return true
        }
        return false
    }
}

/// Root view: the panel plus a size reporter so the window can follow the content height.
struct PanelRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    var onSize: (CGSize) -> Void

    var body: some View {
        PanelView(model: model, ui: ui)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { onSize(geo.size) }
                    .onChange(of: geo.size) { _, new in onSize(new) }
            })
    }
}
