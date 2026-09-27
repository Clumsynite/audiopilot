import CoreAudio
import Foundation
import AudioPilotCore

/// `--list-devices` output. Deliberately omits AudioDeviceIDs so before/after runs can be diffed.
enum DeviceTable {
    static func render(_ hal: AudioHAL) -> String {
        let defIn = hal.defaultUID(.input)
        let defOut = hal.defaultUID(.output)
        let defSys = AudioHAL.defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
        func yn(_ b: Bool) -> String { b ? "Y" : "-" }

        var rows: [[String]] = [["uid", "name", "transport", "inCh", "outCh", "canDefIn", "canDefOut", "canDefSys",
                                 "defIn", "defOut", "defSys", "muteSettable", "mute", "volSettable", "vol"]]
        for dev in hal.devices() {
            var muteSettable = "-", mute = "-", volSettable = "-", vol = "-"
            if dev.hasInput, let id = AudioHAL.id(forUID: dev.uid) {
                let method = MuteDriver.method(for: id)
                muteSettable = yn(method == .muteMain || method == .muteChannels)
                volSettable = yn(!MuteDriver.elements(.volume, id).isEmpty)
                mute = MuteDriver.readMute(id).map { $0 ? "on" : "off" } ?? "-"
                vol = MuteDriver.readVolume(id).map { String(format: "%.2f", $0) } ?? "-"
            }
            rows.append([dev.uid, dev.name, dev.transport.rawValue, "\(dev.inputChannels)", "\(dev.outputChannels)",
                         yn(dev.canBeDefaultInput), yn(dev.canBeDefaultOutput), yn(dev.canBeDefaultSystem),
                         "defIn=" + yn(dev.uid == defIn), "defOut=" + yn(dev.uid == defOut), "defSys=" + yn(dev.uid == defSys),
                         muteSettable, mute, volSettable, vol])
        }
        let widths = rows[0].indices.map { col in rows.map { $0[col].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: " | ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}
