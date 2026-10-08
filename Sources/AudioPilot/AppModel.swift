import AppKit
import Combine
import AudioPilotCore
import ServiceManagement

/// Shared state and actions for the panel, command palette, menu and Settings.
final class AppModel: ObservableObject {
    let engine: EngineController
    let mute: MuteController
    let hotKey: GlobalHotKey
    @Published var hotKeyError = ""
    @Published var paletteHotKeyError = ""
    @Published var loginError = ""
    @Published var deviceShortcutErrors: [String: String] = [:]
    var deviceSlots: [GlobalHotKey.Slot: String] = [:]
    @Published private(set) var revision = 0
    /// Settings navigation, so other UI can deep-link into a pane or device.
    @Published var settingsPane: SettingsPane? = SettingsWindow.initialPane
    @Published var selectedDeviceUID: String?
    /// Apps capturing the microphone right now.
    @Published var micUsers: [AudioHAL.MicUser] = []
    /// Paired Bluetooth audio devices with battery levels.
    @Published var bluetooth: [BluetoothMonitor.Device] = []
    var setBluetoothConnected: (BluetoothMonitor.Device, Bool) -> Void = { _, _ in }
    var refreshBluetooth: () -> Void = {}

    func battery(for dev: AudioDeviceInfo) -> String? {
        guard dev.transport == .bluetooth || dev.transport == .bluetoothLE else { return nil }
        return bluetooth.first { $0.matches(dev.uid) }?.battery
    }

    /// Paired Bluetooth audio devices that aren't connected (offered as "Connect" in the panel).
    var disconnectedBluetooth: [BluetoothMonitor.Device] { bluetooth.filter { !$0.connected } }

    /// Wired by the AppDelegate.
    var onMuteFeedback: () -> Void = {}
    var openSettings: () -> Void = {}
    var openAbout: () -> Void = {}
    var closePanel: () -> Void = {}
    var openPanel: (_ palette: Bool) -> Void = { _ in }
    /// Shown after a shortcut/Spotlight/URL device switch.
    var onDeviceFeedback: (Direction, AudioDeviceInfo) -> Void = { _, _ in }

    static let muteKeyBundleID = "com.davechengapps.GlobalMute"

    init(engine: EngineController, mute: MuteController, hotKey: GlobalHotKey) {
        self.engine = engine
        self.mute = mute
        self.hotKey = hotKey
        engine.observe { [weak self] in self?.revision += 1 }
        mute.observe { [weak self] in self?.revision += 1 }
    }

    var prefs: Preferences { engine.prefs }
    var theme: PanelTheme { PanelTheme.from(prefs.theme) }

    func refresh() { revision += 1 }

    func openDeviceSettings(_ uid: String) {
        settingsPane = .devices
        selectedDeviceUID = uid
        openSettings()
    }

