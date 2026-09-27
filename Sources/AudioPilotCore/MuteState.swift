import Foundation

public struct MutedRecord: Equatable, Sendable, Codable {
    public enum Method: String, Codable, Sendable {
        case muteMain, muteChannels, volume
    }

    public var method: Method
    /// Element → volume scalar before muting (only for `.volume`).
    public var savedVolumes: [UInt32: Float32]

    public init(method: Method, savedVolumes: [UInt32: Float32] = [:]) {
        self.method = method
        self.savedVolumes = savedVolumes
    }
}

public struct MuteState: Equatable, Sendable, Codable {
    public var isMuted: Bool
    /// Devices AudioPilot muted, keyed by UID. Only these are touched on unmute.
    public var devices: [String: MutedRecord]

    public init(isMuted: Bool = false, devices: [String: MutedRecord] = [:]) {
        self.isMuted = isMuted
        self.devices = devices
    }
}
