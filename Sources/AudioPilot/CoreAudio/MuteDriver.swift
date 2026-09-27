import CoreAudio
import Foundation
import AudioPilotCore

/// Mutes a single input device: mute property on the main element, then per-channel mute,
/// then input volume 0. Every write is read back, because some drivers accept writes they ignore.
enum MuteDriver {
    typealias HAL = AudioHAL

    static func muteAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        HAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, element)
    }

    static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
    }

    static func channelElements(_ id: AudioDeviceID) -> [UInt32] {
        let n = HAL.channelCount(id, kAudioObjectPropertyScopeInput)
        return n > 0 ? Array(1...UInt32(n)) : []
    }

    /// Elements a method acts on.
    static func elements(_ method: MutedRecord.Method, _ id: AudioDeviceID) -> [UInt32] {
        switch method {
        case .muteMain: return [kAudioObjectPropertyElementMain]
        case .muteChannels: return channelElements(id).filter { HAL.isSettable(id, muteAddress($0)) }
        case .volume:
            if HAL.isSettable(id, volumeAddress(kAudioObjectPropertyElementMain)) { return [kAudioObjectPropertyElementMain] }
            return channelElements(id).filter { HAL.isSettable(id, volumeAddress($0)) }
        }
    }

    /// Best available method from settable checks alone (no writes). Nil = can't be muted.
    static func method(for id: AudioDeviceID) -> MutedRecord.Method? {
        if HAL.isSettable(id, muteAddress(kAudioObjectPropertyElementMain)) { return .muteMain }
        if !elements(.muteChannels, id).isEmpty { return .muteChannels }
        if !elements(.volume, id).isEmpty { return .volume }
        return nil
    }

    static func readMute(_ id: AudioDeviceID) -> Bool? {
        for el in [kAudioObjectPropertyElementMain] + channelElements(id) where HAL.has(id, muteAddress(el)) {
            if let v = HAL.get(id, muteAddress(el), UInt32(0)) { return v != 0 }
        }
        return nil
    }

    static func readVolume(_ id: AudioDeviceID) -> Float32? {
        for el in [kAudioObjectPropertyElementMain] + channelElements(id) where HAL.has(id, volumeAddress(el)) {
            if let v = HAL.get(id, volumeAddress(el), Float32(0)) { return v }
        }
        return nil
    }

    /// Whether the device is currently silenced the way `record` says it should be.
    static func isHeld(_ id: AudioDeviceID, _ record: MutedRecord) -> Bool {
        let els = elements(record.method, id)
        guard !els.isEmpty else { return false }
        switch record.method {
        case .muteMain, .muteChannels:
            return els.allSatisfy { (HAL.get(id, muteAddress($0), UInt32(0)) ?? 0) != 0 }
        case .volume:
            return els.allSatisfy { (HAL.get(id, volumeAddress($0), Float32(1)) ?? 1) < 0.001 }
        }
    }

    /// Mutes the device. `existing` keeps previously saved volumes so they never become 0.
    /// Returns the record on success, nil if the device can't be (reliably) muted.
    static func mute(_ id: AudioDeviceID, existing: MutedRecord?) -> MutedRecord? {
        guard let method = existing?.method ?? method(for: id) else { return nil }
        let els = elements(method, id)
        guard !els.isEmpty else { return nil }
        var record = existing ?? MutedRecord(method: method)
        switch method {
        case .muteMain, .muteChannels:
            for el in els { HAL.set(id, muteAddress(el), UInt32(1)) }
        case .volume:
            for el in els where record.savedVolumes[el] == nil {
                record.savedVolumes[el] = HAL.get(id, volumeAddress(el), Float32(1)) ?? 1
            }
            for el in els { HAL.set(id, volumeAddress(el), Float32(0)) }
        }
        return isHeld(id, record) ? record : nil
    }

    static func unmute(_ id: AudioDeviceID, _ record: MutedRecord) {
        switch record.method {
        case .muteMain, .muteChannels:
            for el in elements(record.method, id) { HAL.set(id, muteAddress(el), UInt32(0)) }
        case .volume:
            for (el, volume) in record.savedVolumes { HAL.set(id, volumeAddress(el), volume) }
        }
    }
}