    var isMuteKeyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.muteKeyBundleID }
    }

    // MARK: Actions

    func toggleMute(feedback: Bool = false) {
        mute.toggle()
        if feedback { onMuteFeedback() }
    }

    func setMuted(_ muted: Bool, feedback: Bool = false) {
        mute.setMuted(muted)
        if feedback { onMuteFeedback() }
    }

    func pick(_ dir: Direction, _ uid: String) {
        engine.send(.userPicked(dir, uid))
    }

    func setAutoSwitch(_ on: Bool) {
        engine.send(.setAutoSwitch(on))
    }

    func setTheme(_ theme: PanelTheme) {
        engine.editSettings { $0.theme = theme.rawValue }
    }

    func edit(_ body: (inout Preferences) -> Void) {
        engine.editSettings(body)
    }

    // MARK: Devices

    /// Connected devices that can be the default for `dir`, in priority order.
    func devices(_ dir: Direction) -> [AudioDeviceInfo] {
        let order = prefs.priority(dir)
        return engine.state.connected
            .filter { $0.qualifies(for: dir) }
            .sorted { (order.firstIndex(of: $0.uid) ?? .max, $0.name) < (order.firstIndex(of: $1.uid) ?? .max, $1.name) }
    }

    func current(_ dir: Direction) -> AudioDeviceInfo? {
        guard let uid = engine.state.current[dir] else { return nil }
        return engine.state.connected.first { $0.uid == uid }
    }

    func isBlocked(_ uid: String) -> Bool {
        DevicePolicy.isBlockedMic(uid, in: engine.state)
    }

    /// Why the current device for `dir` is selected, in words.
    func reason(_ dir: Direction) -> String {
        guard prefs.autoSwitchEnabled else { return "Auto-switch paused" }
        let state = engine.state
        if let rule = DevicePolicy.activeRule(dir, in: state), state.manualOverride[dir] == nil {
            return "Rule: \(rule.appName)"
        }
        if state.manualOverride[dir] != nil { return "Your choice" }
        let (uid, why) = engine.engine.target(dir)
        guard uid == state.current[dir] else { return "Switching…" }
        switch why {
        case .priority: return "Top priority"
        case .fallback: return "Fallback"
        case .rule: return "Rule"
        case .override: return "Your choice"
        case .none: return ""
        }
    }

    /// Short note shown only when something other than the priority list decided the device.
    func note(_ dir: Direction) -> String? {
        guard prefs.autoSwitchEnabled else { return "Auto-switch off" }
        let state = engine.state
        if state.manualOverride[dir] != nil { return "Your pick" }
        if let rule = DevicePolicy.activeRule(dir, in: state) {
            return rule.bundleID == AppRule.anyApp ? "Mic in use" : "For \(rule.appName)"
        }
        return nil
    }

    // MARK: Profiles

    /// Wired by the AppDelegate to the Wi-Fi switcher.
    var onProfilesChanged: () -> Void = {}
    var requestWiFiName: (@escaping (String?) -> Void) -> Void = { $0(nil) }

    /// Called after a profile switch that should be announced (e.g. from Wi-Fi).
    var onProfileSwitch: (Profile) -> Void = { _ in }

    func switchProfile(_ id: UUID, announce: Bool = false) {
        engine.send(.switchProfile(id))
        if announce, let profile = prefs.activeProfile, profile.id == id { onProfileSwitch(profile) }
    }

    func createProfile(named name: String) {
        edit { $0.createProfile(named: name) }
        refresh()
    }

    func editProfile(_ id: UUID, _ body: (inout Profile) -> Void) {
        edit { prefs in
            guard let i = prefs.profiles.firstIndex(where: { $0.id == id }) else { return }
            body(&prefs.profiles[i])
        }
    }

    func deleteProfile(_ id: UUID) {
        let wasActive = prefs.activeProfileID == id
        edit { $0.deleteProfile(id) }
        // Deleting the active profile loaded another one; re-run device selection for it.
        if wasActive { engine.send(.reorder(.output, prefs.outputPriority)) }
    }

    // MARK: Extra trigger (Globe key / mouse button)

    /// Wired by the AppDelegate; returns false when Input Monitoring permission is missing.
    var applyExtraTrigger: (ExtraTrigger) -> Bool = { _ in false }
    @Published var extraTriggerActive = false

    func setExtraTrigger(_ trigger: ExtraTrigger) {
        edit { $0.extraTrigger = trigger }
        extraTriggerActive = applyExtraTrigger(trigger)
    }

    // MARK: Output groups

    @Published var groupError = ""

    /// Creates a multi-output group and switches output to it.
    func createGroup(name: String, members: [String]) {
        let group = OutputGroup(name: name, members: members)
        guard OutputGroups.create(group, dryRun: engine.dryRun) else {
            groupError = "Couldn't create “\(name)”. Are all its devices connected?"
            return
        }
        groupError = ""
        edit { $0.outputGroups.append(group) }
        // The new device arrives via the HAL listener; pick it once it's there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, isConnected(group.deviceUID) else { return }
            pick(.output, group.deviceUID)
        }
    }

    func deleteGroup(_ id: UUID) {
        guard let group = prefs.outputGroups.first(where: { $0.id == id }) else { return }
        OutputGroups.destroy(group, dryRun: engine.dryRun)
        edit {
            $0.outputGroups.removeAll { $0.id == id }
            $0.outputPriority.removeAll { $0 == group.deviceUID }
            $0.knownDevices[group.deviceUID] = nil
        }
    }

    // MARK: Permission-gated mic features

    /// Live input level 0…1 while the meter runs.
    @Published var micLevel: Float = 0
    @Published var micPermissionDenied = false
    /// Wired by the AppDelegate: re-applies meter / AirPods / meeting-sync state after a change.
    var applyMicFeatures: () -> Void = {}

    /// Turns on a feature that needs microphone access, asking first.
    func setMicFeature(_ key: WritableKeyPath<Preferences, Bool>, _ on: Bool) {
        guard on else {
            edit { $0[keyPath: key] = false }
            applyMicFeatures()
            return
        }
        MicLevelMonitor.requestAccess { [weak self] granted in
            guard let self else { return }
            micPermissionDenied = !granted
            edit { $0[keyPath: key] = granted }
            applyMicFeatures()
        }
    }

    func setMeetingSync(_ on: Bool) {
        if on && !MeetingSync.trusted { MeetingSync.requestAccess() }
        edit { $0.meetingSync = on }
        applyMicFeatures()
    }

    // MARK: App audio (per-app output and volume)

    /// Apps with audio clients, refreshed by the router.
    @Published var audioApps: [AppAudioRouter.App] = []
    /// Why an app's setting isn't applied right now, by bundle ID.
    @Published var appAudioProblems: [String: String] = [:]
    @Published var audioCaptureDenied = false
    /// Wired by the AppDelegate: re-applies settings right away.
    var applyAppAudio: () -> Void = {}

    var appAudioSupported: Bool { AppAudioRouter.isSupported }

    func appAudio(_ bundleID: String) -> AppAudioSetting {
        prefs.appAudio.first { $0.bundleID == bundleID } ?? AppAudioSetting(bundleID: bundleID, appName: bundleID)
    }

    /// Apps for the panel: playing now, or running with a setting.
    var panelAudioApps: [AppAudioRouter.App] {
        audioApps.filter { app in app.isPlaying || prefs.appAudio.contains { $0.bundleID == app.bundleID } }
    }

    /// Output devices an app can be sent to (multi-output groups can't hold a tap).
    var appAudioOutputs: [AudioDeviceInfo] {
        devices(.output).filter { $0.transport != .aggregate }
    }

    func setAppAudioEnabled(_ on: Bool) {
        edit { $0.appAudioEnabled = on }
        if on { requestAudioCaptureIfNeeded() }
        applyAppAudio()
    }

    func setAppVolume(_ app: AppAudioRouter.App, _ volume: Float) {
        editAppAudio(app.bundleID, app.name, deferSave: true) { $0.volume = volume; $0.muted = false }
    }

    func setAppMuted(_ app: AppAudioRouter.App, _ muted: Bool) {
        editAppAudio(app.bundleID, app.name) { $0.muted = muted }
    }

    func setAppOutput(_ bundleID: String, name: String, _ uid: String?) {
        editAppAudio(bundleID, name) { $0.outputUID = uid }
    }

    func resetAppAudio(_ bundleID: String) {
        edit { $0.appAudio.removeAll { $0.bundleID == bundleID } }
        applyAppAudio()
    }

    private func editAppAudio(_ bundleID: String, _ name: String, deferSave: Bool = false,
                              _ body: (inout AppAudioSetting) -> Void) {
        let change: (inout Preferences) -> Void = { $0.appAudio.edit(bundleID, appName: name, body) }
        if deferSave { engine.editSettingsDeferred(change) } else { edit(change) }
        requestAudioCaptureIfNeeded()
        applyAppAudio()
    }

    /// The first rerouted app asks for System Audio Recording permission.
    private func requestAudioCaptureIfNeeded() {
        guard prefs.appAudioEnabled, !prefs.appAudio.isEmpty, AudioCapturePermission.status == .unknown,
              !requestedAudioCapture else { return }
        requestedAudioCapture = true
        AudioCapturePermission.request { [weak self] granted in
            self?.audioCaptureDenied = !granted
            self?.applyAppAudio()
        }
    }

    private var requestedAudioCapture = false

    // MARK: Settings backup

    /// Wired by the AppDelegate: re-registers shortcuts and re-applies features after an import.
    var onSettingsImported: () -> Void = {}

    func exportSettings(to url: URL) throws {
        engine.flushSave()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        try SettingsTransfer.export(prefs, appVersion: version, now: Date()).write(to: url, options: .atomic)
    }

    func importSettings(from url: URL) throws {
        let merged = try SettingsTransfer.importing(Data(contentsOf: url), into: prefs)
        engine.send(.importPreferences(merged))
        OutputGroups.ensure(merged.outputGroups, dryRun: engine.dryRun)
        onSettingsImported()
        refresh()
    }

    // MARK: Mute summary

    /// What's muted, in words: "All microphones muted", "OPPO Enco Buds3 Pro muted", or "Mic on: …".
    var muteHeadline: String {
        let inputs = MuteController.physicalInputs(engine.state.connected)
        let active = current(.input)
        guard mute.isMuted else {
            return active.map { "Mic on: \(label($0))" } ?? "Mic on"
        }
        let muted = inputs.filter { mute.state.devices[$0.uid] != nil || engine.dryRun }
        if !muted.isEmpty && muted.count == inputs.count {
            return inputs.count == 1 ? "\(label(inputs[0])) muted" : "All microphones muted"
        }
        if let active, muted.contains(where: { $0.uid == active.uid }) {
            return "\(label(active)) muted"
        }
        return muted.isEmpty ? "Muting failed" : "\(muted.count) of \(inputs.count) microphones muted"
    }

    /// Mic name for the mute pop-up: the active mic, plus "all mics" when several were muted.
    var hudMicLine: String {
        let inputs = MuteController.physicalInputs(engine.state.connected)
        let name = current(.input).map(label) ?? inputs.first.map(label) ?? "Microphone"
        guard mute.isMuted, inputs.count > 1 else { return name }
        let mutedCount = inputs.filter { mute.state.devices[$0.uid] != nil || engine.dryRun }.count
        guard mutedCount == inputs.count else { return "\(name) · \(mutedCount) of \(inputs.count) mics" }
        let others = inputs.count - 1
        return "\(name) + \(others) other mic\(others == 1 ? "" : "s")"
    }

    /// One line per microphone: its state, and which one apps are using by default.
    var muteDetailLines: [String] {
        let activeUID = current(.input)?.uid
        return MuteController.physicalInputs(engine.state.connected).map { dev in
            let state: String
            if mute.unmutable[dev.uid] != nil { state = "can't be muted" }
            else if mute.isMuted { state = mute.state.devices[dev.uid] != nil || engine.dryRun ? "muted" : "not muted" }
            else { state = "on" }
            return "\(label(dev))\(dev.uid == activeUID ? " (active)" : ""): \(state)"
        }
    }

    // MARK: Device customization

    /// Name to show: the user's custom name, else the device's own.
    func label(_ dev: AudioDeviceInfo) -> String {
        prefs.deviceSettings[dev.uid]?.customName ?? dev.name
    }

    func icon(_ dev: AudioDeviceInfo, _ dir: Direction) -> String {
        prefs.deviceSettings[dev.uid]?.icon ?? DeviceIcon.name(dev, dir)
    }

    func deviceSettings(_ uid: String) -> DeviceSettings {
        prefs.deviceSettings[uid] ?? DeviceSettings()
    }

    /// Edits one device's settings; empty settings are removed. Re-evaluates when hiding changes.
    func editDevice(_ uid: String, _ body: (inout DeviceSettings) -> Void) {
        var settings = deviceSettings(uid)
        let wasHidden = settings.hidden
        body(&settings)
        if let name = settings.customName?.trimmingCharacters(in: .whitespaces), name.isEmpty { settings.customName = nil }
        edit { $0.deviceSettings[uid] = settings.isEmpty ? nil : settings }
        if wasHidden != settings.hidden { engine.send(.reorder(.output, prefs.outputPriority)) }
    }

    func volume(_ dir: Direction) -> Float? {
        current(dir).flatMap { engine.hal.volume($0.uid, dir) }
    }

    func setVolume(_ dir: Direction, _ value: Float) {
        guard let dev = current(dir) else { return }
        engine.hal.setVolume(dev.uid, dir, value)
    }

    func name(_ uid: String) -> String { engine.name(uid) }

    func isConnected(_ uid: String) -> Bool {
        engine.state.connected.contains { $0.uid == uid }
    }

    // MARK: Hotkeys

    func applyHotKey(_ spec: HotKeySpec) {
        let status = hotKey.register(spec, slot: .mute)
        hotKeyError = KeyNames.describe(status)
        if status == noErr { engine.editSettings { $0.hotkey = spec } }
        revision += 1
    }

    func applyPaletteHotKey(_ spec: HotKeySpec) {
        guard spec != prefs.hotkey else {
            paletteHotKeyError = "That's already the mute shortcut."
            return
        }
        let status = hotKey.register(spec, slot: .palette)
        paletteHotKeyError = KeyNames.describe(status)
        if status == noErr { engine.editSettings { $0.paletteHotkey = spec } }
        revision += 1
    }

    func setHotKeyMode(_ mode: HotKeyMode) {
        engine.editSettings { $0.hotkeyMode = mode }
        if mode == .pushToTalk { mute.setMuted(true) }
        revision += 1
    }

    // MARK: Launch at login

    var canUseLoginItem: Bool {
        let path = Bundle.main.bundleURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Bundle.main.bundleIdentifier != nil
            && (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"))
    }

    var loginItemStatus: SMAppService.Status { SMAppService.mainApp.status }

    func setLaunchAtLogin(_ on: Bool) {
        guard canUseLoginItem else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = error.localizedDescription
        }
        engine.editSettings { $0.launchAtLogin = on }
        revision += 1
    }
}
