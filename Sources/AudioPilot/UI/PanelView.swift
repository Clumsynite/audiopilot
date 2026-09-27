import Combine
import AudioPilotCore
import SwiftUI

/// UI state for the panel: palette visibility, query, selection.
final class PanelUIState: ObservableObject {
    @Published var showPalette = false
    @Published var query = ""
    @Published var selection = 0
    unowned let model: AppModel
    /// Set by the controller; closes the whole panel.
    var dismiss: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    var results: [PaletteCommand] {
        PaletteCommands.filter(query, PaletteCommands.all(model))
    }

    func openPalette(query: String = "") {
        self.query = query
        selection = 0
        withAnimation(.snappy(duration: 0.22)) { showPalette = true }
    }

    func closePalette() {
        withAnimation(.snappy(duration: 0.18)) { showPalette = false }
        query = ""
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func runSelected() {
        let list = results
        guard list.indices.contains(selection) else { return }
        let command = list[selection]
        command.run()
        if command.keepsPanelOpen {
            model.refresh()
        } else {
            closePalette()
            dismiss()
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState

    var body: some View {
        Group {
            if ui.showPalette {
                // The panel shrinks to the palette while searching.
                CommandPaletteView(model: model, ui: ui)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    MicModule(model: model)
                    warnings
                    DeviceModule(model: model, dir: .output)
                    DeviceModule(model: model, dir: .input)
                    actions
                }
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(ThemeBackdrop(theme: model.theme))
        .tint(model.theme.accent)
    }

    // MARK: Warnings

    @ViewBuilder
    private var warnings: some View {
        let items = warningItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { text in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(text).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var warningItems: [String] {
        var items: [String] = []
        if !model.mute.unmutable.isEmpty {
            items.append("Can't mute " + model.mute.unmutable.values.sorted().joined(separator: ", "))
        }
        if !model.mute.cantHold.isEmpty {
            items.append("Another app keeps unmuting " + model.mute.cantHold.map(model.name).sorted().joined(separator: ", "))
        }
        if model.isMuteKeyRunning { items.append("MuteKey is also running") }
        if !model.hotKeyError.isEmpty { items.append(model.hotKeyError) }
        return items
    }

    // MARK: Actions (menu-style rows)

    private var actions: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Automatic Switching", shortcut: nil) {
                model.setAutoSwitch(!model.prefs.autoSwitchEnabled)
            } trailing: {
                Toggle("", isOn: Binding(get: { model.prefs.autoSwitchEnabled }, set: { model.setAutoSwitch($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if !model.prefs.profiles.isEmpty {
                HStack {
                    Text("Profile").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: Binding(get: { model.prefs.activeProfileID ?? model.prefs.profiles[0].id },
                                                  set: { model.switchProfile($0) })) {
                        ForEach(model.prefs.profiles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
            MenuRow(title: "Search…", shortcut: "⌘K") { ui.openPalette() }
            MenuRow(title: "Settings…", shortcut: "⌘,") { model.openSettings() }
            MenuRow(title: "About AudioPilot", shortcut: nil) { model.openAbout() }
            MenuRow(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.top, 2)
    }
}

// MARK: - Microphone module

/// Control Center-style module: round toggle, title, state.
private struct MicModule: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let muted = model.mute.isMuted
        Button { model.toggleMute() } label: {
            HStack(spacing: 10) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(muted ? Color.white : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(muted ? Color.red : Color.primary.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        if !model.micUsers.isEmpty {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                        Text(status(muted)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(KeyNames.string(model.prefs.hotkey) + (model.prefs.hotkeyMode == .pushToTalk ? " hold" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(cornerRadius: 14)
        .help(muted ? "Unmute all microphones" : "Mute all microphones")
    }

    /// "On", "Muted", or who is using the mic, e.g. "On · Zoom is listening".
    private func status(_ muted: Bool) -> String {
        let base = muted ? model.muteHeadline : "On"
        let names = model.micUsers.map(\.name)
        guard !names.isEmpty else { return base }
        let who = names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
        return "\(base) · \(who) using mic"
    }
}

// MARK: - Device module

private struct DeviceModule: View {
    @ObservedObject var model: AppModel
    let dir: Direction

    var body: some View {
        let devices = model.devices(dir)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(dir == .output ? "Output" : "Input").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let note = model.note(dir) {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let next = model.prefs.deviceShortcuts[DeviceShortcut.next(dir).key] {
                    Text(KeyNames.string(next)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help(dir == .output ? "Next output device" : "Next input device")
                }
            }
            .padding(.horizontal, 4)

            if model.current(dir) != nil {
                VolumeSlider(model: model, dir: dir)
                    .padding(.horizontal, 4)
                if dir == .input && model.prefs.levelMeter && !model.mute.isMuted {
                    LevelBar(level: model.micLevel, tint: model.theme.accent)
                        .padding(.leading, 24)
                        .padding(.trailing, 4)
                }
            }

            VStack(spacing: 0) {
                if devices.isEmpty {
                    Text("No devices").font(.system(size: 12)).foregroundStyle(.secondary).padding(6)
                }
                ForEach(devices, id: \.uid) { dev in
                    DeviceRow(model: model, dev: dev, dir: dir)
                }
                if dir == .output {
                    ForEach(model.disconnectedBluetooth) { bt in
                        ConnectRow(model: model, device: bt)
                    }
                }
            }
        }
        .padding(10)
        .glassSurface(cornerRadius: 14)
    }
}

private struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let dev: AudioDeviceInfo
    let dir: Direction
    @State private var hovering = false

    var body: some View {
        let isCurrent = model.engine.state.current[dir] == dev.uid
        let blocked = dir == .input && model.isBlocked(dev.uid)
        Button { model.pick(dir, dev.uid) } label: {
            HStack(spacing: 8) {
                Image(systemName: model.icon(dev, dir))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .frame(width: 24, height: 24)
                    .background(isCurrent ? model.theme.accent : Color.primary.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.label(dev)).font(.system(size: 13)).lineLimit(1)
                    if blocked {
                        Text("Mic off to keep audio quality").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let battery = model.battery(for: dev) {
                    Label(battery, systemImage: "battery.75percent")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let spec = model.prefs.deviceShortcuts[DeviceShortcut.device(dir, dev.uid).key] {
                    Text(KeyNames.string(spec)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(blocked ? "Click to use this Bluetooth mic (switches the headset to call-quality audio)" : dev.name)
        .contextMenu { DeviceContextMenu(model: model, dev: dev, dir: dir) }
    }
}

private struct VolumeSlider: View {
    @ObservedObject var model: AppModel
    let dir: Direction
    @State private var value: Double = 0
    @State private var available = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: dir == .output ? "speaker.fill" : "mic.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: Binding(get: { value }, set: { value = $0; model.setVolume(dir, Float($0)) }), in: 0...1)
                .controlSize(.small)
        }
            .disabled(!available || (dir == .input && model.mute.isMuted))
            .opacity(available ? 1 : 0.4)
            .help(available ? (dir == .output ? "Output volume" : "Input level") : "This device has no volume control")
            .onAppear(perform: load)
            .onReceive(timer) { _ in load() }
            .onChange(of: model.revision) { _, _ in load() }
    }

    private func load() {
        if let v = model.volume(dir) {
            available = true
            if abs(Double(v) - value) > 0.01 { value = Double(v) }
        } else {
            available = false
        }
    }
}

/// Thin live input-level bar.
private struct LevelBar: View {
    let level: Float
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(level > 0.85 ? Color.orange : tint)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 4)
        .help("Input level")
    }
}

/// A paired Bluetooth device that isn't connected; clicking connects it.
private struct ConnectRow: View {
    @ObservedObject var model: AppModel
    let device: BluetoothMonitor.Device
    @State private var hovering = false
    @State private var connecting = false

    var body: some View {
        Button {
            connecting = true
            model.setBluetoothConnected(device, true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.name.lowercased().contains("airpods") ? "airpods" : "headphones")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
                Text(device.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Text(connecting ? "Connecting…" : "Connect").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Connect \(device.name)")
    }
}

/// A row that looks and behaves like a macOS menu item.
private struct MenuRow<Trailing: View>: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    init(title: String, shortcut: String?, action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary) }
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The app's mark: a gradient squircle with a mic.
struct AppGlyph: View {
    var size: CGFloat
    var theme: PanelTheme = .aurora

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(theme.accent)
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
