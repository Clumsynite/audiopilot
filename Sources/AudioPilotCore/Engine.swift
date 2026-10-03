import Foundation

public struct PendingSet: Equatable, Sendable {
    public var uid: String
    public var deadline: Date
}

public struct LearnCandidate: Equatable, Sendable {
    public var uid: String
    public var at: Date
}

public struct EngineState: Equatable, Sendable {
    public var prefs: Preferences
    public var connected: [AudioDeviceInfo] = []
    public var current: [Direction: String] = [:]
    /// Last device-list change, wake, or start.
    public var lastTopologyEvent: Date?
    /// Last change of the default output, including AudioPilot's own.
    public var lastOutputChange: Date?
    public var pending: [Direction: PendingSet] = [:]
    public var enforceCount: [Direction: Int] = [:]
    public var lastRevert: [Direction: Date] = [:]
    public var learnCandidate: [Direction: LearnCandidate] = [:]
    public var manualOverride: [Direction: String] = [:]
    public var running: [RunningApp] = []
    public var frontmost: String?
    /// Bundle IDs of apps capturing the microphone right now.
    public var micUsers: [String] = []
    /// Apps that just stopped using the mic, kept until the deadline so a device switch
    /// (which briefly stops capture) can't flip a mic rule off and on again.
    public var micLinger: [String: Date] = [:]

    /// Apps that count as using the mic for `.usingMic` rules.
    public var micApps: Set<String> { Set(micUsers).union(micLinger.keys) }

    public init(prefs: Preferences = Preferences()) {
        self.prefs = prefs
    }
}

public enum EngineEvent: Equatable, Sendable {
    case start(devices: [AudioDeviceInfo], defaults: [Direction: String], prefsExisted: Bool)
    case devicesChanged([AudioDeviceInfo])
    case defaultChanged(Direction, String?)
    case userPicked(Direction, String)
    case appsChanged(running: [RunningApp], frontmost: String?)
    case micUsersChanged([String])
    case wake
    case tick
    case setAllowAsMic(String, Bool)
    case reorder(Direction, [String])
    case forget(String)
    case setAutoSwitch(Bool)
    case updateRules([AppRule])
    case switchProfile(UUID)
    /// Replaces the settings with an imported file's (see `SettingsTransfer`).
    case importPreferences(Preferences)
}

public enum EngineAction: Equatable, Sendable {
    case setDefault(Direction, String)
    case setSystemOutput(String)
    case savePrefs
    case log(String)
    case scheduleRetryBurst
    case scheduleTick(after: TimeInterval)
}

/// Pure reducer: every decision about which device to use, when to revert, and what to learn.
/// `now` is always passed in; the engine never reads the clock or starts timers.
public struct Engine: Sendable {
    public static let topologyWindow: TimeInterval = 5
    public static let pendingLifetime: TimeInterval = 1.5
    public static let enforceCap = 5
    public static let learnDelay: TimeInterval = 5
    public static let learnTickDelay: TimeInterval = 5.1
    public static let micReleaseDelay: TimeInterval = 4

    public private(set) var state: EngineState

    public init(prefs: Preferences = Preferences()) {
        state = EngineState(prefs: prefs)
    }

    public init(state: EngineState) {
        self.state = state
    }

    private var paused: Bool { !state.prefs.autoSwitchEnabled }

    /// Called when a HAL setter failed, so a stale pending record can't swallow a later real change.
    public mutating func clearPending(_ dir: Direction) {
        state.pending[dir] = nil
    }

    /// Edits settings that don't affect device selection (hotkey, HUD, sound, login item).
    public mutating func editSettings(_ body: (inout Preferences) -> Void) -> [EngineAction] {
        body(&state.prefs)
        return [.savePrefs]
    }

    // MARK: - Reduce

