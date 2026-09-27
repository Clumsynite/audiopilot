import Foundation
import Testing
@testable import AudioPilotCore

@Suite struct EngineTests {
    let t0 = F.t0
    func at(_ s: TimeInterval) -> Date { F.t0.addingTimeInterval(s) }

    @Test func firstRunSeedsAndFixesBluetoothMic() {
        var e = Engine()
        let devices = F.base + [F.btSplitIn, F.btSplitOut]
        let actions = e.reduce(.start(devices: devices,
                                      defaults: [.input: F.btSplitIn.uid, .output: F.btSplitOut.uid],
                                      prefsExisted: false), now: t0)
        #expect(e.state.prefs.inputPriority == [F.builtInMic.uid, F.btSplitIn.uid])
        #expect(e.state.prefs.outputPriority == [F.btSplitOut.uid, F.builtInSpeakers.uid])
        #expect(e.state.prefs.knownDevices[F.btSplitIn.uid]?.allowAsMic == false)
        #expect(e.state.prefs.knownDevices[F.builtInMic.uid]?.allowAsMic == true)
        #expect(actions.sets(.input) == [F.builtInMic.uid])
        #expect(actions.sets(.output).isEmpty)
        #expect(actions.saves)
        #expect(actions.contains(.scheduleRetryBurst))
        #expect(actions.hasLog("decision dir=in"))
        #expect(actions.hasLog("decision dir=out"))
    }

    @Test func firstRunSkipsVirtualDefault() {
        var e = Engine()
        _ = e.reduce(.start(devices: F.base + [F.zoomVirtual],
                            defaults: [.input: F.builtInMic.uid, .output: F.zoomVirtual.uid],
                            prefsExisted: false), now: t0)
        #expect(e.state.prefs.outputPriority == [F.builtInSpeakers.uid])
    }

    @Test func newUSBHeadsetTakesOver() {
        var e = F.started()
        let actions = e.reduce(.devicesChanged(F.base + [F.usbHeadset]), now: at(100))
        #expect(actions.sets(.input) == [F.usbHeadset.uid])
        #expect(actions.sets(.output) == [F.usbHeadset.uid])
        #expect(actions.contains(.setSystemOutput(F.usbHeadset.uid)))
        #expect(e.state.prefs.inputPriority.first == F.usbHeadset.uid)
    }

