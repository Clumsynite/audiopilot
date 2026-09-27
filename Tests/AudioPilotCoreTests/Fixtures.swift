import Foundation
@testable import AudioPilotCore

enum F {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func dev(_ uid: String, _ name: String, _ transport: Transport, input: Int = 0, output: Int = 0,
                    system: Bool = true) -> AudioDeviceInfo {
        AudioDeviceInfo(uid: uid, name: name, transport: transport,
                        inputChannels: input, outputChannels: output,
                        canBeDefaultInput: input > 0, canBeDefaultOutput: output > 0,
                        canBeDefaultSystem: output > 0 && system)
    }

    static let builtInMic = dev("BuiltInMicrophoneDevice", "MacBook Pro Microphone", .builtIn, input: 1)
    static let builtInSpeakers = dev("BuiltInSpeakerDevice", "MacBook Pro Speakers", .builtIn, output: 2)
    static let usbHeadset = dev("AppleUSBAudioEngine:Jabra:1", "Jabra Evolve", .usb, input: 1, output: 2)
    static let btSplitIn = dev("64-8F:input", "OPPO Enco Buds3 Pro", .bluetooth, input: 1)
    static let btSplitOut = dev("64-8F:output", "OPPO Enco Buds3 Pro", .bluetooth, output: 2)
    static let btCombo = dev("AA-BB-CC", "AirPods Pro", .bluetooth, input: 1, output: 2)
    static let zoomVirtual = dev("zoom.us.ZoomAudioDevice", "ZoomAudioDevice", .virtual, input: 2, output: 2)
    static let aggregate = dev("CADefaultDeviceAggregate-1", "Aggregate", .aggregate, input: 2, output: 2)
    static let hdmiMonitor = dev("HDMI-DELL", "DELL U2723QE", .hdmi, output: 2)
    static let continuityMic = dev("iPhone-mic", "iPhone Microphone", .continuityWireless, input: 1)

    static let base = [builtInMic, builtInSpeakers]

    /// Engine that has already started with existing prefs (not first run), at `t0`.
    static func started(devices: [AudioDeviceInfo] = base,
                        input: [String] = [builtInMic.uid], output: [String] = [builtInSpeakers.uid],
                        known extra: [AudioDeviceInfo] = [],
                        defaults: [Direction: String]? = nil,
                        configure: (inout Preferences) -> Void = { _ in }) -> Engine {
        var prefs = Preferences()
        prefs.inputPriority = input
        prefs.outputPriority = output
        for d in devices + extra {
            prefs.knownDevices[d.uid] = KnownDevice(d, allowAsMic: !d.transport.blocksMicByDefault, now: t0)
        }
        configure(&prefs)
        var engine = Engine(prefs: prefs)
        let defs = defaults ?? [.input: input.first ?? builtInMic.uid, .output: output.first ?? builtInSpeakers.uid]
        _ = engine.reduce(.start(devices: devices, defaults: defs, prefsExisted: true), now: t0)
        return engine
    }
}

extension Array where Element == EngineAction {
    var sets: [EngineAction] {
        filter { if case .setDefault = $0 { true } else { false } }
    }

    func sets(_ dir: Direction) -> [String] {
        compactMap { if case let .setDefault(d, uid) = $0, d == dir { uid } else { nil } }
    }

    var saves: Bool { contains(.savePrefs) }

    func hasLog(_ prefix: String) -> Bool {
        contains { if case let .log(m) = $0 { m.hasPrefix(prefix) } else { false } }
    }
}