    public mutating func reduce(_ event: EngineEvent, now: Date) -> [EngineAction] {
        var out: [EngineAction] = []
        switch event {
        case let .start(devices, defaults, prefsExisted):
            state.connected = devices
            state.current = defaults
            state.lastTopologyEvent = now
            if prefsExisted {
                if registerDevices(now: now) { out.append(.savePrefs) }
            } else {
                seed(now: now)
                out.append(.savePrefs)
            }
            out.append(.scheduleRetryBurst)
            evaluate(now: now, into: &out)

        case let .devicesChanged(devices):
            state.connected = devices
            if registerDevices(now: now) { out.append(.savePrefs) }
            state.learnCandidate = [:]
            state.manualOverride = [:]
            state.lastTopologyEvent = now
            state.enforceCount = [:]
            out.append(.scheduleRetryBurst)
            evaluate(now: now, into: &out)

        case let .defaultChanged(dir, uid):
            defaultChanged(dir, uid, now: now, into: &out)

        case let .userPicked(dir, uid):
            userPicked(dir, uid, now: now, into: &out)

        case let .appsChanged(running, frontmost):
            changeRuleContext {
                $0.running = running
                $0.frontmost = frontmost
            }
            evaluate(now: now, into: &out)

        case let .micUsersChanged(users):
            changeRuleContext { state in
                for gone in state.micUsers where !users.contains(gone) {
                    state.micLinger[gone] = now.addingTimeInterval(Self.micReleaseDelay)
                }
                users.forEach { state.micLinger[$0] = nil }
                state.micUsers = users
            }
            if !state.micLinger.isEmpty { out.append(.scheduleTick(after: Self.micReleaseDelay + 0.1)) }
            evaluate(now: now, into: &out)

        case .wake:
            state.learnCandidate = [:]
            state.manualOverride = [:]
            state.lastTopologyEvent = now
            state.enforceCount = [:]
            out.append(.scheduleRetryBurst)
            evaluate(now: now, into: &out)

        case .tick:
            changeRuleContext { $0.micLinger = $0.micLinger.filter { $0.value > now } }
            for (dir, candidate) in state.learnCandidate
            where now.timeIntervalSince(candidate.at) >= Self.learnDelay
                && (state.lastTopologyEvent.map { $0 < candidate.at } ?? true) {
                state.prefs.moveToTop(candidate.uid, dir)
                state.learnCandidate[dir] = nil
                state.manualOverride[dir] = nil
                out.append(.log("learned \(dir.short) \(candidate.uid)"))
                out.append(.savePrefs)
            }
            evaluate(now: now, into: &out)

        case let .setAllowAsMic(uid, allow):
            state.prefs.knownDevices[uid]?.allowAsMic = allow
            out.append(.savePrefs)
            evaluate(now: now, into: &out)

        case let .reorder(dir, list):
            state.prefs.setPriority(dir, list)
            out.append(.savePrefs)
            evaluate(now: now, into: &out)

        case let .updateRules(rules):
            state.prefs.appRules = rules
            out.append(.savePrefs)
            evaluate(now: now, into: &out)

        case let .forget(uid):
            guard DevicePolicy.device(uid, in: state) == nil else { break }
            state.prefs.inputPriority.removeAll { $0 == uid }
            state.prefs.outputPriority.removeAll { $0 == uid }
            state.prefs.knownDevices[uid] = nil
            out.append(.savePrefs)

        case let .switchProfile(id):
            guard state.prefs.activeProfileID != id, state.prefs.activateProfile(id) else { break }
            state.manualOverride = [:]
            state.learnCandidate = [:]
            // New devices seen since the profile was last used still go to the top.
            _ = registerDevices(now: now)
            out.append(.log("profile \(state.prefs.activeProfile?.name ?? "?")"))
            out.append(.savePrefs)
            evaluate(now: now, into: &out)

        case let .importPreferences(prefs):
            let local = state.prefs.knownDevices
            state.prefs = prefs
            // Connected devices aren't "new" just because the file never saw them.
            for dev in state.connected where state.prefs.knownDevices[dev.uid] == nil {
                state.prefs.knownDevices[dev.uid] = local[dev.uid]
                    ?? KnownDevice(dev, allowAsMic: !dev.transport.blocksMicByDefault, now: now)
            }
            state.manualOverride = [:]
            state.learnCandidate = [:]
            // Devices this Mac knows but the imported lists don't mention go after the imported order.
            for dir in Direction.allCases {
                let extra = state.connected
                    .filter { $0.transport.isPhysical && $0.qualifies(for: dir) && !state.prefs.priority(dir).contains($0.uid) }
                    .map(\.uid)
                state.prefs.setPriority(dir, state.prefs.priority(dir) + extra)
            }
            _ = registerDevices(now: now)
            out.append(.log("imported settings"))
            out.append(.savePrefs)
            evaluate(now: now, into: &out)

        case let .setAutoSwitch(enabled):
            state.prefs.autoSwitchEnabled = enabled
            out.append(.savePrefs)
            if enabled { evaluate(now: now, into: &out) }
        }
        return out
    }

