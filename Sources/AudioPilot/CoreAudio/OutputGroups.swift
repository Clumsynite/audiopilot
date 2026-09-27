import CoreAudio
import Foundation
import AudioPilotCore
import os

/// Creates and removes the multi-output ("stacked" aggregate) devices behind `OutputGroup`s.
/// They are public aggregates, so they show up like any other output and persist in coreaudiod;
/// AudioPilot recreates any that are missing at launch.
enum OutputGroups {
    private static let logger = Logger(subsystem: "com.techenable.audiopilot", category: "groups")

    /// Makes sure every group's device exists. Returns groups that couldn't be created.
    @discardableResult
    static func ensure(_ groups: [OutputGroup], dryRun: Bool) -> [OutputGroup] {
        groups.filter { group in
            if AudioHAL.id(forUID: group.deviceUID) != nil { return false }
            return !create(group, dryRun: dryRun)
        }
    }

    static func create(_ group: OutputGroup, dryRun: Bool) -> Bool {
        guard group.members.count >= 2 else { return false }
        if dryRun {
            print("DRYRUN create group \(group.name): \(group.members.joined(separator: ", "))")
            return true
        }
        let subdevices: [[String: Any]] = group.members.enumerated().map { i, uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: i == 0 ? 0 : 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: group.name,
            kAudioAggregateDeviceUIDKey: group.deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: group.members[0],
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0,
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        if status != noErr { logger.error("create group \(group.name, privacy: .public) failed: \(status)") }
        return status == noErr
    }

    static func destroy(_ group: OutputGroup, dryRun: Bool) {
        guard let id = AudioHAL.id(forUID: group.deviceUID) else { return }
        if dryRun {
            print("DRYRUN destroy group \(group.name)")
            return
        }
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr { logger.error("destroy group \(group.name, privacy: .public) failed: \(status)") }
    }
}
