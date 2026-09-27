import AppKit
import SwiftUI

/// On-screen glass indicator for mute toggles and device switches, styled like the system HUDs.
/// The window is backed by real Liquid Glass (`NSGlassEffectView`) on macOS 26, a HUD material before.
final class HUD {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private let state = HUDState()

    /// `detail` is usually the input device name.
    func showMute(_ muted: Bool, detail: String? = nil) {
        show(.init(symbol: muted ? "mic.slash.fill" : "mic.fill",
                   title: muted ? "Microphone Off" : "Microphone On",
                   detail: detail, tint: muted ? .red : Color(nsColor: .systemGreen), style: .large),
             duration: 1.1)
    }

    func showSwitch(symbol: String, title: String, subtitle: String) {
        show(.init(symbol: symbol, title: title, detail: subtitle, tint: .accentColor, style: .banner), duration: 1.8)
    }

    private func show(_ content: HUDContent, duration: TimeInterval) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        let styleChanged = state.content?.style != content.style
        withAnimation(.snappy(duration: 0.25)) { state.content = content }

        if styleChanged || !wasVisible { layout(panel, content.style) }
        hide?.cancel()
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            state.appeared = false
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { state.appeared = true }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        let item = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.state.appeared = false }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            }
        }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    private func layout(_ panel: NSPanel, _ style: HUDContent.Style) {
        let size = style == .large ? NSSize(width: 340, height: 72) : NSSize(width: 300, height: 64)
        let radius: CGFloat = size.height / 2
        panel.contentView = Self.glass(radius: radius, content: NSHostingView(rootView: HUDView(state: state)))
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = style == .large
            ? NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.12)
            : NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 16)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func glass(radius: CGFloat, content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

struct HUDContent: Equatable {
    enum Style { case large, banner }
    var symbol: String
    var title: String
    var detail: String?
    var tint: Color
    var style: Style
}

final class HUDState: ObservableObject {
    @Published var content: HUDContent?
    @Published var appeared = false
}

private struct HUDView: View {
    @ObservedObject var state: HUDState

    var body: some View {
        if let c = state.content {
            Group {
                if c.style == .large { large(c) } else { banner(c) }
            }
            .scaleEffect(state.appeared ? 1 : 0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Mute capsule: solid round badge (red = off) with the mic glyph, state, then the mic name.
    private func large(_ c: HUDContent) -> some View {
        HStack(spacing: 14) {
            Image(systemName: c.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 46, height: 46)
                .background(c.tint.gradient, in: Circle())
                .shadow(color: c.tint.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title)
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.opacity)
                if let detail = c.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
        .padding(.trailing, 20)
    }

    private func banner(_ c: HUDContent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(c.tint)
                .frame(width: 36, height: 36)
                .background(c.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let detail = c.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }
}