    /// Applies a change to running apps or mic users; a manual pick made under one rule
    /// doesn't carry over once a different rule (or none) is in charge.
    private mutating func changeRuleContext(_ body: (inout EngineState) -> Void) {
        let before = Direction.allCases.map { DevicePolicy.activeRule($0, in: state)?.id }
        body(&state)
        for (i, dir) in Direction.allCases.enumerated()
        where DevicePolicy.activeRule(dir, in: state)?.id != before[i] {
            state.manualOverride[dir] = nil
        }
    }

    // MARK: - Targets

    /// Effective target: a live manual override wins, otherwise the policy.
    public func target(_ dir: Direction) -> (uid: String?, reason: Reason) {
        if let uid = state.manualOverride[dir], DevicePolicy.qualifies(uid, dir, in: state) {
            return (uid, .override)
        }
        return DevicePolicy.target(dir, in: state)
    }

    private mutating func apply(_ dir: Direction, _ uid: String, now: Date, into out: inout [EngineAction]) {
        out.append(.setDefault(dir, uid))
        state.pending[dir] = PendingSet(uid: uid, deadline: now.addingTimeInterval(Self.pendingLifetime))
        if dir == .output, state.prefs.systemSoundFollowsOutput,
           DevicePolicy.device(uid, in: state)?.canBeDefaultSystem == true {
            out.append(.setSystemOutput(uid))
        }
    }

    private mutating func evaluate(now: Date, into out: inout [EngineAction]) {
        guard !paused else { return }
        for dir in Direction.allCases {
            let (uid, reason) = target(dir)
            let current = state.current[dir]
            out.append(.log("decision dir=\(dir.short) current=\(current ?? "nil") target=\(uid ?? "nil") reason=\(reason.rawValue)"))
            if let uid, uid != current {
                apply(dir, uid, now: now, into: &out)
            }
        }
    }

    private mutating func revert(_ dir: Direction, now: Date, into out: inout [EngineAction]) {
        if let last = state.lastRevert[dir], now.timeIntervalSince(last) >= Self.topologyWindow {
            state.enforceCount[dir] = 0
        }
        let count = state.enforceCount[dir] ?? 0
        guard count < Self.enforceCap else {
            out.append(.log("gave up enforcing \(dir.short)"))
            state.manualOverride[dir] = state.current[dir]
            return
        }
        guard let uid = target(dir).uid, uid != state.current[dir] else { return }
        apply(dir, uid, now: now, into: &out)
        state.enforceCount[dir] = count + 1
        state.lastRevert[dir] = now
        out.append(.log("reverted \(dir.short) to \(uid)"))
    }

    // MARK: - Default changes

    private mutating func defaultChanged(_ dir: Direction, _ uid: String?, now: Date, into out: inout [EngineAction]) {
        // 1
        if let uid { state.current[dir] = uid } else { state.current[dir] = nil }
        if dir == .output { state.lastOutputChange = now }
        // 2
        if let pending = state.pending[dir] {
            if pending.deadline < now {
                state.pending[dir] = nil
            } else if pending.uid == uid {
                state.pending[dir] = nil
                return
            }
        }
        // 3
        guard !paused, let uid else { return }
        // 4
        if target(dir).uid == uid {
            state.learnCandidate[dir] = nil
            return
        }
        // 5: the hijack fix
        if dir == .input, DevicePolicy.isBlockedMic(uid, in: state),
           DevicePolicy.activeRule(.input, in: state)?.inputUID != uid,
           state.manualOverride[.input] != uid {
            revert(dir, now: now, into: &out)
            return
        }
        // 6: macOS reacting to a connect/disconnect/wake
        if let t = state.lastTopologyEvent, now.timeIntervalSince(t) < Self.topologyWindow {
            revert(dir, now: now, into: &out)
            return
        }
        // 7: macOS often moves input right after an output change; accept, don't learn
        if dir == .input, let t = state.lastOutputChange, now.timeIntervalSince(t) < Self.topologyWindow {
            state.manualOverride[.input] = uid
            return
        }
        // 8: user override during an app rule
        if DevicePolicy.activeRule(dir, in: state) != nil {
            state.manualOverride[dir] = uid
            return
        }
        // 9: calm change: learn once it survives the learn delay
        state.learnCandidate[dir] = LearnCandidate(uid: uid, at: now)
        state.manualOverride[dir] = uid
        out.append(.scheduleTick(after: Self.learnTickDelay))
    }

