import AppKit
import CoreSpotlight
import AudioPilotCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let flags: Flags
    private var hal: AudioHAL!
    private var engine: EngineController!
    private var mute: MuteController!
    private var appWatcher: AppWatcher!
    private let hotKey = GlobalHotKey()
    private var model: AppModel!
    private var statusMenu: StatusMenu?
    private var panel: PanelController?
    private var settings: SettingsWindow?
    private var about: AboutWindow?
    private var spotlight: SpotlightIndexer?
    private var micMonitor: MicUsageMonitor?
    private var wifi: WiFiProfileSwitcher?
    private let bluetooth = BluetoothMonitor()
    private let extraTrigger = ExtraTriggerTap()
    private let levelMonitor = MicLevelMonitor()
    private var lastSyncedMute: Bool?
    private let hud = HUD()
    private let overlay = MutedOverlay()
    private var tokens: [NSObjectProtocol] = []
    private var pendingURLs: [URL] = []
    private var launched = false

    init(flags: Flags) {
        self.flags = flags
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Dry-run never writes: prefs are read-only and first-run seeding stays in memory.
        let store = JSONStore(directory: JSONStore.prepareDirectory(readOnly: flags.dryRun), readOnly: flags.dryRun)
        let (prefs, existed) = store.load(Preferences.self, name: "preferences")

        hal = AudioHAL(dryRun: flags.dryRun)
        engine = EngineController(prefs: prefs ?? Preferences(), hal: hal, store: store, dryRun: flags.dryRun)
        mute = MuteController(store: store, dryRun: flags.dryRun)
        model = AppModel(engine: engine, mute: mute, hotKey: hotKey)
        IntentBridge.model = model

        hal.observeSystem { [weak self] in self?.audioChanged() }
        OutputGroups.ensure(prefs?.outputGroups ?? [], dryRun: flags.dryRun)
        engine.start(prefsExisted: existed)
        appWatcher = AppWatcher { [weak self] running, frontmost in
            self?.engine.send(.appsChanged(running: running, frontmost: frontmost))
        }
        appWatcher.start()
        mute.start(devices: engine.state.connected, pushToTalk: engine.prefs.hotkeyMode == .pushToTalk)
        observeSystemEvents()
        setUpDeviceEvents()

        if flags.dryRun {
            if let what = flags.showPanel { preview(what) }
            DispatchQueue.main.asyncAfter(deadline: .now() + flags.dryRunSeconds) { exit(0) }
            return
        }

        if engine.prefs.startMuted { mute.setMuted(true) }
        setUpUI()
        setUpHotKeys()
        launched = true
        pendingURLs.forEach(handle)
        pendingURLs = []
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mics stay muted on quit by design; the state file lets the next launch restore volumes.
        hal?.removeSystemObservers()
        mute?.removeListeners()
        hotKey.unregisterAll()
        extraTrigger.stop()
    }

    // MARK: - UI

    /// Dry-run UI preview: no hotkeys, no audio or file writes (the HAL and stores are in dry-run mode).
    private func preview(_ what: String) {
        setUpUI()
        panel?.pinned = true
        switch what {
        case "hud-muted": hud.showMute(true, detail: model.hudMicLine)
        case "hud-live": hud.showMute(false, detail: model.hudMicLine)
        case "hud-switch":
            if let dev = model.current(.output) { hud.showSwitch(symbol: model.icon(dev, .output), title: model.label(dev), subtitle: "Output") }
        case "palette": panel?.show(palette: true)
        case "about": showAbout(activate: false)
        case "panel": panel?.show(palette: false)
        default:
            if let pane = SettingsPane(rawValue: what) { model.settingsPane = pane }
            if what == "devices" { model.selectedDeviceUID = engine.state.current[.output] }
            showSettings(activate: false)
        }
    }

    private func setUpUI() {
        let panel = PanelController(model: model)
        self.panel = panel
        let menu = StatusMenu(model: model)
        statusMenu = menu
        panel.anchorProvider = { [weak menu] in menu?.buttonFrame }
        menu.togglePanel = { [weak panel] in panel?.toggle() }
        menu.openSettings = { [weak self] in self?.showSettings() }

        model.openSettings = { [weak self] in
            self?.panel?.close()
            self?.showSettings()
        }
        model.openAbout = { [weak self] in
            self?.panel?.close()
            self?.showAbout()
        }
        model.closePanel = { [weak self] in self?.panel?.close() }
        model.openPanel = { [weak self] palette in self?.panel?.show(palette: palette) }
        model.onDeviceFeedback = { [weak self] dir, dev in
            guard let self, !(self.panel?.isVisible ?? false) else { return }
            hud.showSwitch(symbol: model.icon(dev, dir), title: model.label(dev),
                           subtitle: dir == .output ? "Output" : "Input")
        }
        model.onMuteFeedback = { [weak self] in self?.feedback() }

        engine.onAutoSwitch = { [weak self] dir, uid in self?.announce(dir, uid) }
        setUpMicFeatures(panel)
        mute.observe { [weak self] in self?.updateOverlay() }
        engine.observe { [weak self] in self?.updateOverlay() }
        updateOverlay()

        model.onProfileSwitch = { [weak self] profile in
            self?.hud.showSwitch(symbol: "rectangle.stack", title: profile.name, subtitle: "Profile")
        }

        // Spotlight and Wi-Fi/Location are system-wide side effects, so never in dry-run previews.
        if !flags.dryRun {
            let switcher = WiFiProfileSwitcher(model: model)
            wifi = switcher
            model.onProfilesChanged = { [weak switcher] in switcher?.update() }
            model.requestWiFiName = { [weak switcher] completion in
                guard let switcher else { return completion(nil) }
                if let ssid = switcher.currentSSID { return completion(ssid) }
                // No name yet: ask for Location access, then try again shortly after.
                switcher.requestAccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { completion(switcher.currentSSID) }
            }
            switcher.update()

            let indexer = SpotlightIndexer(model: model)
            spotlight = indexer
            indexer.reindex()
            engine.observe { [weak indexer] in indexer?.scheduleReindex() }
        }
    }

    private func setUpHotKeys() {
        hotKey.setHandlers(.mute, press: { [weak self] in
            guard let self else { return }
            if engine.prefs.hotkeyMode == .pushToTalk { mute.setMuted(false) } else { mute.toggle() }
            feedback()
        }, release: { [weak self] in
            guard let self, engine.prefs.hotkeyMode == .pushToTalk else { return }
            mute.setMuted(true)
            feedback()
        })
        hotKey.setHandlers(.palette, press: { [weak self] in
            guard let panel = self?.panel else { return }
            if panel.isVisible && panel.ui.showPalette { panel.close() } else { panel.show(palette: true) }
        })
        model.applyHotKey(engine.prefs.hotkey)
        model.applyPaletteHotKey(engine.prefs.paletteHotkey)
        model.applyDeviceShortcuts()

        // Globe key / mouse button: push-to-talk follows press/release; toggle fires on a clean tap.
        extraTrigger.onPress = { [weak self] in
            guard let self, engine.prefs.hotkeyMode == .pushToTalk else { return }
            mute.setMuted(false)
            feedback()
        }
        extraTrigger.onRelease = { [weak self] wasTap in
            guard let self else { return }
            if engine.prefs.hotkeyMode == .pushToTalk {
                mute.setMuted(true)
                feedback()
            } else if wasTap {
                mute.toggle()
                feedback()
            }
        }
        model.applyExtraTrigger = { [weak self] trigger in
            guard let self else { return false }
            return extraTrigger.start(trigger)
        }
        model.extraTriggerActive = extraTrigger.start(engine.prefs.extraTrigger)
    }

    /// Level meter (only while the panel is open and the mic is live), AirPods stem, meeting sync.
    private func setUpMicFeatures(_ panel: PanelController) {
        levelMonitor.onLevel = { [weak self] level in self?.model.micLevel = level }
        panel.onVisibilityChange = { [weak self] _ in self?.updateLevelMeter() }
        model.applyMicFeatures = { [weak self] in
            guard let self else { return }
            updateLevelMeter()
            if engine.prefs.airPodsMute && !flags.dryRun {
                AirPodsMute.enable { [weak self] muted in
                    guard let self else { return }
                    mute.setMuted(muted)
                    feedback()
                }
                AirPodsMute.sync(mute.isMuted)
            } else {
                AirPodsMute.disable()
            }
        }
        mute.observe { [weak self] in
            guard let self else { return }
            let muted = mute.isMuted
            updateLevelMeter()
            guard muted != lastSyncedMute else { return }
            lastSyncedMute = muted
            if engine.prefs.airPodsMute { AirPodsMute.sync(muted) }
            if engine.prefs.meetingSync && !flags.dryRun {
                MeetingSync.apply(muted: muted, micUsers: model.micUsers.map(\.bundleID))
            }
        }
        lastSyncedMute = mute.isMuted
        model.applyMicFeatures()
    }

    private func updateLevelMeter() {
        let wanted = engine.prefs.levelMeter && !mute.isMuted && (panel?.isVisible ?? false) && !flags.dryRun
        if wanted && !levelMonitor.isRunning { levelMonitor.start() }
        if !wanted && levelMonitor.isRunning { levelMonitor.stop() }
    }

    private func feedback() {
        if engine.prefs.showHUD { hud.showMute(mute.isMuted, detail: model.hudMicLine) }
        if engine.prefs.playSound { NSSound(named: mute.isMuted ? "Bottle" : "Tink")?.play() }
    }

    private func announce(_ dir: Direction, _ uid: String) {
        guard engine.prefs.announceSwitches, !(panel?.isVisible ?? false),
              let dev = engine.state.connected.first(where: { $0.uid == uid }) else { return }
        hud.showSwitch(symbol: model.icon(dev, dir), title: model.label(dev),
                       subtitle: dir == .output ? "Output switched" : "Input switched")
    }

    private func updateOverlay() {
        overlay.update(visible: engine.prefs.showMutedOverlay && mute.isMuted)
    }

    private func showSettings(activate: Bool = true) {
        if settings == nil { settings = SettingsWindow(model: model) }
        settings?.show(activate: activate)
    }

    private func showAbout(activate: Bool = true) {
        if about == nil { about = AboutWindow(model: model) }
        about?.show(activate: activate)
    }

    // MARK: - System events

    private func audioChanged() {
        let devices = hal.devices()
        engine.halChanged(devices: devices)
        mute.devicesChanged(devices)
        micMonitor?.devicesChanged(devices)
        bluetooth.refresh()
    }

    /// Connect scripts, outside mute changes, and which apps use the mic (with auto-mute).
    private func setUpDeviceEvents() {
        engine.onDeviceConnection = { [weak self] dev, connected in
            guard let self else { return }
            ScriptRunner.run(for: dev, connected: connected, settings: engine.prefs.deviceSettings[dev.uid],
                             label: model.label(dev), dryRun: flags.dryRun)
        }
        mute.onExternalChange = { [weak self] dev, muted in
            guard let self, engine.prefs.notifyExternalMuteChanges, !(panel?.isVisible ?? false) else { return }
            hud.showSwitch(symbol: muted ? "mic.slash" : "mic",
                           title: muted ? "Mic muted outside AudioPilot" : "Mic unmuted outside AudioPilot",
                           subtitle: model.label(dev))
        }
        let monitor = MicUsageMonitor(hal: hal)
        micMonitor = monitor
        monitor.onChange = { [weak self] users, started in
            guard let self else { return }
            model.micUsers = users
            guard !flags.dryRun, engine.prefs.autoMuteOnCallStart, !mute.isMuted else { return }
            let apps = engine.prefs.autoMuteApps
            if let trigger = started.first(where: { apps.isEmpty || apps.contains($0.bundleID) }) {
                mute.setMuted(true)
                hud.showSwitch(symbol: "mic.slash.fill", title: "Muted",
                               subtitle: "\(trigger.name) started using the mic")
            }
        }
        monitor.start(devices: engine.state.connected)

        bluetooth.onChange = { [weak self] devices in self?.model.bluetooth = devices }
        model.refreshBluetooth = { [weak self] in self?.bluetooth.refresh() }
        model.setBluetoothConnected = { [weak self] device, connect in
            guard let self else { return }
            if flags.dryRun { print("DRYRUN bluetooth \(connect ? "connect" : "disconnect") \(device.name)"); return }
            bluetooth.setConnected(device, connect)
        }
        bluetooth.start()
    }

    private func observeSystemEvents() {
        let wake: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine.send(.wake)
                self.audioChanged()
                self.mute.wake()
            }
        }
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.prefs.muteOnLock, !self.flags.dryRun else { return }
                self.mute.setMuted(true)
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: wake))
        tokens.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: wake))
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: wake))
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock))
        tokens.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock))
    }

    // MARK: - Spotlight

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        if launched {
            runFromOutside(id)
        } else {
            var components = URLComponents(string: "audiopilot://run")
            components?.queryItems = [URLQueryItem(name: "id", value: id)]
            if let url = components?.url { pendingURLs.append(url) }
        }
        return true
    }

    private func runFromOutside(_ id: String) {
        if !model.perform(id) {
            hud.showSwitch(symbol: "exclamationmark.circle", title: "Not available right now",
                           subtitle: "Is the device connected?")
        }
    }

    // MARK: - URL scheme (Shortcuts, Raycast, scripts)

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { urls.forEach(handle) } else { pendingURLs += urls }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "audiopilot" else { return }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ($0.name.lowercased(), $0.value ?? "") } ?? [], uniquingKeysWith: { $1 })

        switch command {
        case "toggle", "toggle-mute": model.toggleMute(feedback: true)
        case "mute": model.setMuted(true, feedback: true)
        case "unmute": model.setMuted(false, feedback: true)
        case "input", "output":
            let dir: Direction = command == "input" ? .input : .output
            if let dev = findDevice(dir, uid: query["uid"], name: query["name"]) {
                model.pick(dir, dev.uid)
                hud.showSwitch(symbol: model.icon(dev, dir), title: model.label(dev),
                               subtitle: dir == .output ? "Output switched" : "Input switched")
            } else {
                hud.showSwitch(symbol: "questionmark.circle", title: "No matching device",
                               subtitle: query["name"] ?? query["uid"] ?? "")
            }
        case "auto":
            let value = query["on"]?.lowercased() ?? "toggle"
            let on = value == "toggle" ? !engine.prefs.autoSwitchEnabled : ["1", "true", "yes", "on"].contains(value)
            model.setAutoSwitch(on)
        case "theme":
            if let theme = PanelTheme(rawValue: query["name"]?.lowercased() ?? "") { model.setTheme(theme) }
        case "panel": panel?.show(palette: false)
        case "palette", "search":
            panel?.show(palette: true)
            if let q = query["q"] { panel?.ui.query = q }
        case "settings": showSettings()
        case "about": showAbout()
        case "next":
            let dir: Direction = query["dir"]?.lowercased().hasPrefix("in") == true ? .input : .output
            model.perform(.next(dir))
        case "run":
            if let id = query["id"] { runFromOutside(id) }
        default: break
        }
    }

    /// Exact UID, then exact name, then name containing the text (case-insensitive).
    private func findDevice(_ dir: Direction, uid: String?, name: String?) -> AudioDeviceInfo? {
        let devices = engine.state.connected.filter { $0.qualifies(for: dir) }
        if let uid, let dev = devices.first(where: { $0.uid == uid }) { return dev }
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        let labels = devices.map { (dev: $0, names: [$0.name.lowercased(), model.label($0).lowercased()]) }
        return labels.first { $0.names.contains(name) }?.dev ?? labels.first { $0.names.contains { $0.contains(name) } }?.dev
    }
}