    @Test func disconnectFallbackIsNotLearned() {
        var e = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.usbHeadset.uid, F.builtInMic.uid],
                          output: [F.usbHeadset.uid, F.builtInSpeakers.uid])
        // Unplug: the engine moves to built-in itself.
        let a1 = e.reduce(.devicesChanged(F.base), now: at(100))
        #expect(a1.sets(.input) == [F.builtInMic.uid])
        // macOS reports the change 0.2 s later.
        _ = e.reduce(.defaultChanged(.input, F.builtInMic.uid), now: at(100.2))
        _ = e.reduce(.defaultChanged(.output, F.builtInSpeakers.uid), now: at(100.2))
        _ = e.reduce(.tick, now: at(106))
        #expect(e.state.prefs.inputPriority == [F.usbHeadset.uid, F.builtInMic.uid])
        #expect(e.state.prefs.outputPriority == [F.usbHeadset.uid, F.builtInSpeakers.uid])
        // Replug: the headset wins again.
        let a2 = e.reduce(.devicesChanged(F.base + [F.usbHeadset]), now: at(200))
        #expect(a2.sets(.input) == [F.usbHeadset.uid])
        #expect(a2.sets(.output) == [F.usbHeadset.uid])
    }

    @Test func reversedEventOrderIsNotLearned() {
        var e = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.usbHeadset.uid, F.builtInMic.uid],
                          output: [F.usbHeadset.uid, F.builtInSpeakers.uid])
        // CoreAudio reports the new default before the device list.
        _ = e.reduce(.defaultChanged(.input, F.builtInMic.uid), now: at(100))
        #expect(e.state.learnCandidate[.input] != nil)
        _ = e.reduce(.devicesChanged(F.base), now: at(100.05))
        #expect(e.state.learnCandidate.isEmpty)
        let a = e.reduce(.tick, now: at(106))
        #expect(!a.hasLog("learned"))
        #expect(e.state.prefs.inputPriority == [F.usbHeadset.uid, F.builtInMic.uid])
    }

    @Test func bluetoothMicHijackAfterConnectIsReverted() {
        var e = F.started()
        let a1 = e.reduce(.devicesChanged(F.base + [F.btSplitIn, F.btSplitOut]), now: at(100))
        #expect(a1.sets(.output) == [F.btSplitOut.uid])
        #expect(a1.sets(.input).isEmpty)
        _ = e.reduce(.defaultChanged(.output, F.btSplitOut.uid), now: at(100.1))
        let a2 = e.reduce(.defaultChanged(.input, F.btSplitIn.uid), now: at(100.5))
        #expect(a2.sets(.input) == [F.builtInMic.uid])
        #expect(e.state.prefs.knownDevices[F.btSplitIn.uid]?.allowAsMic == false)
    }

    @Test func combinedBluetoothHeadsetMicIsBlocked() {
        var e = F.started()
        let a = e.reduce(.devicesChanged(F.base + [F.btCombo]), now: at(100))
        #expect(a.sets(.output) == [F.btCombo.uid])
        #expect(a.sets(.input).isEmpty)
        let b = e.reduce(.defaultChanged(.input, F.btCombo.uid), now: at(100.3))
        #expect(b.sets(.input) == [F.builtInMic.uid])
    }

    @Test func blockedMicIsRevertedEvenWhenCalm() {
        var e = F.started(devices: F.base + [F.btSplitIn, F.btSplitOut],
                          input: [F.builtInMic.uid, F.btSplitIn.uid],
                          output: [F.btSplitOut.uid, F.builtInSpeakers.uid])
        let a = e.reduce(.defaultChanged(.input, F.btSplitIn.uid), now: at(60))
        #expect(a.sets(.input) == [F.builtInMic.uid])
        #expect(e.state.learnCandidate[.input] == nil)
    }

    @Test func menuPickAllowsBluetoothMic() {
        var e = F.started(devices: F.base + [F.btSplitIn, F.btSplitOut],
                          input: [F.builtInMic.uid, F.btSplitIn.uid],
                          output: [F.btSplitOut.uid, F.builtInSpeakers.uid])
        let a = e.reduce(.userPicked(.input, F.btSplitIn.uid), now: at(50))
        #expect(a.sets(.input) == [F.btSplitIn.uid])
        #expect(a.saves)
        #expect(e.state.prefs.knownDevices[F.btSplitIn.uid]?.allowAsMic == true)
        #expect(e.state.prefs.inputPriority.first == F.btSplitIn.uid)
        _ = e.reduce(.defaultChanged(.input, F.btSplitIn.uid), now: at(50.1))

        let gone = e.reduce(.devicesChanged(F.base), now: at(100))
        #expect(gone.sets(.input) == [F.builtInMic.uid])
        _ = e.reduce(.defaultChanged(.input, F.builtInMic.uid), now: at(100.1))
        let back = e.reduce(.devicesChanged(F.base + [F.btSplitIn, F.btSplitOut]), now: at(200))
        #expect(back.sets(.input) == [F.btSplitIn.uid])
    }

    @Test func calmExternalChangeIsLearned() {
        var e = F.started(devices: F.base + [F.hdmiMonitor],
                          output: [F.builtInSpeakers.uid, F.hdmiMonitor.uid])
        let a = e.reduce(.defaultChanged(.output, F.hdmiMonitor.uid), now: at(100))
        #expect(a.sets.isEmpty)
        #expect(a.contains(.scheduleTick(after: Engine.learnTickDelay)))
        let t = e.reduce(.tick, now: at(105.1))
        #expect(e.state.prefs.outputPriority == [F.hdmiMonitor.uid, F.builtInSpeakers.uid])
        #expect(t.saves)
        #expect(t.sets.isEmpty)
        #expect(e.state.manualOverride.isEmpty)
    }

    @Test func inputChangeRightAfterOutputChangeIsAcceptedNotLearned() {
        var e = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.builtInMic.uid, F.usbHeadset.uid],
                          output: [F.builtInSpeakers.uid, F.usbHeadset.uid])
        _ = e.reduce(.defaultChanged(.output, F.usbHeadset.uid), now: at(100))
        let a = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(101))
        #expect(a.sets.isEmpty)
        #expect(e.state.manualOverride[.input] == F.usbHeadset.uid)
        let t = e.reduce(.tick, now: at(105.2))
        #expect(t.sets.isEmpty)
        #expect(e.state.prefs.inputPriority == [F.builtInMic.uid, F.usbHeadset.uid])
        #expect(e.state.prefs.outputPriority.first == F.usbHeadset.uid)
        #expect(e.state.manualOverride[.input] == F.usbHeadset.uid)
        // A device event ends the override.
        let d = e.reduce(.devicesChanged(F.base + [F.usbHeadset]), now: at(200))
        #expect(e.state.manualOverride.isEmpty)
        #expect(d.sets(.input) == [F.builtInMic.uid])
    }

    @Test func pendingSelfSetIsIgnored() {
        var e = F.started()
        _ = e.reduce(.devicesChanged(F.base + [F.usbHeadset]), now: at(100))
        let a = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(100.1))
        #expect(a.isEmpty)
        #expect(e.state.pending[.input] == nil)
        #expect(e.state.learnCandidate[.input] == nil)
    }

    @Test func expiredPendingDoesNotSwallowUserChange() {
        var s = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.builtInMic.uid, F.usbHeadset.uid]).state
        s.pending[.input] = PendingSet(uid: F.usbHeadset.uid, deadline: at(101.5))
        var e = Engine(state: s)
        _ = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(102))
        #expect(e.state.pending[.input] == nil)
        #expect(e.state.learnCandidate[.input]?.uid == F.usbHeadset.uid)
    }

    @Test func enforcementIsCapped() {
        var e = F.started(devices: F.base + [F.btSplitIn],
                          input: [F.builtInMic.uid, F.btSplitIn.uid])
        var reverts = 0
        var gaveUp = false
        for i in 0..<6 {
            let a = e.reduce(.defaultChanged(.input, F.btSplitIn.uid), now: at(100 + Double(i) * 0.5))
            reverts += a.sets(.input).count
            gaveUp = gaveUp || a.hasLog("gave up")
        }
        #expect(reverts == 5)
        #expect(gaveUp)
        #expect(e.state.manualOverride[.input] == F.btSplitIn.uid)
        // After a quiet period the cap resets.
        _ = e.reduce(.devicesChanged(F.base + [F.btSplitIn]), now: at(200))
        let later = e.reduce(.defaultChanged(.input, F.btSplitIn.uid), now: at(300))
        #expect(later.sets(.input) == [F.builtInMic.uid])
    }

    @Test func virtualAndAggregateAreNotAutoSelected() {
        var e = F.started()
        let a = e.reduce(.devicesChanged(F.base + [F.zoomVirtual, F.aggregate]), now: at(100))
        #expect(a.sets.isEmpty)
        #expect(!e.state.prefs.inputPriority.contains(F.zoomVirtual.uid))
        #expect(!e.state.prefs.outputPriority.contains(F.aggregate.uid))
        let p = e.reduce(.userPicked(.output, F.zoomVirtual.uid), now: at(110))
        #expect(p.sets(.output) == [F.zoomVirtual.uid])
        #expect(e.state.prefs.outputPriority.first == F.zoomVirtual.uid)
    }

    @Test func newHDMIMonitorTakesOutput() {
        var e = F.started()
        let a = e.reduce(.devicesChanged(F.base + [F.hdmiMonitor]), now: at(100))
        #expect(a.sets(.output) == [F.hdmiMonitor.uid])
        #expect(a.sets(.input).isEmpty)
    }

    @Test func nameFallbackMigratesSingleMatch() {
        let old = F.dev("StudioDisplay:port1", "Studio Display", .usb, output: 2)
        let new = F.dev("StudioDisplay:port2", "Studio Display", .usb, output: 2)
        var e = F.started(output: [F.builtInSpeakers.uid, old.uid], known: [old])
        let a = e.reduce(.devicesChanged(F.base + [new]), now: at(100))
        #expect(e.state.prefs.outputPriority == [F.builtInSpeakers.uid, new.uid])
        #expect(e.state.prefs.knownDevices[old.uid] == nil)
        #expect(e.state.prefs.knownDevices[new.uid] != nil)
        #expect(a.sets.isEmpty)
    }

    @Test func nameFallbackWithTwoCandidatesIsNewDevice() {
        let a1 = F.dev("usb-a", "USB Audio Device", .usb, output: 2)
        let a2 = F.dev("usb-b", "USB Audio Device", .usb, output: 2)
        let fresh = F.dev("usb-c", "USB Audio Device", .usb, output: 2)
        var e = F.started(output: [F.builtInSpeakers.uid, a1.uid, a2.uid], known: [a1, a2])
        let a = e.reduce(.devicesChanged(F.base + [fresh]), now: at(100))
        #expect(e.state.prefs.outputPriority.first == fresh.uid)
        #expect(e.state.prefs.knownDevices[a1.uid] != nil)
        #expect(a.sets(.output) == [fresh.uid])
    }

    @Test func runningAppRuleOverrideAndRevert() {
        let zoom = "us.zoom.xos"
        var e = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.builtInMic.uid, F.usbHeadset.uid],
                          output: [F.builtInSpeakers.uid, F.usbHeadset.uid]) { p in
            p.appRules = [AppRule(bundleID: zoom, appName: "Zoom", inputUID: F.usbHeadset.uid)]
        }
        let launch = e.reduce(.appsChanged(running: [RunningApp(bundleID: zoom, launchDate: at(100))], frontmost: zoom), now: at(100))
        #expect(launch.sets(.input) == [F.usbHeadset.uid])
        #expect(launch.sets(.output).isEmpty)
        _ = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(100.1))

        let pick = e.reduce(.userPicked(.input, F.builtInMic.uid), now: at(120))
        #expect(pick.sets(.input) == [F.builtInMic.uid])
        #expect(e.state.manualOverride[.input] == F.builtInMic.uid)
        #expect(e.state.prefs.inputPriority == [F.builtInMic.uid, F.usbHeadset.uid])
        _ = e.reduce(.defaultChanged(.input, F.builtInMic.uid), now: at(120.1))

        // Switching frontmost app doesn't undo the pick.
        let other = e.reduce(.appsChanged(running: [RunningApp(bundleID: zoom, launchDate: at(100))], frontmost: "com.apple.Safari"), now: at(130))
        #expect(other.sets.isEmpty)

        // External change while the rule is active: accepted, not learned.
        _ = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(140))
        #expect(e.state.learnCandidate[.input] == nil)
        #expect(e.state.manualOverride[.input] == F.usbHeadset.uid)

        let quit = e.reduce(.appsChanged(running: [], frontmost: "com.apple.Safari"), now: at(150))
        #expect(e.state.manualOverride[.input] == nil)
        #expect(quit.sets(.input) == [F.builtInMic.uid])
        #expect(e.state.prefs.inputPriority == [F.builtInMic.uid, F.usbHeadset.uid])
    }

    @Test func pausedDoesNothingButMenuPicksStillWork() {
        var e = F.started(devices: F.base + [F.hdmiMonitor], output: [F.builtInSpeakers.uid, F.hdmiMonitor.uid])
        _ = e.reduce(.setAutoSwitch(false), now: at(10))
        let d = e.reduce(.devicesChanged(F.base + [F.hdmiMonitor, F.usbHeadset]), now: at(100))
        #expect(d.sets.isEmpty)
        let c = e.reduce(.defaultChanged(.input, F.usbHeadset.uid), now: at(200))
        #expect(c.isEmpty)
        let p = e.reduce(.userPicked(.output, F.hdmiMonitor.uid), now: at(300))
        #expect(p.sets(.output) == [F.hdmiMonitor.uid])
        #expect(e.state.prefs.outputPriority.first == F.hdmiMonitor.uid)
        let r = e.reduce(.setAutoSwitch(true), now: at(400))
        #expect(r.hasLog("decision"))
    }

    @Test func forgetOnlyDisconnected() {
        var e = F.started(devices: F.base, input: [F.builtInMic.uid, F.usbHeadset.uid], known: [F.usbHeadset])
        _ = e.reduce(.forget(F.builtInMic.uid), now: at(10))
        #expect(e.state.prefs.inputPriority.contains(F.builtInMic.uid))
        _ = e.reduce(.forget(F.usbHeadset.uid), now: at(10))
        #expect(!e.state.prefs.inputPriority.contains(F.usbHeadset.uid))
        #expect(e.state.prefs.knownDevices[F.usbHeadset.uid] == nil)
    }

    @Test func wakeOpensTopologyWindow() {
        var e = F.started(devices: F.base + [F.usbHeadset],
                          input: [F.usbHeadset.uid, F.builtInMic.uid],
                          output: [F.usbHeadset.uid, F.builtInSpeakers.uid])
        _ = e.reduce(.wake, now: at(1000))
        let a = e.reduce(.defaultChanged(.input, F.builtInMic.uid), now: at(1001))
        #expect(a.sets(.input) == [F.usbHeadset.uid])
        #expect(e.state.learnCandidate.isEmpty)
    }
}