    private mutating func userPicked(_ dir: Direction, _ uid: String, now: Date, into out: inout [EngineAction]) {
        apply(dir, uid, now: now, into: &out)
        if dir == .input, DevicePolicy.isBlockedMic(uid, in: state) {
            if state.prefs.knownDevices[uid] != nil {
                state.prefs.knownDevices[uid]?.allowAsMic = true
            } else if let dev = DevicePolicy.device(uid, in: state) {
                state.prefs.knownDevices[uid] = KnownDevice(dev, allowAsMic: true, now: now)
            }
        }
        if !paused, DevicePolicy.activeRule(dir, in: state) != nil {
            state.manualOverride[dir] = uid
        } else {
            state.prefs.moveToTop(uid, dir)
            state.manualOverride[dir] = nil
            state.learnCandidate[dir] = nil
        }
        out.append(.log("picked \(dir.short) \(uid)"))
        out.append(.savePrefs)
    }

    // MARK: - Device registry

    /// First run: seed both lists from the current defaults and connected physical devices.
    private mutating func seed(now: Date) {
        for dev in state.connected {
            state.prefs.knownDevices[dev.uid] = KnownDevice(dev, allowAsMic: !dev.transport.blocksMicByDefault, now: now)
        }
        for dir in Direction.allCases {
            var list: [String] = []
            if let cur = state.current[dir], let dev = DevicePolicy.device(cur, in: state),
               dev.transport.isPhysical, dev.qualifies(for: dir),
               !(dir == .input && DevicePolicy.isBlockedMic(cur, in: state)) {
                list.append(cur)
            }
            let others = state.connected
                .filter { $0.transport.isPhysical && $0.qualifies(for: dir) && !list.contains($0.uid) }
                .sorted { (blockedRank($0, dir), $0.transport.seedRank, $0.uid) < (blockedRank($1, dir), $1.transport.seedRank, $1.uid) }
            list += others.map(\.uid)
            state.prefs.setPriority(dir, list)
        }
    }

    private func blockedRank(_ dev: AudioDeviceInfo, _ dir: Direction) -> Int {
        dir == .input && DevicePolicy.isBlockedMic(dev.uid, in: state) ? 1 : 0
    }

    /// Name fallback for changed UIDs, then new devices go to the top of their lists.
    /// Returns whether the prefs changed.
    private mutating func registerDevices(now: Date) -> Bool {
        let before = state.prefs
        let connectedUIDs = Set(state.connected.map(\.uid))
        for dev in state.connected where state.prefs.knownDevices[dev.uid] == nil {
            let matches = state.prefs.knownDevices.filter { uid, known in
                !connectedUIDs.contains(uid) && known.name == dev.name && known.transport == dev.transport
                    && known.hasInput == dev.hasInput && known.hasOutput == dev.hasOutput
            }
            if matches.count == 1, let (oldUID, record) = matches.first {
                migrate(from: oldUID, to: dev.uid, record: record)
                continue
            }
            state.prefs.knownDevices[dev.uid] = KnownDevice(dev, allowAsMic: !dev.transport.blocksMicByDefault, now: now)
            guard dev.transport.isPhysical else { continue }
            for dir in Direction.allCases where dev.qualifies(for: dir) {
                state.prefs.moveToTop(dev.uid, dir)
            }
        }
        for dev in state.connected {
            state.prefs.knownDevices[dev.uid]?.lastSeen = now
            state.prefs.knownDevices[dev.uid]?.name = dev.name
        }
        return state.prefs != before
    }

    private mutating func migrate(from old: String, to new: String, record: KnownDevice) {
        state.prefs.knownDevices[old] = nil
        state.prefs.knownDevices[new] = record
        state.prefs.inputPriority = state.prefs.inputPriority.map { $0 == old ? new : $0 }
        state.prefs.outputPriority = state.prefs.outputPriority.map { $0 == old ? new : $0 }
        state.prefs.appRules = state.prefs.appRules.map { rule in
            var r = rule
            if r.inputUID == old { r.inputUID = new }
            if r.outputUID == old { r.outputUID = new }
            return r
        }
        state.prefs.appAudio = state.prefs.appAudio.map { setting in
            var s = setting
            if s.outputUID == old { s.outputUID = new }
            return s
        }
    }
}

extension KnownDevice {
    init(_ dev: AudioDeviceInfo, allowAsMic: Bool, now: Date) {
        self.init(name: dev.name, transport: dev.transport, hasInput: dev.hasInput, hasOutput: dev.hasOutput,
                  allowAsMic: allowAsMic, lastSeen: now)
    }
}
