import AppKit
import AudioPilotCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, devices, microphones, appAudio, shortcuts, rules, profiles, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .devices: "Devices"
        case .microphones: "Microphones"
        case .appAudio: "App Audio"
        case .shortcuts: "Shortcuts"
        case .rules: "App Rules"
        case .profiles: "Profiles"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .devices: "hifispeaker.2.fill"
        case .microphones: "mic.fill"
        case .appAudio: "slider.horizontal.3"
        case .shortcuts: "command"
        case .rules: "app.badge.fill"
        case .profiles: "rectangle.stack.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .pink
        case .devices: .blue
        case .microphones: .orange
        case .appAudio: .red
        case .shortcuts: .purple
        case .rules: .green
        case .profiles: .indigo
        case .about: .teal
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.settingsPane) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(item.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch model.settingsPane ?? .general {
                case .general: GeneralPane(model: model)
                case .appearance: AppearancePane(model: model)
                case .devices: DevicesPane(model: model)
                case .microphones: MicrophonesPane(model: model)
                case .appAudio: AppAudioPane(model: model)
                case .shortcuts: ShortcutsPane(model: model)
                case .rules: RulesPane(model: model)
                case .profiles: ProfilesPane(model: model)
                case .about: AboutView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle((model.settingsPane ?? .general).title)
        }
        .frame(minWidth: 720, minHeight: 520)
        .tint(model.theme.accent)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Microphone") {
                toggle("Start muted when AudioPilot launches", \.startMuted)
                toggle("Mute automatically when a call starts", \.autoMuteOnCallStart)
                if model.prefs.autoMuteOnCallStart {
                    AutoMuteAppsRow(model: model)
                }
                toggle("Tell me when another app mutes or unmutes the mic", \.notifyExternalMuteChanges)
                toggle("Mute when the screen locks or sleeps", \.muteOnLock)
                toggle("Show floating “Muted” indicator while muted", \.showMutedOverlay)
            }
            Section {
                Toggle("Show live input level in the panel", isOn: Binding(
                    get: { model.prefs.levelMeter }, set: { model.setMicFeature(\.levelMeter, $0) }))
                Toggle("Show live input level in the menu bar during calls", isOn: Binding(
                    get: { model.prefs.menuBarLevel }, set: { model.setMicFeature(\.menuBarLevel, $0) }))
                Toggle("Press the AirPods stem to mute (experimental)", isOn: Binding(
                    get: { model.prefs.airPodsMute }, set: { model.setMicFeature(\.airPodsMute, $0) }))
                Toggle("Keep Zoom and Teams mute buttons in sync", isOn: Binding(
                    get: { model.prefs.meetingSync }, set: { model.setMeetingSync($0) }))
                if model.prefs.meetingSync && !MeetingSync.trusted {
                    HStack {
                        Text("Needs Accessibility permission.").font(.caption).foregroundStyle(.orange)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .controlSize(.small)
                    }
                }
                if model.micPermissionDenied {
                    Text("Microphone access was denied. Allow AudioPilot in System Settings › Privacy & Security › Microphone.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("The meter opens the mic only while the panel is open (or, for the menu bar, while another app is already using it) and you're unmuted. AirPods stem presses reach AudioPilot most reliably while a call app is using the mic. Zoom sync uses its Meeting menu; Teams sync sends ⌘⇧M during calls and can drift if you also mute inside Teams.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                toggle("Show on-screen indicator when muting", \.showHUD)
                toggle("Play a sound when muting", \.playSound)
                toggle("Announce automatic device switches", \.announceSwitches)
            }
            Section("Devices") {
                Toggle("Automatically switch devices", isOn: Binding(get: { model.prefs.autoSwitchEnabled },
                                                                     set: { model.setAutoSwitch($0) }))
                toggle("Alert sounds follow the output device", \.systemSoundFollowsOutput)
            }
            Section {
                toggle("Show AudioPilot actions and devices in Spotlight", \.spotlightEnabled)
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Search Spotlight for “mute”, a device name, or “AudioPilot” to run actions without opening the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.prefs.launchAtLogin && model.loginItemStatus != .notRegistered },
                                                        set: { model.setLaunchAtLogin($0) }))
                    .disabled(!model.canUseLoginItem)
                if !model.canUseLoginItem {
                    Text("Move AudioPilot to the Applications folder to enable this.").font(.caption).foregroundStyle(.secondary)
                } else if model.loginItemStatus == .requiresApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if !model.loginError.isEmpty {
                    Text(model.loginError).font(.caption).foregroundStyle(.red)
                }
            }
            BackupSection(model: model)
            Section {
                Text("If AudioPilot quits while muted, your microphones stay muted until you relaunch AudioPilot and unmute.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<Preferences, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.prefs[keyPath: key] },
                                    set: { value in model.edit { $0[keyPath: key] = value } }))
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Panel theme").font(.headline)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(PanelTheme.allCases) { theme in
                        ThemeCard(theme: theme, selected: model.theme == theme) { model.setTheme(theme) }
                    }
                }
                Text("Themes tint the menu bar panel, command palette and About window. On macOS 26 they sit on Liquid Glass; earlier versions use frosted materials.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

private struct ThemeCard: View {
    let theme: PanelTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary)
                    ThemeBackdrop(theme: theme)
                        .opacity(theme == .glass ? 1 : 3)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(spacing: 6) {
                        HStack {
                            Circle().fill(theme.accent).frame(width: 18, height: 18)
                            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.35)).frame(width: 50, height: 6)
                            Spacer()
                        }
                        RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.1)).frame(height: 14)
                        RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.1)).frame(height: 14)
                    }
                    .padding(12)
                    .glassSurface(cornerRadius: 10)
                    .padding(10)
                }
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? theme.accent : .secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1))
                HStack(spacing: 4) {
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                    Text(theme.title).font(.callout.weight(selected ? .semibold : .regular))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Devices

private struct DevicesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                list(.output, "Output priority")
                list(.input, "Input priority")
                Text("Drag to reorder — the first connected device wins. Select a device to rename, hide or tune it.")
                    .font(.caption).foregroundStyle(.secondary)
                OutputGroupsSection(model: model)
            }
            .padding(16)
            .frame(width: 250)
            Divider()
            Group {
                if let uid = model.selectedDeviceUID, model.prefs.knownDevices[uid] != nil {
                    DeviceDetail(model: model, uid: uid)
                } else {
                    Text("Select a device").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ dir: Direction, _ title: String) -> some View {
        let uids = model.prefs.priority(dir)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            List(selection: $model.selectedDeviceUID) {
                ForEach(uids, id: \.self) { uid in
                    DeviceRow(model: model, uid: uid, dir: dir).tag(uid)
                }
                .onMove { from, to in
                    var list = uids
                    list.move(fromOffsets: from, toOffset: to)
                    model.engine.send(.reorder(dir, list))
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let uid: String
    let dir: Direction

    var body: some View {
        let connected = model.isConnected(uid)
        let dev = model.engine.state.connected.first { $0.uid == uid }
        let settings = model.deviceSettings(uid)
        HStack(spacing: 8) {
            Image(systemName: dev.map { model.icon($0, dir) } ?? settings.icon ?? (dir == .input ? "mic" : "speaker.wave.2"))
                .frame(width: 20)
                .foregroundStyle(connected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name(uid)).lineLimit(1)
                Text(connected ? "Connected" : "Offline")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if settings.hidden {
                Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Hidden")
            }
        }
        .opacity(connected && !settings.hidden ? 1 : 0.6)
    }
}

/// Everything about one device: name, icon, visibility, audio format, balance and scripts.
private struct DeviceDetail: View {
    @ObservedObject var model: AppModel
    let uid: String
    @State private var name = ""
    @State private var onConnect = ""
    @State private var onDisconnect = ""
    @State private var balance: Double = 0.5

    var body: some View {
        let known = model.prefs.knownDevices[uid]
        let settings = model.deviceSettings(uid)
        let connected = model.isConnected(uid)
        let hal = model.engine.hal
        Form {
            Section {
                LabeledContent("Device", value: known?.name ?? uid)
                TextField("Display name", text: $name, prompt: Text(known?.name ?? ""))
                    .onSubmit(saveName)
                Picker("Icon", selection: Binding(get: { settings.icon ?? "" },
                                                  set: { v in model.editDevice(uid) { $0.icon = v.isEmpty ? nil : v } })) {
                    Text("Automatic").tag("")
                    ForEach(DeviceIconChoices.all, id: \.self) { symbol in
                        Label(DeviceIconChoices.title(symbol), systemImage: symbol).tag(symbol)
                    }
                }
                Toggle("Hide from menus and never pick automatically", isOn: Binding(
                    get: { settings.hidden }, set: { v in model.editDevice(uid) { $0.hidden = v } }))
            }

            if connected {
                Section("Audio") {
                    let rates = hal.sampleRates(uid)
                    if rates.count > 1 {
                        Picker("Sample rate", selection: Binding(
                            get: { hal.sampleRate(uid) ?? rates[0] },
                            set: { hal.setSampleRate(uid, $0); model.refresh() })) {
                            ForEach(rates, id: \.self) { Text(DeviceIconChoices.rateName($0)).tag($0) }
                        }
                    } else if let rate = hal.sampleRate(uid) {
                        LabeledContent("Sample rate", value: DeviceIconChoices.rateName(rate))
                    }
                    if known?.hasOutput == true, hal.balance(uid) != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Balance")
                                Spacer()
                                Button("Centre") { balance = 0.5 }
                                    .buttonStyle(.borderless)
                                    .disabled(abs(balance - 0.5) < 0.01)
                            }
                            Slider(value: $balance, in: 0...1) {
                                Text("Balance")
                            } minimumValueLabel: {
                                Text("L").font(.caption).foregroundStyle(.secondary)
                            } maximumValueLabel: {
                                Text("R").font(.caption).foregroundStyle(.secondary)
                            }
                            .labelsHidden()
                            .onChange(of: balance) { _, v in hal.setBalance(uid, Float(v)) }
                        }
                    }
                }
            }

            Section {
                commandField("When connected", $onConnect, "open -a Music")
                commandField("When disconnected", $onDisconnect, "shortcuts run \"Pause Music\"")
            } header: {
                Text("Run a command")
            } footer: {
                Text("Runs in zsh with $AUDIOPILOT_DEVICE_NAME and $AUDIOPILOT_EVENT set. Use shortcuts run \"Name\" to run a Shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: uid) { _, _ in load() }
        .onDisappear { saveName(); saveScripts() }
    }

    private func commandField(_ title: String, _ text: Binding<String>, _ example: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField("", text: text, prompt: Text(example))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .labelsHidden()
                .onSubmit(saveScripts)
        }
    }

    private func load() {
        let settings = model.deviceSettings(uid)
        name = settings.customName ?? ""
        onConnect = settings.onConnect ?? ""
        onDisconnect = settings.onDisconnect ?? ""
        balance = Double(model.engine.hal.balance(uid) ?? 0.5)
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        model.editDevice(uid) { $0.customName = n.isEmpty ? nil : n }
    }

    private func saveScripts() {
        let c = onConnect.trimmingCharacters(in: .whitespaces)
        let d = onDisconnect.trimmingCharacters(in: .whitespaces)
        model.editDevice(uid) {
            $0.onConnect = c.isEmpty ? nil : c
            $0.onDisconnect = d.isEmpty ? nil : d
        }
    }
}

// MARK: - Microphones

private struct MicrophonesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let mics = model.prefs.knownDevices.filter { $0.value.hasInput }.sorted { $0.value.name < $1.value.name }
        Form {
            Section {
                ForEach(mics, id: \.key) { uid, known in
                    Toggle(isOn: Binding(get: { known.allowAsMic },
                                         set: { model.engine.send(.setAllowAsMic(uid, $0)) })) {
                        VStack(alignment: .leading) {
                            Text(known.name)
                            Text(known.transport.rawValue + (model.isConnected(uid) ? "" : " · offline"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Allow as microphone")
            } footer: {
                Text("Using a Bluetooth headset's mic switches it to low-quality call audio, so Bluetooth and iPhone mics are off until you allow them here or pick them in the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var model: AppModel

    private let links: [(String, String)] = [
        ("audiopilot://toggle", "Toggle mute"),
        ("audiopilot://mute", "Mute all microphones"),
        ("audiopilot://unmute", "Unmute"),
        ("audiopilot://output?name=AirPods", "Switch output (name match)"),
        ("audiopilot://input?name=MacBook", "Switch input (name match)"),
        ("audiopilot://next?dir=output", "Next output device"),
        ("audiopilot://next?dir=input", "Next input device"),
        ("audiopilot://auto?on=toggle", "Pause / resume auto-switch"),
        ("audiopilot://theme?name=aurora", "Change theme"),
        ("audiopilot://palette?q=output", "Open the command palette"),
        ("audiopilot://panel", "Open the panel"),
    ]

    var body: some View {
        Form {
            Section("Keyboard") {
                LabeledContent("Mute microphone") {
                    HotKeyRecorder(current: model.prefs.hotkey,
                                   onBegin: { model.hotKey.unregister(.mute) },
                                   onCancel: { model.applyHotKey(model.prefs.hotkey) },
                                   onRecord: { model.applyHotKey($0) })
                }
                if !model.hotKeyError.isEmpty {
                    Text(model.hotKeyError).foregroundStyle(.red).font(.caption)
                }
                Picker("Mute mode", selection: Binding(get: { model.prefs.hotkeyMode }, set: { model.setHotKeyMode($0) })) {
                    Text("Toggle mute").tag(HotKeyMode.toggle)
                    Text("Push to talk (hold to unmute)").tag(HotKeyMode.pushToTalk)
                }
                Picker("Also mute with", selection: Binding(get: { model.prefs.extraTrigger },
                                                            set: { model.setExtraTrigger($0) })) {
                    ForEach(ExtraTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.prefs.extraTrigger != .none && !model.extraTriggerActive {
                    HStack {
                        Text("Needs Input Monitoring permission.").font(.caption).foregroundStyle(.orange)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                        .controlSize(.small)
                        Button("Retry") { model.setExtraTrigger(model.prefs.extraTrigger) }.controlSize(.small)
                    }
                }
                if model.prefs.extraTrigger == .globe {
                    Text("Tip: set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing” so macOS doesn't also open emoji or dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Command palette") {
                    HotKeyRecorder(current: model.prefs.paletteHotkey,
                                   onBegin: { model.hotKey.unregister(.palette) },
                                   onCancel: { model.applyPaletteHotKey(model.prefs.paletteHotkey) },
                                   onRecord: { model.applyPaletteHotKey($0) })
                }
                if !model.paletteHotKeyError.isEmpty {
                    Text(model.paletteHotKeyError).foregroundStyle(.red).font(.caption)
                }
            }
            DeviceShortcutsSection(model: model)
            Section {
                shortcutRow("⌘K", "Open the command palette — type a device name, “mute”, a theme…")
                shortcutRow("Just type", "Start searching from anywhere in the panel")
                shortcutRow("↑ ↓ ↩", "Choose and run a command")
                shortcutRow("⌘,", "Settings")
                shortcutRow("esc", "Close the palette or panel")
                shortcutRow("⌥-click", "Menu bar icon: toggle mute instantly")
                shortcutRow("Right-click", "Menu bar icon: quick menu")
            } header: {
                Text("In the panel")
            }
            Section {
                ForEach(links, id: \.0) { link, info in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text(info).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy")
                    }
                }
            } header: {
                Text("Shortcuts app & automation")
            } footer: {
                Text("In the Shortcuts app, add an “Open URLs” action with one of these links. They also work from Raycast, Alfred, Stream Deck, or `open \"audiopilot://toggle\"` in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ keys: String, _ text: String) -> some View {
        HStack {
            KeyCap(keys)
            Text(text).font(.callout)
            Spacer()
        }
    }
}

// MARK: - App rules

private struct RulesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let rules = model.prefs.appRules
        VStack(alignment: .leading, spacing: 0) {
            if rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.badge").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No app rules yet").font(.headline)
                    Text("A rule picks devices while an app is running, in front, or using the mic — e.g. use your USB headset whenever a call starts.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(rules) { rule in
                        RuleRow(model: model, rule: rule)
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                Menu("Add Running App") {
                    ForEach(runningApps(), id: \.bundleID) { app in
                        Button(app.name) { add(bundleID: app.bundleID, name: app.name) }
                    }
                }
                .fixedSize()
                Button("Choose App…") { chooseApp() }
                Button("Any App Using the Mic") {
                    add(bundleID: AppRule.anyApp, name: "Any app using the mic", trigger: .usingMic)
                }
                .help("Picks devices whenever any app starts using the microphone, e.g. when a call starts")
                .disabled(model.prefs.appRules.contains { $0.bundleID == AppRule.anyApp })
                Spacer()
            }
            .padding(16)
        }
    }

    private func runningApps() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name < $1.name }
    }

    private func add(bundleID: String, name: String, trigger: AppRule.Trigger = .running) {
        guard !model.prefs.appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        model.engine.send(.updateRules(model.prefs.appRules + [AppRule(bundleID: bundleID, appName: name, trigger: trigger)]))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(bundleID: id, name: name)
    }
}

private struct RuleRow: View {
    @ObservedObject var model: AppModel
    let rule: AppRule

    var body: some View {
        Section {
            devicePicker("Input", .input, \.inputUID)
            devicePicker("Output", .output, \.outputUID)
            if rule.bundleID == AppRule.anyApp {
                LabeledContent("When", value: "Any app is using the mic")
            } else {
                Picker("When", selection: binding(\.trigger)) {
                    Text("App is running").tag(AppRule.Trigger.running)
                    Text("App is in front").tag(AppRule.Trigger.frontmost)
                    Text("App is using the mic").tag(AppRule.Trigger.usingMic)
                }
            }
        } header: {
            HStack {
                appIcon
                Text(rule.appName)
                Spacer()
                Button(role: .destructive) {
                    model.engine.send(.updateRules(model.prefs.appRules.filter { $0.id != rule.id }))
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if rule.bundleID == AppRule.anyApp {
            Image(systemName: "mic.fill").frame(width: 18, height: 18)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        }
    }

    private func devicePicker(_ title: String, _ dir: Direction, _ key: WritableKeyPath<AppRule, String?>) -> some View {
        let known = model.prefs.knownDevices
            .filter { dir == .input ? $0.value.hasInput : $0.value.hasOutput }
            .sorted { $0.value.name < $1.value.name }
        return Picker(title, selection: binding(key)) {
            Text("Don't change").tag(String?.none)
            ForEach(known, id: \.key) { uid, device in
                Text(device.name).tag(String?.some(uid))
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<AppRule, T>) -> Binding<T> {
        Binding(get: { rule[keyPath: key] }, set: { value in
            let rules = model.prefs.appRules.map { r -> AppRule in
                guard r.id == rule.id else { return r }
                var copy = r
                copy[keyPath: key] = value
                return copy
            }
            model.engine.send(.updateRules(rules))
        })
    }
}

// MARK: - Device shortcuts

private struct DeviceShortcutsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            row(.next(.output), "Next output device", symbol: "speaker.wave.2")
            row(.next(.input), "Next input device", symbol: "mic")
            ForEach(devices(.output), id: \.uid) { item in
                row(.device(.output, item.uid), item.name, symbol: "speaker.wave.2", caption: "Output")
            }
            ForEach(devices(.input), id: \.uid) { item in
                row(.device(.input, item.uid), item.name, symbol: "mic", caption: "Input")
            }
        } header: {
            Text("Switch devices")
        } footer: {
            Text("“Next” skips Bluetooth mics you haven't allowed. Device shortcuts only work while that device is connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func devices(_ dir: Direction) -> [(uid: String, name: String)] {
        model.prefs.knownDevices
            .filter { $0.value.transport.isPhysical && (dir == .input ? $0.value.hasInput : $0.value.hasOutput) }
            .map { ($0.key, $0.value.name) }
            .sorted { $0.name < $1.name }
    }

    private func row(_ shortcut: DeviceShortcut, _ title: String, symbol: String, caption: String? = nil) -> some View {
        let key = shortcut.key
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 6) {
                    HotKeyRecorder(current: model.prefs.deviceShortcuts[key],
                                   onBegin: { model.suspendDeviceShortcuts(); model.hotKey.unregister(.mute) },
                                   onCancel: { model.applyHotKey(model.prefs.hotkey); model.applyDeviceShortcuts() },
                                   onRecord: { spec in
                                       model.applyHotKey(model.prefs.hotkey)
                                       model.setDeviceShortcut(key, spec)
                                   })
                    Button {
                        model.setDeviceShortcut(key, nil)
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .opacity(model.prefs.deviceShortcuts[key] == nil ? 0 : 1)
                        .help("Remove shortcut")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).lineLimit(1)
                        if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let error = model.deviceShortcutErrors[key] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Which apps trigger auto-mute: any app by default, or a chosen list.
private struct AutoMuteAppsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let apps = model.prefs.autoMuteApps
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(apps.isEmpty ? "Triggered by any app that starts using the mic" : "Triggered by:")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Add App") {
                    ForEach(candidates(), id: \.0) { id, name in
                        Button(name) { model.edit { $0.autoMuteApps.append(id) } }
                    }
                }
                .fixedSize()
            }
            ForEach(apps, id: \.self) { id in
                HStack {
                    Text(appName(id))
                    Spacer()
                    Button { model.edit { $0.autoMuteApps.removeAll { $0 == id } } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func candidates() -> [(String, String)] {
        let common = ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
                      "com.hnc.Discord", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"]
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        return Array(Set(common + running))
            .filter { !model.prefs.autoMuteApps.contains($0) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            .map { ($0, appName($0)) }
            .sorted { $0.1 < $1.1 }
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Profiles

private struct ProfilesPane: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""

    var body: some View {
        let profiles = model.prefs.profiles
        Form {
            if profiles.isEmpty {
                Section {
                    Text("Profiles save your device priorities and app rules for different places — Home, Office, Desk — and switch between them manually, from ⌘K, or automatically when you join a Wi-Fi network.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(profiles) { profile in
                ProfileRow(model: model, profile: profile)
            }
            Section {
                HStack {
                    TextField("New profile name", text: $newName, prompt: Text(profiles.isEmpty ? "e.g. Office" : "Name"))
                        .onSubmit(create)
                    Button("Save Current Setup as Profile", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(profiles.isEmpty ? "Your current setup is kept as “Default”." : "The new profile starts as a copy of the current one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.createProfile(named: name)
        newName = ""
    }
}

private struct ProfileRow: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    var body: some View {
        let active = model.prefs.activeProfileID == profile.id
        Section {
            TextField("Name", text: Binding(get: { profile.name },
                                            set: { v in model.editProfile(profile.id) { $0.name = v } }))
            LabeledContent("Wi-Fi network") {
                HStack {
                    Text(profile.wifiSSID ?? "None").foregroundStyle(profile.wifiSSID == nil ? .secondary : .primary)
                    Menu("Change") {
                        Button("Use Current Network") { useCurrentNetwork() }
                        if profile.wifiSSID != nil {
                            Button("None") { model.editProfile(profile.id) { $0.wifiSSID = nil }; model.onProfilesChanged() }
                        }
                    }
                    .fixedSize()
                }
            }
            LabeledContent("Devices", value: summary)
        } header: {
            HStack {
                Text(profile.name)
                if active { Text("Active").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !active {
                    Button("Switch") { model.switchProfile(profile.id) }.buttonStyle(.borderless)
                }
                Button(role: .destructive) { model.deleteProfile(profile.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(model.prefs.profiles.count == 1)
            }
        }
    }

    private var summary: String {
        let p = model.prefs.activeProfileID == profile.id ? (model.prefs.outputPriority, model.prefs.inputPriority)
                                                           : (profile.outputPriority, profile.inputPriority)
        let out = p.0.first.map(model.name) ?? "—"
        let inp = p.1.first.map(model.name) ?? "—"
        return "\(out) · \(inp)"
    }

    private func useCurrentNetwork() {
        model.requestWiFiName { ssid in
            guard let ssid else { return }
            model.editProfile(profile.id) { $0.wifiSSID = ssid }
            model.onProfilesChanged()
        }
    }
}

// MARK: - Output groups

private struct OutputGroupsSection: View {
    @ObservedObject var model: AppModel
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Multi-output groups").font(.headline)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Play through several outputs at once")
                    .popover(isPresented: $creating) { NewGroupForm(model: model) { creating = false } }
            }
            if model.prefs.outputGroups.isEmpty {
                Text("None. Click + to play through several outputs at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.prefs.outputGroups) { group in
                HStack {
                    Image(systemName: "hifispeaker.2").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.name)
                        Text(group.members.map(model.name).joined(separator: " + "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.deleteGroup(group.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            if !model.groupError.isEmpty {
                Text(model.groupError).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct NewGroupForm: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    @State private var name = "All Speakers"
    @State private var chosen: [String] = []

    var body: some View {
        let outputs = model.engine.state.connected.filter { $0.hasOutput && $0.transport.isPhysical }
        VStack(alignment: .leading, spacing: 10) {
            Text("New multi-output group").font(.headline)
            TextField("Name", text: $name)
            Text("Play through (the first one keeps time):").font(.caption).foregroundStyle(.secondary)
            ForEach(outputs, id: \.uid) { dev in
                Toggle(model.label(dev), isOn: Binding(
                    get: { chosen.contains(dev.uid) },
                    set: { on in if on { chosen.append(dev.uid) } else { chosen.removeAll { $0 == dev.uid } } }))
            }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Create") {
                    model.createGroup(name: name.trimmingCharacters(in: .whitespaces), members: chosen)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.count < 2 || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - App audio

private struct AppAudioPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            if !model.appAudioSupported {
                Section {
                    Text("Per-app audio needs macOS 14.2 or later.").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Toggle("Control output and volume per app", isOn: Binding(
                        get: { model.prefs.appAudioEnabled }, set: { model.setAppAudioEnabled($0) }))
                    if !model.prefs.appAudioEnabled {
                        Text("Off: AudioPilot leaves every app's audio alone and doesn't need System Audio Recording permission.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.appAudioSupported && model.prefs.appAudioEnabled {
                if model.audioCaptureDenied {
                    Section {
                        HStack {
                            Text("AudioPilot needs System Audio Recording permission to change an app's output or volume.")
                                .font(.callout).foregroundStyle(.orange)
                            Button("Open Settings") { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
                                .controlSize(.small)
                        }
                    }
                }
                let rows = entries
                if rows.isEmpty {
                    Section {
                        Text("Apps appear here once they play sound. Give one its own output or volume, e.g. music on the speakers while calls stay on the headset.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows, id: \.bundleID) { entry in
                    AppAudioRow(model: model, bundleID: entry.bundleID, name: entry.name)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Text("AudioPilot captures the app's sound (macOS may show a recording indicator) and plays it to the device you pick, at the volume you set. Settings apply whenever the app plays; reset an app to hand it back to macOS.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 12)
        }
    }

    /// Apps with a setting, then other apps that are playing.
    private var entries: [(bundleID: String, name: String)] {
        let configured = model.prefs.appAudio.map { ($0.bundleID, $0.appName) }
        let others = model.audioApps.filter { app in app.isPlaying && !configured.contains { $0.0 == app.bundleID } }
            .map { ($0.bundleID, $0.name) }
        return (configured + others).map { (bundleID: $0.0, name: $0.1) }
    }
}

private struct AppAudioRow: View {
    @ObservedObject var model: AppModel
    let bundleID: String
    let name: String

    var body: some View {
        let setting = model.appAudio(bundleID)
        let configured = model.prefs.appAudio.contains { $0.bundleID == bundleID }
        let app = AppAudioRouter.App(bundleID: bundleID, name: name, isPlaying: false)
        Section {
            Picker("Output", selection: Binding(get: { setting.outputUID },
                                                set: { model.setAppOutput(bundleID, name: name, $0) })) {
                Text("System output").tag(String?.none)
                ForEach(model.appAudioOutputs, id: \.uid) { Text(model.label($0)).tag(String?.some($0.uid)) }
                if let uid = setting.outputUID, !model.isConnected(uid) {
                    Text("\(model.name(uid)) (offline)").tag(String?.some(uid))
                }
            }
            LabeledContent("Volume") {
                HStack {
                    Button { model.setAppMuted(app, !setting.muted) } label: {
                        Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(setting.muted ? "Unmute" : "Mute")
                    Slider(value: Binding(get: { Double(setting.volume) }, set: { model.setAppVolume(app, Float($0)) }), in: 0...1)
                        .disabled(setting.muted)
                    Text("\(Int((setting.volume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            if let problem = model.appAudioProblems[bundleID] {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            HStack {
                AppIcon(bundleID: bundleID)
                Text(name)
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if configured {
                    Button("Reset") { model.resetAppAudio(bundleID) }
                        .buttonStyle(.borderless)
                        .help("Play through the system output at full volume again")
                }
            }
        }
    }

    private var status: String {
        guard let app = model.audioApps.first(where: { $0.bundleID == bundleID }) else { return "Not running" }
        return app.isPlaying ? "Playing" : "Idle"
    }
}

// MARK: - Backup

private struct BackupSection: View {
    @ObservedObject var model: AppModel
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        Section {
            HStack {
                Button("Export Settings…", action: exportSettings)
                Button("Import Settings…", action: importSettings)
                Spacer()
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Saves device priorities, app rules, profiles, per-app audio, shortcuts and appearance to a file you can import on another Mac. Devices this Mac knows are kept, and Launch at login stays as set on each Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AudioPilot Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportSettings(to: url)
            report("Exported to \(url.lastPathComponent).", failed: false)
        } catch {
            report("Couldn't export: \(error.localizedDescription)", failed: true)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Replace your AudioPilot settings?"
        alert.informativeText = "Your current settings are replaced by the ones in “\(url.lastPathComponent)”. Export them first if you might want them back."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.importSettings(from: url)
            report("Imported \(url.lastPathComponent).", failed: false)
        } catch let error as SettingsTransfer.ImportError {
            report(error.description, failed: true)
        } catch {
            report("Couldn't import: \(error.localizedDescription)", failed: true)
        }
    }

    private func report(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }
}
