import Foundation
import Testing
@testable import AudioPilotCore

@Suite struct MicRuleTests {
    func at(_ s: TimeInterval) -> Date { F.t0.addingTimeInterval(s) }
    let zoom = "us.zoom.xos"

    func headsetEngine(_ rules: [AppRule]) -> Engine {
        F.started(devices: F.base + [F.usbHeadset],
                  input: [F.builtInMic.uid, F.usbHeadset.uid],
                  output: [F.builtInSpeakers.uid, F.usbHeadset.uid]) { $0.appRules = rules }
    }

    @Test func anyAppUsingMicSwitchesAndReleasesAfterGrace() {
        var e = headsetEngine([AppRule(bundleID: AppRule.anyApp, appName: "Any app", inputUID: F.usbHeadset.uid,
                                       outputUID: F.usbHeadset.uid, trigger: .usingMic)])
        let start = e.reduce(.micUsersChanged([zoom]), now: at(100))
        #expect(start.sets(.input) == [F.usbHeadset.uid])
        #expect(start.sets(.output) == [F.usbHeadset.uid])
        _ = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(100.1))
        _ = e.reduce(.defaultChanged(.output, F.usbHeadset.uid), now: at(100.1))

        // Capture stops briefly while the device switches: the rule holds.
        let blip = e.reduce(.micUsersChanged([]), now: at(100.3))
        #expect(blip.sets.isEmpty)
        #expect(blip.contains(.scheduleTick(after: Engine.micReleaseDelay + 0.1)))
        _ = e.reduce(.micUsersChanged([zoom]), now: at(101))
        #expect(e.state.micLinger.isEmpty)

        // The call really ends: back to the priority list once the grace period is over.
        _ = e.reduce(.micUsersChanged([]), now: at(200))
        #expect(e.reduce(.tick, now: at(202)).sets.isEmpty)
        let end = e.reduce(.tick, now: at(204.2))
        #expect(end.sets(.input) == [F.builtInMic.uid])
        #expect(end.sets(.output) == [F.builtInSpeakers.uid])
        #expect(e.state.prefs.inputPriority == [F.builtInMic.uid, F.usbHeadset.uid])
    }

    @Test func namedMicRuleBeatsAnyAppAndRunningRules() {
        let rules = [
            AppRule(bundleID: zoom, appName: "Zoom", outputUID: F.builtInSpeakers.uid, trigger: .running),
            AppRule(bundleID: AppRule.anyApp, appName: "Any app", outputUID: F.builtInSpeakers.uid, trigger: .usingMic),
            AppRule(bundleID: zoom, appName: "Zoom", outputUID: F.usbHeadset.uid, trigger: .usingMic),
        ]
        var s = EngineState()
        s.prefs.appRules = rules
        s.connected = F.base + [F.usbHeadset]
        s.running = [RunningApp(bundleID: zoom, launchDate: F.t0)]
        #expect(DevicePolicy.activeRule(.output, in: s)?.id == rules[0].id)
        s.micUsers = ["com.apple.FaceTime"]
        #expect(DevicePolicy.activeRule(.output, in: s)?.id == rules[1].id)
        s.micUsers = ["com.apple.FaceTime", zoom]
        #expect(DevicePolicy.activeRule(.output, in: s)?.id == rules[2].id)
        #expect(DevicePolicy.activeRule(.input, in: s) == nil)
    }

    @Test func manualPickDuringCallIsDroppedWhenCallEnds() {
        var e = headsetEngine([AppRule(bundleID: zoom, appName: "Zoom", inputUID: F.usbHeadset.uid, trigger: .usingMic)])
        _ = e.reduce(.micUsersChanged([zoom]), now: at(100))
        _ = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(100.1))
        _ = e.reduce(.userPicked(.input, F.builtInMic.uid), now: at(110))
        #expect(e.state.manualOverride[.input] == F.builtInMic.uid)
        _ = e.reduce(.micUsersChanged([]), now: at(200))
        _ = e.reduce(.tick, now: at(205))
        #expect(e.state.manualOverride[.input] == nil)
    }

    @Test func micUsersDecodeOldRuleFiles() throws {
        let data = Data(#"{"appRules":[{"id":"6D1C5A4E-4E0A-4E5B-9F59-1C0A5E3B2A10","bundleID":"x","appName":"X","trigger":"usingMic"}]}"#.utf8)
        let prefs = try JSONDecoder.store.decode(Preferences.self, from: data)
        #expect(prefs.appRules.first?.trigger == .usingMic)
    }
}

@Suite struct AppAudioTests {
    let speakers = F.builtInSpeakers.uid
    let headset = F.usbHeadset.uid
    let connected = F.base + [F.usbHeadset, F.aggregate]

    @Test func neutralSettingsAreDropped() {
        var list: [AppAudioSetting] = []
        list.edit("com.spotify.client", appName: "Spotify") { $0.volume = 0.5 }
        #expect(list.count == 1)
        list.edit("com.spotify.client", appName: "Spotify") { $0.volume = 1 }
        #expect(list.isEmpty)
        list.edit("com.spotify.client", appName: "Spotify") { $0.muted = true }
        #expect(list.first?.gain == 0)
    }

