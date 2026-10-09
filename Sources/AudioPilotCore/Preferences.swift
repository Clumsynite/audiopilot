import Foundation

public struct KnownDevice: Equatable, Sendable, Codable {
    public var name: String
    public var transport: Transport
    public var hasInput: Bool
    public var hasOutput: Bool
    public var allowAsMic: Bool
    public var lastSeen: Date

    public init(name: String, transport: Transport, hasInput: Bool, hasOutput: Bool, allowAsMic: Bool, lastSeen: Date) {
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.allowAsMic = allowAsMic
        self.lastSeen = lastSeen
    }
}

public struct DeviceSettings: Equatable, Sendable, Codable {
    /// Display name shown instead of the device's own name.
    public var customName: String?
    /// SF Symbol name shown instead of the automatic icon.
    public var icon: String?
    /// Hidden devices are left out of menus and never selected automatically.
    public var hidden: Bool = false
    /// Shell commands run when the device connects / disconnects.
    public var onConnect: String?
    public var onDisconnect: String?

    public init(customName: String? = nil, icon: String? = nil, hidden: Bool = false,
                onConnect: String? = nil, onDisconnect: String? = nil) {
        self.customName = customName
        self.icon = icon
        self.hidden = hidden
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    public var isEmpty: Bool {
        customName == nil && icon == nil && !hidden && onConnect == nil && onDisconnect == nil
    }
}

/// A single key or mouse button that mutes, following the toggle / push-to-talk mode.
public enum ExtraTrigger: String, Codable, Sendable, CaseIterable {
    case none, globe, middleMouse, mouseBack, mouseForward

    public var title: String {
        switch self {
        case .none: "None"
        case .globe: "Globe (fn) key"
        case .middleMouse: "Middle mouse button"
        case .mouseBack: "Mouse button 4 (back)"
        case .mouseForward: "Mouse button 5 (forward)"
        }
    }

    /// CGEvent mouse button number, for mouse triggers.
    public var mouseButton: Int64? {
        switch self {
        case .middleMouse: 2
        case .mouseBack: 3
        case .mouseForward: 4
        default: nil
        }
    }
}

/// A multi-output device: audio plays through every member at once.
public struct OutputGroup: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Member output UIDs; the first is the clock (main) device.
    public var members: [String]

    public init(id: UUID = UUID(), name: String, members: [String]) {
        self.id = id
        self.name = name
        self.members = members
    }

    /// UID of the aggregate device CoreAudio publishes for this group.
    public var deviceUID: String { "com.techenable.audiopilot.group.\(id.uuidString)" }
}

/// A named set of device priorities and app rules (e.g. Home, Office), optionally tied to a Wi-Fi network.
public struct Profile: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var inputPriority: [String]
    public var outputPriority: [String]
    public var appRules: [AppRule]
    /// Switch to this profile automatically when joining this Wi-Fi network.
    public var wifiSSID: String?

    public init(id: UUID = UUID(), name: String, inputPriority: [String] = [], outputPriority: [String] = [],
                appRules: [AppRule] = [], wifiSSID: String? = nil) {
        self.id = id
        self.name = name
        self.inputPriority = inputPriority
        self.outputPriority = outputPriority
        self.appRules = appRules
        self.wifiSSID = wifiSSID
    }
}

extension Preferences {
    public var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// Copies the live priorities and rules into the active profile.
    public mutating func storeActiveProfile() {
        guard let i = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles[i].inputPriority = inputPriority
        profiles[i].outputPriority = outputPriority
        profiles[i].appRules = appRules
    }

    /// Saves the live setup as a new profile and makes it active. The first profile created also
    /// keeps the previous setup as "Default" so nothing is lost.
    @discardableResult
    public mutating func createProfile(named name: String) -> UUID {
        if profiles.isEmpty {
            let base = Profile(name: "Default", inputPriority: inputPriority, outputPriority: outputPriority, appRules: appRules)
            profiles.append(base)
            activeProfileID = base.id
        }
        storeActiveProfile()
        let profile = Profile(name: name, inputPriority: inputPriority, outputPriority: outputPriority, appRules: appRules)
        profiles.append(profile)
        activeProfileID = profile.id
        return profile.id
    }

