import Foundation

public enum Reason: String, Sendable, Equatable {
    case rule, priority, fallback, none, override
}

/// Pure device-selection logic. Reads `EngineState`, never changes it.
public enum DevicePolicy {
    public static func device(_ uid: String, in state: EngineState) -> AudioDeviceInfo? {
        state.connected.first { $0.uid == uid }
    }

    /// Connected, eligible for `dir`, and not hidden by the user.
    public static func qualifies(_ uid: String, _ dir: Direction, in state: EngineState) -> Bool {
        guard state.prefs.deviceSettings[uid]?.hidden != true else { return false }
        return device(uid, in: state)?.qualifies(for: dir) ?? false
    }

    /// A mic the user has not explicitly allowed (Bluetooth/Continuity by default).
    public static func isBlockedMic(_ uid: String, in state: EngineState) -> Bool {
        if let known = state.prefs.knownDevices[uid] { return !known.allowAsMic }
        return device(uid, in: state)?.transport.blocksMicByDefault ?? false
    }

    /// The rule deciding `dir`: a `.usingMic` rule for an app on the mic (named app before "any app"), then
    /// a frontmost rule, else the `.running` rule of the most recently launched app.
    /// Only rules whose device is connected and qualifies count.
    public static func activeRule(_ dir: Direction, in state: EngineState) -> AppRule? {
        func usable(_ rule: AppRule) -> Bool {
            guard let uid = rule.device(for: dir) else { return false }
            return qualifies(uid, dir, in: state)
        }
        let rules = state.prefs.appRules
        let micApps = state.micApps
        if let rule = rules.first(where: { $0.trigger == .usingMic && micApps.contains($0.bundleID) && usable($0) })
            ?? rules.first(where: { $0.trigger == .usingMic && $0.bundleID == AppRule.anyApp && !micApps.isEmpty && usable($0) }) {
            return rule
        }
        if let front = state.frontmost,
           let rule = rules.first(where: { $0.trigger == .frontmost && $0.bundleID == front && usable($0) }) {
            return rule
        }
        for app in state.running.sorted(by: { $0.launchDate > $1.launchDate }) {
            if let rule = rules.first(where: { $0.trigger == .running && $0.bundleID == app.bundleID && usable($0) }) {
                return rule
            }
        }
        return nil
    }

    /// Rule → priority list → fallback. Blocked mics are skipped except when a rule names them.
    public static func target(_ dir: Direction, in state: EngineState) -> (uid: String?, reason: Reason) {
        if let rule = activeRule(dir, in: state), let uid = rule.device(for: dir) {
            return (uid, .rule)
        }
        func allowed(_ uid: String) -> Bool {
            qualifies(uid, dir, in: state) && !(dir == .input && isBlockedMic(uid, in: state))
        }
        if let uid = state.prefs.priority(dir).first(where: allowed) {
            return (uid, .priority)
        }
        let fallback = state.connected
            .filter { $0.transport.isPhysical && allowed($0.uid) }
            .sorted { ($0.transport.fallbackRank, $0.uid) < ($1.transport.fallbackRank, $1.uid) }
            .first
        if let fallback { return (fallback.uid, .fallback) }
        return (nil, .none)
    }
}