    @Test func outcomes() {
        func outcome(_ s: AppAudioSetting, _ def: String? = F.builtInSpeakers.uid) -> AppAudioPlan.Outcome {
            AppAudioPlan.outcome(for: s, defaultOutput: def, connected: connected)
        }
        let app = AppAudioSetting(bundleID: "a", appName: "A")
        #expect(outcome(app) == .untouched)

        var quiet = app
        quiet.volume = 0.5
        #expect(outcome(quiet) == .route(.init(outputUID: speakers, gain: 0.25)))

        var routed = app
        routed.outputUID = headset
        #expect(outcome(routed) == .route(.init(outputUID: headset, gain: 1)))
        // Routed to the device that is already the system output, at full volume: nothing to do.
        #expect(outcome(routed, headset) == .untouched)

        // Chosen device unplugged: volume still applies on the system output.
        var offline = quiet
        offline.outputUID = "gone"
        #expect(outcome(offline) == .route(.init(outputUID: speakers, gain: 0.25)))

        var toGroup = app
        toGroup.outputUID = F.aggregate.uid
        if case .unsupported = outcome(toGroup) {} else { Issue.record("aggregate target should be unsupported") }
        if case .unsupported = outcome(quiet, nil) {} else { Issue.record("no output should be unsupported") }
    }

    @Test func outputMigratesWithDevice() {
        let old = F.dev("usb-old", "Desk DAC", .usb, output: 2)
        let new = F.dev("usb-new", "Desk DAC", .usb, output: 2)
        var e = F.started(output: [F.builtInSpeakers.uid, old.uid], known: [old]) {
            $0.appAudio = [AppAudioSetting(bundleID: "a", appName: "A", outputUID: old.uid)]
        }
        _ = e.reduce(.devicesChanged(F.base + [new]), now: F.t0.addingTimeInterval(10))
        #expect(e.state.prefs.appAudio.first?.outputUID == new.uid)
    }
}

@Suite struct SettingsTransferTests {
    func sample() -> Preferences {
        var p = Preferences()
        p.inputPriority = ["mic-a"]
        p.outputPriority = ["out-a"]
        p.knownDevices["out-a"] = KnownDevice(name: "A", transport: .usb, hasInput: false, hasOutput: true,
                                              allowAsMic: true, lastSeen: F.t0)
        p.theme = "aurora"
        p.launchAtLogin = true
        p.appAudio = [AppAudioSetting(bundleID: "s", appName: "S", volume: 0.4)]
        p.createProfile(named: "Office")
        p.outputPriority = ["out-b"]
        return p
    }

    @Test func roundTripMergesLocalDevicesAndKeepsLoginItem() throws {
        let data = try SettingsTransfer.export(sample(), appVersion: "0.2.0", now: F.t0)
        var local = Preferences()
        local.knownDevices["here"] = KnownDevice(name: "Here", transport: .builtIn, hasInput: true, hasOutput: false,
                                                 allowAsMic: true, lastSeen: F.t0)
        local.launchAtLogin = false
        let merged = try SettingsTransfer.importing(data, into: local)
        #expect(merged.theme == "aurora")
        #expect(merged.appAudio.first?.volume == 0.4)
        #expect(merged.launchAtLogin == false)
        #expect(Set(merged.knownDevices.keys) == ["out-a", "here"])
        // The export stored the live lists into the active profile first.
        #expect(merged.profiles.first { $0.name == "Office" }?.outputPriority == ["out-b"])
        #expect(merged.activeProfileID == merged.profiles.first { $0.name == "Office" }?.id)
    }

    @Test func acceptsBarePreferencesFile() throws {
        let data = try JSONEncoder.store.encode(sample())
        #expect(try SettingsTransfer.importing(data, into: Preferences()).theme == "aurora")
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: SettingsTransfer.ImportError.notAudioPilot) {
            try SettingsTransfer.importing(Data(#"{"hello":"world"}"#.utf8), into: Preferences())
        }
        #expect(throws: SettingsTransfer.ImportError.notAudioPilot) {
            try SettingsTransfer.importing(Data("nope".utf8), into: Preferences())
        }
        var future = SettingsExport(preferences: Preferences(), appVersion: nil, exportedAt: F.t0)
        future.version = 99
        let data = try! JSONEncoder.store.encode(future)
        #expect(throws: SettingsTransfer.ImportError.newerVersion(99)) {
            try SettingsTransfer.importing(data, into: Preferences())
        }
    }

    @Test func engineImportKeepsUnlistedLocalDevicesAndSwitches() {
        var e = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.usbHeadset.uid, F.builtInMic.uid],
                          output: [F.usbHeadset.uid, F.builtInSpeakers.uid])
        var imported = Preferences()
        imported.outputPriority = [F.builtInSpeakers.uid]
        imported.inputPriority = ["other-mac-mic"]
        let a = e.reduce(.importPreferences(imported), now: F.t0.addingTimeInterval(50))
        #expect(e.state.prefs.outputPriority.first == F.builtInSpeakers.uid)
        #expect(e.state.prefs.outputPriority.contains(F.usbHeadset.uid))
        #expect(e.state.prefs.inputPriority.first == "other-mac-mic")
        #expect(a.sets(.output) == [F.builtInSpeakers.uid])
        #expect(a.saves)
    }
}