    /// Stores the current profile, then loads `id`'s priorities and rules. False if `id` is unknown.
    @discardableResult
    public mutating func activateProfile(_ id: UUID) -> Bool {
        guard let target = profiles.first(where: { $0.id == id }) else { return false }
        storeActiveProfile()
        inputPriority = target.inputPriority
        outputPriority = target.outputPriority
        appRules = target.appRules
        activeProfileID = id
        return true
    }

    /// Removes a profile. The last remaining profile can't be removed while it's active.
    public mutating func deleteProfile(_ id: UUID) {
        guard profiles.count > 1 || activeProfileID != id else { return }
        if activeProfileID == id, let other = profiles.first(where: { $0.id != id }) {
            activateProfile(other.id)
        }
        profiles.removeAll { $0.id == id }
    }
}

public struct AppRule: Equatable, Sendable, Codable, Identifiable {
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        /// While the app is open, while it's in front, or while it's capturing the microphone.
        case running, frontmost, usingMic
    }

    /// `bundleID` of a `.usingMic` rule that matches whichever app starts using the mic.
    public static let anyApp = "*"

    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var inputUID: String?
    public var outputUID: String?
    public var trigger: Trigger

    public init(id: UUID = UUID(), bundleID: String, appName: String,
                inputUID: String? = nil, outputUID: String? = nil, trigger: Trigger = .running) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.inputUID = inputUID
        self.outputUID = outputUID
        self.trigger = trigger
    }

    public func device(for dir: Direction) -> String? {
        dir == .input ? inputUID : outputUID
    }
}

public struct HotKeySpec: Equatable, Sendable, Codable {
    /// Carbon virtual key code (kVK_*).
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘⇧M: kVK_ANSI_M = 46, cmdKey|shiftKey = 256|512 (same as Mic Drop's default).
    public static let `default` = HotKeySpec(keyCode: 46, modifiers: 256 | 512)

    /// The pre-v2 default (⌃⌥⌘M); settings still on it move to the new default.
    public static let legacyDefault = HotKeySpec(keyCode: 46, modifiers: 4096 | 2048 | 256)

    /// ⌃⌥⌘K (kVK_ANSI_K = 40) opens the command palette.
    public static let palette = HotKeySpec(keyCode: 40, modifiers: 4096 | 2048 | 256)
    /// ⌃⌥⌘O (kVK_ANSI_O = 31): next output device.
    public static let nextOutput = HotKeySpec(keyCode: 31, modifiers: 4096 | 2048 | 256)
    /// ⌃⌥⌘I (kVK_ANSI_I = 34): next input device.
    public static let nextInput = HotKeySpec(keyCode: 34, modifiers: 4096 | 2048 | 256)
}

public enum HotKeyMode: String, Codable, Sendable, CaseIterable {
    case toggle, pushToTalk
}

public struct Preferences: Equatable, Sendable, Codable {
    public var version: Int = 2
    public var inputPriority: [String] = []
    public var outputPriority: [String] = []
    public var knownDevices: [String: KnownDevice] = [:]
    public var appRules: [AppRule] = []
    public var hotkey: HotKeySpec = .default
    public var hotkeyMode: HotKeyMode = .toggle
    public var autoSwitchEnabled: Bool = true
    public var systemSoundFollowsOutput: Bool = true
    public var showHUD: Bool = true
    public var playSound: Bool = false
    /// System sound names (from /System/Library/Sounds) played on mute and unmute.
    public var muteSound: String = "Bottle"
    public var unmuteSound: String = "Tink"
    public var launchAtLogin: Bool = false
    /// Look for a newer release on the download site every few hours.
    public var autoCheckUpdates: Bool = true
    /// Download what the check finds and install it when nothing would be interrupted, or at quit.
    public var autoInstallUpdates: Bool = true
    public var paletteHotkey: HotKeySpec = .palette
    /// Raw value of the app's panel theme.
    public var theme: String = "glass"
    public var startMuted: Bool = false
    public var muteOnLock: Bool = false
    public var showMutedOverlay: Bool = false
    public var announceSwitches: Bool = true
    /// Device-switching shortcuts, keyed by `DeviceShortcut.key`. Removing a key disables it.
    public var deviceShortcuts: [String: HotKeySpec] = [
        DeviceShortcut.next(.output).key: .nextOutput,
        DeviceShortcut.next(.input).key: .nextInput,
    ]
    /// Index actions and devices in Spotlight.
    public var spotlightEnabled: Bool = true
    /// Custom name/icon, hidden flag and connect scripts per device UID.
    public var deviceSettings: [String: DeviceSettings] = [:]
    /// Show a notice when another app mutes or unmutes the mic.
    public var notifyExternalMuteChanges: Bool = true
    /// Mute automatically when an app starts using the mic.
    public var autoMuteOnCallStart: Bool = false
    /// Bundle IDs that trigger auto-mute; empty means any app.
    public var autoMuteApps: [String] = []
    /// Saved sets of priorities and rules. The live lists above belong to `activeProfileID`.
    public var profiles: [Profile] = []
    public var activeProfileID: UUID?
    /// Multi-output devices AudioPilot creates (play to several outputs at once).
    public var outputGroups: [OutputGroup] = []
    /// Extra mute trigger that isn't a normal shortcut (needs Input Monitoring).
    public var extraTrigger: ExtraTrigger = .none
    /// Live input level in the panel (needs microphone permission; only runs while the panel is open).
    public var levelMeter: Bool = false
    /// Press the AirPods stem to mute (experimental; needs microphone permission).
    public var airPodsMute: Bool = false
    /// Keep meeting apps' own mute buttons in sync (needs Accessibility permission).
    public var meetingSync: Bool = false
    /// Live input level in the menu bar icon while an app is using the mic (needs microphone permission).
    public var menuBarLevel: Bool = false
    /// Per-app output device and volume (needs System Audio Recording permission). Off leaves every
    /// app alone and never asks for the permission; `appAudio` is kept for turning it back on.
    public var appAudioEnabled: Bool = false
    public var appAudio: [AppAudioSetting] = []