@Suite struct ProfileTests {
    @Test func createKeepsDefaultAndSwitchingRestoresLists() {
        var prefs = Preferences()
        prefs.outputPriority = ["speakers", "hdmi"]
        let office = prefs.createProfile(named: "Office")
        #expect(prefs.profiles.map(\.name) == ["Default", "Office"])
        #expect(prefs.activeProfileID == office)
        prefs.outputPriority = ["hdmi", "speakers"]
        let home = prefs.profiles[0].id
        let toHome = prefs.activateProfile(home)
        #expect(toHome)
        #expect(prefs.outputPriority == ["speakers", "hdmi"])
        #expect(prefs.profiles[1].outputPriority == ["hdmi", "speakers"])
        let toOffice = prefs.activateProfile(office)
        #expect(toOffice)
        #expect(prefs.outputPriority == ["hdmi", "speakers"])
    }

    @Test func engineSwitchReevaluates() {
        var e = F.started(devices: F.base + [F.hdmiMonitor], output: [F.builtInSpeakers.uid, F.hdmiMonitor.uid])
        _ = e.reduce(.setAutoSwitch(true), now: F.t0)
        var prefs = e.state.prefs
        let desk = prefs.createProfile(named: "Desk")
        prefs.activateProfile(prefs.profiles[0].id)
        prefs.profiles[prefs.profiles.firstIndex { $0.id == desk }!].outputPriority = [F.hdmiMonitor.uid, F.builtInSpeakers.uid]
        var s = e.state
        s.prefs = prefs
        e = Engine(state: s)
        let a = e.reduce(.switchProfile(desk), now: F.t0.addingTimeInterval(50))
        #expect(a.sets(.output) == [F.hdmiMonitor.uid])
        #expect(e.state.prefs.activeProfile?.name == "Desk")
    }

    @Test func cannotDeleteOnlyActiveProfile() {
        var prefs = Preferences()
        prefs.createProfile(named: "A")
        let ids = prefs.profiles.map(\.id)
        prefs.deleteProfile(ids[1])
        #expect(prefs.profiles.count == 1)
        prefs.deleteProfile(ids[0])
        #expect(prefs.profiles.count == 1)
    }
}
