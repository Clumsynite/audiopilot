import Foundation
import Testing
@testable import AudioPilotCore

@Suite struct StoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudioPilotTests-\(UUID().uuidString)")

    @Test func roundTrip() throws {
        let store = JSONStore(directory: dir)
        var prefs = Preferences()
        prefs.inputPriority = ["a", "b"]
        prefs.knownDevices["a"] = KnownDevice(name: "A", transport: .usb, hasInput: true, hasOutput: false,
                                              allowAsMic: true, lastSeen: F.t0)
        prefs.appRules = [AppRule(bundleID: "us.zoom.xos", appName: "Zoom", inputUID: "a")]
        prefs.hotkeyMode = .pushToTalk
        #expect(store.save(prefs, name: "preferences"))
        let (loaded, existed) = store.load(Preferences.self, name: "preferences")
        #expect(existed)
        #expect(loaded == prefs)

        let mute = MuteState(isMuted: true, devices: ["x": MutedRecord(method: .volume, savedVolumes: [0: 0.75, 1: 0.5])])
        #expect(store.save(mute, name: "mute-state"))
        #expect(store.load(MuteState.self, name: "mute-state").value == mute)
    }

    @Test func corruptFileIsBackedUp() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("preferences.json"))
        let store = JSONStore(directory: dir)
        let (loaded, existed) = store.load(Preferences.self, name: "preferences")
        #expect(loaded == nil)
        #expect(!existed)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("preferences.corrupt-") && $0.hasSuffix(".json") })
        #expect(!files.contains("preferences.json"))
    }

    @Test func missingFile() {
        let (loaded, existed) = JSONStore(directory: dir).load(Preferences.self, name: "preferences")
        #expect(loaded == nil)
        #expect(!existed)
    }

    @Test func readOnlyNeverWrites() throws {
        let store = JSONStore(directory: dir, readOnly: true)
        #expect(!store.save(Preferences(), name: "preferences"))
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("preferences.json"))
        _ = store.load(Preferences.self, name: "preferences")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["preferences.json"])
    }

    @Test func missingKeysUseDefaults() throws {
        let data = Data(#"{"inputPriority":["x"]}"#.utf8)
        let prefs = try JSONDecoder.store.decode(Preferences.self, from: data)
        #expect(prefs.inputPriority == ["x"])
        #expect(prefs.autoSwitchEnabled)
        #expect(prefs.hotkey == .default)
        #expect(!prefs.appAudioEnabled)
        #expect(prefs.muteSound == "Bottle")
        #expect(prefs.unmuteSound == "Tink")
    }

    @Test func appAudioStaysOnForExistingSettings() throws {
        let data = Data(#"{"appAudio":[{"bundleID":"a","appName":"A","volume":0.5,"muted":false}]}"#.utf8)
        #expect(try JSONDecoder.store.decode(Preferences.self, from: data).appAudioEnabled)
        let off = Data(#"{"appAudioEnabled":false,"appAudio":[{"bundleID":"a","appName":"A","volume":0.5,"muted":false}]}"#.utf8)
        #expect(try !JSONDecoder.store.decode(Preferences.self, from: off).appAudioEnabled)
    }
}

@Suite struct ShortcutTests {
    @Test func keysRoundTrip() {
        for s in [DeviceShortcut.next(.output), .next(.input), .device(.input, "64-8F:input"), .device(.output, "a:b:c")] {
            #expect(DeviceShortcut(key: s.key) == s)
        }
        #expect(DeviceShortcut(key: "bogus") == nil)
    }

    @Test func cycleWrapsAndSkips() {
        let list = ["a", "b", "c"]
        #expect(DeviceCycle.next(after: "a", in: list) == "b")
        #expect(DeviceCycle.next(after: "c", in: list) == "a")
        #expect(DeviceCycle.next(after: "a", in: list, skip: { $0 == "b" }) == "c")
        #expect(DeviceCycle.next(after: nil, in: list) == "a")
        #expect(DeviceCycle.next(after: "a", in: ["a"]) == nil)
        #expect(DeviceCycle.next(after: "a", in: list, skip: { $0 != "a" }) == nil)
    }

    @Test func clearedShortcutStaysCleared() throws {
        var prefs = Preferences()
        prefs.deviceShortcuts[DeviceShortcut.next(.input).key] = nil
        let data = try JSONEncoder.store.encode(prefs)
        let back = try JSONDecoder.store.decode(Preferences.self, from: data)
        #expect(back.deviceShortcuts[DeviceShortcut.next(.input).key] == nil)
        #expect(back.deviceShortcuts[DeviceShortcut.next(.output).key] == .nextOutput)
    }
}

@Suite struct MigrationTests {
    @Test func legacyDefaultShortcutMovesToCmdShiftM() throws {
        let v1 = Data(#"{"version":1,"hotkey":{"keyCode":46,"modifiers":6400}}"#.utf8)
        let prefs = try JSONDecoder.store.decode(Preferences.self, from: v1)
        #expect(prefs.hotkey == .default)
        #expect(prefs.version == 2)
    }

    @Test func customShortcutIsKept() throws {
        let v1 = Data(#"{"version":1,"hotkey":{"keyCode":0,"modifiers":768}}"#.utf8)
        let prefs = try JSONDecoder.store.decode(Preferences.self, from: v1)
        #expect(prefs.hotkey == HotKeySpec(keyCode: 0, modifiers: 768))
    }
}

@Suite struct RenameMigrationTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("AudioPilotMigration-\(UUID().uuidString)")

    private func makeLegacy() throws {
        let legacy = base.appendingPathComponent("MuteMe")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"inputPriority":["x"]}"#.utf8).write(to: legacy.appendingPathComponent("preferences.json"))
    }

    @Test func copiesLegacySettingsAndKeepsOriginal() throws {
        try makeLegacy()
        let dir = JSONStore.prepareDirectory(in: base, readOnly: false)
        #expect(dir.lastPathComponent == "AudioPilot")
        #expect(JSONStore(directory: dir).load(Preferences.self, name: "preferences").value?.inputPriority == ["x"])
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("MuteMe/preferences.json").path))
    }

    @Test func readOnlyReadsLegacyInPlace() throws {
        try makeLegacy()
        let dir = JSONStore.prepareDirectory(in: base, readOnly: true)
        #expect(dir.lastPathComponent == "MuteMe")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("AudioPilot").path))
    }

    @Test func freshInstallUsesNewFolder() {
        #expect(JSONStore.prepareDirectory(in: base, readOnly: false).lastPathComponent == "AudioPilot")
    }
}
