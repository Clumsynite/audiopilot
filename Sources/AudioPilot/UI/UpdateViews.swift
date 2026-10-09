import AppKit
import AudioPilotCore
import SwiftUI

/// Panel card, shown only while there's something to do: an update to get, a download running, one ready
/// to install, a failed download, or (once) what changed in the version just installed.
struct UpdateCard: View {
    @ObservedObject var updater: Updater
    var theme: PanelTheme

    var body: some View {
        if let done = updater.justUpdated {
            card(symbol: "checkmark", title: "Updated to \(done.version)") {
                NotesView(markdown: done.notes, limit: 4)
                Button("Got It") { updater.dismissJustUpdated() }.controlSize(.small)
            }
        } else {
            switch updater.state {
            case let .available(m):
                card(symbol: "arrow.down", title: "AudioPilot \(m.version) is out") {
                    Text("Download it now and restart when you're ready.").secondaryCaption()
                    Button("Download Update") { updater.download() }.controlSize(.small)
                }
            case let .downloading(m, fraction):
                card(symbol: "arrow.down", title: "AudioPilot \(m.version) is out") {
                    Text("Downloading and checking the file…").secondaryCaption()
                    ProgressView(value: fraction).controlSize(.small)
                }
            case let .ready(m, _):
                card(symbol: "arrow.clockwise", title: "AudioPilot \(m.version) is ready") {
                    Text("Downloaded and verified. AudioPilot restarts to finish, by itself once you're off calls if automatic updates are on.").secondaryCaption()
                    Button("Restart to Update") { updater.install() }.controlSize(.small)
                }
            case let .failed(reason) where reason != Updater.offline:
                card(symbol: "exclamationmark.triangle", title: "Update didn't finish") {
                    Text(reason).secondaryCaption()
                    HStack {
                        Button("Try Again") { updater.check() }
                        Button("Website") { updater.openDownloadPage() }
                    }
                    .controlSize(.small)
                }
            default:
                EmptyView()
            }
        }
    }

    private func card(symbol: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassSurface(cornerRadius: 14)
    }
}

/// Settings › General › Updates.
struct UpdateSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(updater.version)")
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Now") { updater.check() }
                    .disabled(!updater.enabled || updater.state == .checking)
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { model.prefs.autoCheckUpdates }, set: { on in model.edit { $0.autoCheckUpdates = on } }))
                .disabled(!updater.enabled)
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { model.prefs.autoInstallUpdates }, set: { on in model.edit { $0.autoInstallUpdates = on } }))
                .disabled(!updater.enabled || !model.prefs.autoCheckUpdates)
            if case let .available(m) = updater.state {
                NotesView(markdown: m.notes, limit: 12)
                HStack {
                    Button("Download Update") { updater.download() }
                    Button("Website") { updater.openDownloadPage() }
                }
            }
            if case let .ready(m, _) = updater.state {
                Button("Restart to Update to \(m.version)") { updater.install() }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("AudioPilot checks its website for a new version every few hours. Updates are signed and verified before they're installed. Automatic installs wait until no app is using the mic and no per-app audio is playing, then AudioPilot restarts by itself (or the update goes in when you quit).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        guard updater.enabled else { return "Development builds don't update." }
        switch updater.state {
        case .checking: return "Checking…"
        case .upToDate: return "Up to date."
        case let .available(m): return "Version \(m.version) is available."
        case let .downloading(m, f): return "Downloading \(m.version)… \(Int(f * 100))%"
        case let .ready(m, _): return "Version \(m.version) is ready to install."
        case let .failed(reason): return reason
        case .idle:
            guard let last = updater.lastChecked else { return "Not checked yet." }
            return "Last checked \(last.formatted(.relative(presentation: .named)))."
        }
    }
}

/// A release's CHANGELOG section: headings and bullet items, Markdown inline styling kept.
struct NotesView: View {
    let markdown: String
    var limit: Int

    var body: some View {
        let blocks = ReleaseNotes.blocks(markdown)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(blocks.prefix(limit).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text):
                    Text(text).font(.caption.weight(.semibold)).padding(.top, 2)
                case let .item(text):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•")
                        Text(Self.inline(text))
                    }
                    .font(.caption)
                case let .text(text):
                    Text(Self.inline(text)).font(.caption)
                }
            }
            if blocks.count > limit {
                Text("…and more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private extension Text {
    func secondaryCaption() -> some View {
        font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
