import AppKit
import SwiftUI

final class AboutWindow {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// `activate: false` (previews) shows the window without taking focus from the user.
    func show(activate: Bool = true) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView(model: model)))
            w.title = "About AudioPilot"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
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

struct AboutView: View {
    @ObservedObject var model: AppModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            AppGlyph(size: 80, theme: model.theme)
                .padding(.top, 18)
            VStack(spacing: 4) {
                Text("AudioPilot").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
            Text("A smart audio device manager with a global mic mute.\nKeeps your AirPods sounding great, remembers your devices, and mutes every mic with one shortcut.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                feature("wand.and.stars", "Auto-switches input & output by learned priority")
                feature("airpodspro", "Blocks Bluetooth mic hijack (no more call-quality audio)")
                feature("mic.slash.fill", "Mutes all mics — toggle or push-to-talk")
                feature("command", "⌘K command palette and audiopilot:// links for Shortcuts")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 16)

            HStack(spacing: 10) {
                Button("Settings…") { model.openSettings() }
                Button("Show Data Folder") {
                    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("AudioPilot")
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                }
            }
            .controlSize(.regular)

            Text("Built with CoreAudio, SwiftUI and Liquid Glass. Inspired by MuteKey, SoundSource and MicPriority.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 28)
        .frame(width: 460)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(model.theme.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