    public init() {}

    public func priority(_ dir: Direction) -> [String] {
        dir == .input ? inputPriority : outputPriority
    }

    public mutating func setPriority(_ dir: Direction, _ list: [String]) {
        if dir == .input { inputPriority = list } else { outputPriority = list }
    }

    /// Moves (or inserts) `uid` to the top of the `dir` list.
    public mutating func moveToTop(_ uid: String, _ dir: Direction) {
        var list = priority(dir)
        list.removeAll { $0 == uid }
        list.insert(uid, at: 0)
        setPriority(dir, list)
    }

    enum CodingKeys: String, CodingKey {
        case version, inputPriority, outputPriority, knownDevices, appRules, hotkey, hotkeyMode
        case autoSwitchEnabled, systemSoundFollowsOutput, showHUD, playSound, muteSound, unmuteSound, launchAtLogin, autoCheckUpdates, autoInstallUpdates
        case paletteHotkey, theme, startMuted, muteOnLock, showMutedOverlay, announceSwitches
        case deviceShortcuts, spotlightEnabled, deviceSettings, notifyExternalMuteChanges, autoMuteOnCallStart, autoMuteApps
        case profiles, activeProfileID, outputGroups, extraTrigger, levelMeter, airPodsMute, meetingSync
        case menuBarLevel, appAudioEnabled, appAudio
    }

