import AppKit
import SwiftUI

/// Optional always-visible "Muted" pill in the top-right corner while the mic is muted. Click-through.
final class MutedOverlay {
    private var panel: NSPanel?

    func update(visible: Bool) {
        if visible { show() } else { panel?.orderOut(nil) }
    }

    private func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
    }

    private func make() -> NSPanel {
        let hosting = NSHostingView(rootView: MutedPill())
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        return panel
    }
}

private struct MutedPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.slash.fill")
            Text("Muted")
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: 14, tint: .red.opacity(0.75))
        .padding(4)
    }
}
