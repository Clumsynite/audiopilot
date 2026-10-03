import Foundation

/// One app's own output device and volume. Neutral settings (system output, full volume,
/// not muted) are removed rather than stored.
public struct AppAudioSetting: Equatable, Sendable, Codable, Identifiable {
    public var bundleID: String
    public var appName: String
    /// Output device UID; nil plays wherever the system output is.
    public var outputUID: String?
    /// Slider position 0…1.
    public var volume: Float
    public var muted: Bool

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, outputUID: String? = nil, volume: Float = 1, muted: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.outputUID = outputUID
        self.volume = volume
        self.muted = muted
    }

    public var isNeutral: Bool { outputUID == nil && volume >= 0.999 && !muted }

    /// Linear gain applied to the app's audio. Squaring the slider makes it feel even across its range.
    public var gain: Float { muted ? 0 : max(0, min(1, volume)) * max(0, min(1, volume)) }
}

/// Where an app's audio should go, given its setting and the connected devices.
public enum AppAudioPlan {
    public struct Route: Equatable, Sendable {
        public var outputUID: String
        public var gain: Float

        public init(outputUID: String, gain: Float) {
            self.outputUID = outputUID
            self.gain = gain
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Leave the app alone: nothing to change.
        case untouched
        case route(Route)
        /// Can't route (no output, or the output is an aggregate such as a multi-output group).
        case unsupported(String)
    }

    /// The chosen device if it's connected, else the system output. Aggregates (multi-output groups)
    /// can't hold a process tap's aggregate, so they aren't supported as targets.
    public static func outcome(for setting: AppAudioSetting, defaultOutput: String?,
                               connected: [AudioDeviceInfo]) -> Outcome {
        guard !setting.isNeutral else { return .untouched }
        func usable(_ uid: String) -> AudioDeviceInfo? {
            connected.first { $0.uid == uid && $0.qualifies(for: .output) }
        }
        let chosen = setting.outputUID.flatMap(usable)
        guard let target = chosen ?? defaultOutput.flatMap(usable) else { return .unsupported("No output device") }
        if target.transport == .aggregate {
            return .unsupported("Can't route to \(target.name)")
        }
        if target.uid == defaultOutput && setting.gain >= 0.999 { return .untouched }
        return .route(Route(outputUID: target.uid, gain: setting.gain))
    }
}

extension Array where Element == AppAudioSetting {
    /// Applies `body` to `bundleID`'s setting (creating it), dropping it again if it ends up neutral.
    public mutating func edit(_ bundleID: String, appName: String, _ body: (inout AppAudioSetting) -> Void) {
        var setting = first { $0.bundleID == bundleID } ?? AppAudioSetting(bundleID: bundleID, appName: appName)
        body(&setting)
        if let i = firstIndex(where: { $0.bundleID == bundleID }) {
            if setting.isNeutral { remove(at: i) } else { self[i] = setting }
        } else if !setting.isNeutral {
            append(setting)
        }
    }
}
