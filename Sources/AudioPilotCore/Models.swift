import Foundation

public enum Direction: String, Codable, Sendable, CaseIterable {
    case input, output

    public var short: String { self == .input ? "in" : "out" }
}

/// Mirrors `kAudioDeviceTransportType*` from CoreAudio, without depending on it.
public enum Transport: String, Codable, Sendable, CaseIterable {
    case builtIn, aggregate, virtual, pci, usb, fireWire, bluetooth, bluetoothLE
    case hdmi, displayPort, airPlay, avb, thunderbolt
    case continuityWired, continuityWireless, remoteScreen, remoteStreaming, unknown

    /// Devices you physically connect. Only these are auto-inserted into priority lists,
    /// used for first-run seeding, or picked as a fallback.
    public var isPhysical: Bool {
        switch self {
        case .virtual, .aggregate, .airPlay, .unknown, .remoteScreen, .remoteStreaming: false
        default: true
        }
    }

    /// Bluetooth and Continuity mics degrade audio quality (or hijack the iPhone), so they are opt-in.
    public var blocksMicByDefault: Bool {
        switch self {
        case .bluetooth, .bluetoothLE, .continuityWired, .continuityWireless: true
        default: false
        }
    }

    /// Order used when seeding priority lists on first run.
    var seedRank: Int {
        switch self {
        case .usb, .thunderbolt, .pci, .fireWire, .avb: 0
        case .builtIn: 1
        case .hdmi, .displayPort: 2
        case .bluetooth, .bluetoothLE: 3
        default: 4
        }
    }

    /// Order used when nothing in the priority list is connected.
    var fallbackRank: Int {
        switch self {
        case .builtIn: 0
        case .usb, .thunderbolt, .pci, .fireWire: 1
        default: 2
        }
    }
}

public struct AudioDeviceInfo: Equatable, Sendable, Codable {
    public var uid: String
    public var name: String
    public var transport: Transport
    public var inputChannels: Int
    public var outputChannels: Int
    public var canBeDefaultInput: Bool
    public var canBeDefaultOutput: Bool
    public var canBeDefaultSystem: Bool
    public var isAlive: Bool
    public var isHidden: Bool

    public init(uid: String, name: String, transport: Transport,
                inputChannels: Int, outputChannels: Int,
                canBeDefaultInput: Bool, canBeDefaultOutput: Bool, canBeDefaultSystem: Bool,
                isAlive: Bool = true, isHidden: Bool = false) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.canBeDefaultInput = canBeDefaultInput
        self.canBeDefaultOutput = canBeDefaultOutput
        self.canBeDefaultSystem = canBeDefaultSystem
        self.isAlive = isAlive
        self.isHidden = isHidden
    }

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    /// Whether the device may become the default device for `dir`.
    public func qualifies(for dir: Direction) -> Bool {
        guard isAlive, !isHidden else { return false }
        switch dir {
        case .input: return canBeDefaultInput && inputChannels > 0
        case .output: return canBeDefaultOutput && outputChannels > 0
        }
    }
}

public struct RunningApp: Equatable, Sendable {
    public var bundleID: String
    public var launchDate: Date

    public init(bundleID: String, launchDate: Date) {
        self.bundleID = bundleID
        self.launchDate = launchDate
    }
}