    // Tolerates missing keys so older or hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        inputPriority = try c.decodeIfPresent([String].self, forKey: .inputPriority) ?? d.inputPriority
        outputPriority = try c.decodeIfPresent([String].self, forKey: .outputPriority) ?? d.outputPriority
        knownDevices = try c.decodeIfPresent([String: KnownDevice].self, forKey: .knownDevices) ?? d.knownDevices
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? d.appRules
        hotkey = try c.decodeIfPresent(HotKeySpec.self, forKey: .hotkey) ?? d.hotkey
        hotkeyMode = try c.decodeIfPresent(HotKeyMode.self, forKey: .hotkeyMode) ?? d.hotkeyMode
        autoSwitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchEnabled) ?? d.autoSwitchEnabled
        systemSoundFollowsOutput = try c.decodeIfPresent(Bool.self, forKey: .systemSoundFollowsOutput) ?? d.systemSoundFollowsOutput
        showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? d.showHUD
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? d.playSound
        muteSound = try c.decodeIfPresent(String.self, forKey: .muteSound) ?? d.muteSound
        unmuteSound = try c.decodeIfPresent(String.self, forKey: .unmuteSound) ?? d.unmuteSound
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? d.autoCheckUpdates
        autoInstallUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? d.autoInstallUpdates
        // v1 → v2: the default mute shortcut changed from ⌃⌥⌘M to ⌘⇧M.
        if version < 2 {
            if hotkey == .legacyDefault { hotkey = .default }
            version = 2
        }
        paletteHotkey = try c.decodeIfPresent(HotKeySpec.self, forKey: .paletteHotkey) ?? d.paletteHotkey
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        startMuted = try c.decodeIfPresent(Bool.self, forKey: .startMuted) ?? d.startMuted
        muteOnLock = try c.decodeIfPresent(Bool.self, forKey: .muteOnLock) ?? d.muteOnLock
        showMutedOverlay = try c.decodeIfPresent(Bool.self, forKey: .showMutedOverlay) ?? d.showMutedOverlay
        announceSwitches = try c.decodeIfPresent(Bool.self, forKey: .announceSwitches) ?? d.announceSwitches
        deviceShortcuts = try c.decodeIfPresent([String: HotKeySpec].self, forKey: .deviceShortcuts) ?? d.deviceShortcuts
        spotlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .spotlightEnabled) ?? d.spotlightEnabled
        deviceSettings = try c.decodeIfPresent([String: DeviceSettings].self, forKey: .deviceSettings) ?? d.deviceSettings
        notifyExternalMuteChanges = try c.decodeIfPresent(Bool.self, forKey: .notifyExternalMuteChanges) ?? d.notifyExternalMuteChanges
        autoMuteOnCallStart = try c.decodeIfPresent(Bool.self, forKey: .autoMuteOnCallStart) ?? d.autoMuteOnCallStart
        autoMuteApps = try c.decodeIfPresent([String].self, forKey: .autoMuteApps) ?? d.autoMuteApps
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? d.profiles
        activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID) ?? d.activeProfileID
        outputGroups = try c.decodeIfPresent([OutputGroup].self, forKey: .outputGroups) ?? d.outputGroups
        extraTrigger = try c.decodeIfPresent(ExtraTrigger.self, forKey: .extraTrigger) ?? d.extraTrigger
        levelMeter = try c.decodeIfPresent(Bool.self, forKey: .levelMeter) ?? d.levelMeter
        airPodsMute = try c.decodeIfPresent(Bool.self, forKey: .airPodsMute) ?? d.airPodsMute
        meetingSync = try c.decodeIfPresent(Bool.self, forKey: .meetingSync) ?? d.meetingSync
        menuBarLevel = try c.decodeIfPresent(Bool.self, forKey: .menuBarLevel) ?? d.menuBarLevel
        appAudio = try c.decodeIfPresent([AppAudioSetting].self, forKey: .appAudio) ?? d.appAudio
        // Files from before the switch existed stay on if they already use per-app audio.
        appAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .appAudioEnabled) ?? !appAudio.isEmpty
    }
}

/// A shortcut target: cycle to the next device, or switch to one specific device.
public enum DeviceShortcut: Hashable, Sendable {
    case next(Direction)
    case device(Direction, String)

    public var key: String {
        switch self {
        case let .next(dir): "next:\(dir.rawValue)"
        case let .device(dir, uid): "\(dir.rawValue):\(uid)"
        }
    }

    public init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "next", let dir = Direction(rawValue: parts[1]) {
            self = .next(dir)
        } else if let dir = Direction(rawValue: parts[0]) {
            self = .device(dir, parts[1])
        } else {
            return nil
        }
    }
}

public enum DeviceCycle {
    /// The device after `current` in `ordered`, wrapping around; skips anything `skip` rejects.
    public static func next(after current: String?, in ordered: [String], skip: (String) -> Bool = { _ in false }) -> String? {
        let candidates = ordered.filter { !skip($0) || $0 == current }
        guard !candidates.isEmpty else { return nil }
        guard let current, let i = candidates.firstIndex(of: current) else { return candidates.first { !skip($0) } }
        for step in 1...candidates.count {
            let uid = candidates[(i + step) % candidates.count]
            if !skip(uid) { return uid == current ? nil : uid }
        }
        return nil
    }
}
