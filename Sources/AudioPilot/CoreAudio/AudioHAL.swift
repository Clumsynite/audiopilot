import CoreAudio
import Foundation
import AudioPilotCore

/// Thin CoreAudio wrapper. Devices are addressed by UID everywhere outside this file;
/// UIDs are translated to `AudioDeviceID`s on every call because IDs change across wake/reconnect.
final class AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    let dryRun: Bool
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var activityListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    // MARK: - Property helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(id, &a)
    }

    static func isSettable(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        guard AudioObjectHasProperty(id, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func bool(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        (get(id, addr, UInt32(0)) ?? 0) != 0
    }

    // MARK: - Devices

    static func deviceIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func transport(_ raw: UInt32) -> Transport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeAggregate: .aggregate
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypePCI: .pci
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeFireWire: .fireWire
        case kAudioDeviceTransportTypeBluetooth: .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: .bluetoothLE
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeAVB: .avb
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired: .continuityWired
        case kAudioDeviceTransportTypeContinuityCaptureWireless: .continuityWireless
        case kAudioDeviceTransportTypeRemoteScreen: .remoteScreen
        case kAudioDeviceTransportTypeRemoteStreaming: .remoteStreaming
        default: .unknown
        }
    }

    static func info(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? uid
        let inCh = channelCount(id, kAudioObjectPropertyScopeInput)
        let outCh = channelCount(id, kAudioObjectPropertyScopeOutput)
        return AudioDeviceInfo(
            uid: uid, name: name,
            transport: transport(get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0),
            inputChannels: inCh, outputChannels: outCh,
            canBeDefaultInput: inCh > 0 && bool(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput)),
            canBeDefaultOutput: outCh > 0 && bool(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput)),
            canBeDefaultSystem: outCh > 0 && bool(id, address(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput)),
            isAlive: has(id, address(kAudioDevicePropertyDeviceIsAlive)) ? bool(id, address(kAudioDevicePropertyDeviceIsAlive)) : true,
            isHidden: bool(id, address(kAudioDevicePropertyIsHidden))
        )
    }

    func devices() -> [AudioDeviceInfo] {
        Self.deviceIDs().compactMap(Self.info).sorted { $0.uid < $1.uid }
    }

    static func id(forUID uid: String) -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    // MARK: - Defaults

    static func selector(_ dir: Direction) -> AudioObjectPropertySelector {
        dir == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        guard let id = get(system, address(selector), AudioDeviceID(0)), id != kAudioObjectUnknown else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    func defaultUID(_ dir: Direction) -> String? {
        Self.defaultUID(Self.selector(dir))
    }

    func defaults() -> [Direction: String] {
        var d: [Direction: String] = [:]
        for dir in Direction.allCases { d[dir] = defaultUID(dir) }
        return d
    }

    /// Returns nil on success, or an error description.
    func setDefault(_ dir: Direction, uid: String) -> String? {
        setDefault(Self.selector(dir), uid: uid, label: "set \(dir.short)")
    }

    func setSystemOutput(uid: String) -> String? {
        setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, uid: uid, label: "set system-output")
    }

    private func setDefault(_ selector: AudioObjectPropertySelector, uid: String, label: String) -> String? {
        if dryRun {
            print("DRYRUN \(label) -> \(uid)")
            return nil
        }
        guard let id = Self.id(forUID: uid) else { return "device \(uid) not found" }
        let status = Self.set(Self.system, Self.address(selector), id)
        return status == noErr ? nil : "\(label) \(uid) failed: \(status)"
    }

    // MARK: - Listeners

    /// Calls `handler` on the main queue whenever the device list or a default device changes.
    func observeSystem(_ handler: @escaping @MainActor () -> Void) {
        let selectors = [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice]
        for selector in selectors {
            var addr = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { handler() }
            }
            if AudioObjectAddPropertyListenerBlock(Self.system, &addr, DispatchQueue.main, block) == noErr {
                systemListeners.append((addr, block))
            }
        }
    }

    func removeSystemObservers() {
        for (addr, block) in systemListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(Self.system, &a, DispatchQueue.main, block)
        }
        systemListeners = []
    }
}

// MARK: - Volume

extension AudioHAL {
    static func scope(_ dir: Direction) -> AudioObjectPropertyScope {
        dir == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    /// Main element if its volume is settable, else each settable channel.
    static func volumeElements(_ id: AudioDeviceID, _ dir: Direction) -> [UInt32] {
        let sc = scope(dir)
        if isSettable(id, address(kAudioDevicePropertyVolumeScalar, sc, kAudioObjectPropertyElementMain)) {
            return [kAudioObjectPropertyElementMain]
        }
        let n = channelCount(id, sc)
        guard n > 0 else { return [] }
        return (1...UInt32(n)).filter { isSettable(id, address(kAudioDevicePropertyVolumeScalar, sc, $0)) }
    }

    /// Average volume (0…1) of the device in that direction, or nil if it has no volume control.
    func volume(_ uid: String, _ dir: Direction) -> Float? {
        guard let id = Self.id(forUID: uid) else { return nil }
        let values = Self.volumeElements(id, dir).compactMap {
            Self.get(id, Self.address(kAudioDevicePropertyVolumeScalar, Self.scope(dir), $0), Float32(0))
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    func setVolume(_ uid: String, _ dir: Direction, _ value: Float) {
        guard !dryRun, let id = Self.id(forUID: uid) else { return }
        let v = Float32(min(max(value, 0), 1))
        for el in Self.volumeElements(id, dir) {
            Self.set(id, Self.address(kAudioDevicePropertyVolumeScalar, Self.scope(dir), el), v)
        }
    }
}
