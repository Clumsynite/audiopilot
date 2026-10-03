import AudioToolbox
import CoreAudio
import Foundation
import os

/// One app's audio, rerouted: a process tap mutes the app's own output and captures it, and a
/// private aggregate device (the target output plus the tap) plays it back at an adjustable gain.
/// Private taps and aggregates belong to this process, so if AudioPilot quits or crashes they
/// vanish and the app plays normally again.
///
/// Not tied to the main actor: CoreAudio calls are thread-safe and the render block runs on the
/// HAL's real-time thread.
nonisolated final class TapSession {
    static let uidPrefix = "com.techenable.audiopilot.tap."

    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case call(String, OSStatus)
        case format(String)

        var description: String {
            switch self {
            case .unavailable: "Needs macOS 14.2 or later"
            case let .call(what, status): "Couldn't \(what) (\(status))"
            case let .format(what): what
            }
        }
    }

    let processes: [AudioObjectID]
    let outputUID: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Read by the render block on every cycle; a single aligned Float, so plain loads and stores are safe.
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Highest output sample since the last `takePeak()`, written by the render block.
    private let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private static let logger = Logger(subsystem: "com.techenable.audiopilot", category: "taps")

    init(processes: [AudioObjectID], outputUID: String, name: String, gain initial: Float) throws {
        self.processes = processes
        self.outputUID = outputUID
        gain.initialize(to: initial)
        peak.initialize(to: 0)
        guard #available(macOS 14.2, *) else { throw Failure.unavailable }
        do {
            try start(name: name)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        gain.deallocate()
        peak.deallocate()
    }

    /// Loudest sample played since the last call (0…1), e.g. to check audio is flowing.
    func takePeak() -> Float {
        defer { peak.pointee = 0 }
        return peak.pointee
    }

    /// False once CoreAudio has torn the playback device down (e.g. across sleep).
    var isAlive: Bool {
        guard aggregateID != kAudioObjectUnknown else { return false }
        return (Self.get(aggregateID, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) ?? 0) != 0
    }

    func setGain(_ value: Float) {
        gain.pointee = value
    }

    /// Stops playback and destroys the aggregate and the tap (the app's own output comes back).
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Setup

    @available(macOS 14.2, *)
    private func start(name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the audio tap")
        tapID = tap

        guard let format = Self.get(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              Self.isFloat32(format), format.mChannelsPerFrame > 0 else {
            throw Failure.format("The app's audio format isn't supported")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the playback device")
        aggregateID = device

        // The IO proc gets buffers in each stream's virtual format, which must be Float32 for the mixer below.
        let outputFormats = Self.streamFormats(device, kAudioObjectPropertyScopeOutput)
        guard !outputFormats.isEmpty, outputFormats.allSatisfy(Self.isFloat32) else {
            throw Failure.format("The output device's format isn't supported")
        }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapChannels = Int(format.mChannelsPerFrame)
        let tapBuffers = nonInterleaved ? tapChannels : 1
        // Input streams are the output device's own (e.g. a headset mic) followed by the tap's.
        let inputStreams = Self.streamFormats(device, kAudioObjectPropertyScopeInput).count
        let deviceInputStreams = Self.streamCount(uid: outputUID, kAudioObjectPropertyScopeInput)
        guard inputStreams == deviceInputStreams + tapBuffers else {
            throw Failure.format("Unexpected stream layout (\(inputStreams) inputs)")
        }
        Self.logger.info("tap \(name, privacy: .public): \(tapChannels) ch, \(nonInterleaved ? "planar" : "interleaved"), \(deviceInputStreams) device inputs")

        let block = Self.renderBlock(gain: gain, peak: peak, tapChannels: tapChannels, nonInterleaved: nonInterleaved)
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, block), "set up playback")
        procID = proc
        try check(AudioDeviceStart(device, proc), "start playback")
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Failure.call(what, status) }
    }

    // MARK: Rendering (real-time thread: no allocation, locks or Swift runtime calls)

    /// Copies the tap's stereo mix to the output's first two channels (or folds it to mono),
    /// silences any other channels, and applies the gain.
    private static func renderBlock(gain: UnsafeMutablePointer<Float>, peak: UnsafeMutablePointer<Float>,
                                    tapChannels: Int, nonInterleaved: Bool) -> AudioDeviceIOBlock {
        let tapBuffers = nonInterleaved ? tapChannels : 1
        return { _, inputData, _, outputData, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            let g = gain.pointee

            // Left and right source channels as (pointer, stride); mono sources use the same channel twice.
            var left: UnsafePointer<Float>?
            var right: UnsafePointer<Float>?
            var stride = 1
            var sourceFrames = 0
            if input.count >= tapBuffers {
                let first = input.count - tapBuffers
                if nonInterleaved {
                    left = input[first].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
                    right = tapChannels > 1 ? input[first + 1].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } : left
                    sourceFrames = Int(input[first].mDataByteSize) / MemoryLayout<Float>.size
                } else {
                    let base = input[first].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
                    left = base
                    right = tapChannels > 1 ? base.map { $0 + 1 } : base
                    stride = tapChannels
                    sourceFrames = Int(input[first].mDataByteSize) / (MemoryLayout<Float>.size * tapChannels)
                }
            }

            var totalChannels = 0
            for buffer in output { totalChannels += Int(buffer.mNumberChannels) }
            var channel = 0
            var loudest: Float = 0
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    channel += channels
                    continue
                }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                for c in 0..<channels {
                    let out = channel + c
                    let source: UnsafePointer<Float>? = totalChannels == 1 ? nil : (out == 0 ? left : out == 1 ? right : nil)
                    for f in 0..<frames {
                        var v: Float = 0
                        if f < sourceFrames {
                            if totalChannels == 1, let l = left, let r = right {
                                v = (l[f * stride] + r[f * stride]) * 0.5
                            } else if let source {
                                v = source[f * stride]
                            }
                        }
                        let sample = v * g
                        data[f * channels + c] = sample
                        if abs(sample) > loudest { loudest = abs(sample) }
                    }
                }
                channel += channels
            }
            if loudest > peak.pointee { peak.pointee = loudest }
        }
    }

    // MARK: Property helpers

    private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    private static func isFloat32(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
    }

    /// Virtual formats of a device's streams in one direction, in stream order.
    private static func streamFormats(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamBasicDescription] {
        streams(device, scope).compactMap { get($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) }
    }

    private static func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Number of streams a device (by UID) has in one direction.
    private static func streamCount(uid: String, _ scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return 0 }
        return streams(device, scope).count
    }
}

/// "System Audio Recording" permission, which process taps need. macOS has no public check, so this
/// asks TCC directly when it can; `.unknown` means macOS will prompt when the first tap starts.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var status: Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet.
    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else { return done(true) }
        unsafeBitCast(symbol, to: Request.self)(service, nil, completion(done))
    }

    /// Built outside the main actor: TCC calls back on its own queue.
    private nonisolated static func completion(_ done: @escaping @MainActor (Bool) -> Void) -> @convention(block) (Bool) -> Void {
        { granted in Task { @MainActor in done(granted) } }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
