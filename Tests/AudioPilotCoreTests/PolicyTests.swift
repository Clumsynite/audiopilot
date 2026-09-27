import Foundation
import Testing
@testable import AudioPilotCore

@Suite struct PolicyTests {
    func state(_ devices: [AudioDeviceInfo], input: [String] = [], output: [String] = [],
               configure: (inout EngineState) -> Void = { _ in }) -> EngineState {
        var s = EngineState()
        s.connected = devices
        s.prefs.inputPriority = input
        s.prefs.outputPriority = output
        for d in devices {
            s.prefs.knownDevices[d.uid] = KnownDevice(d, allowAsMic: !d.transport.blocksMicByDefault, now: F.t0)
        }
        configure(&s)
        return s
    }

    @Test func firstQualifyingPriorityWins() {
        let s = state(F.base + [F.usbHeadset],
                      input: ["missing", F.usbHeadset.uid, F.builtInMic.uid],
                      output: [F.hdmiMonitor.uid, F.builtInSpeakers.uid, F.usbHeadset.uid])
        #expect(DevicePolicy.target(.input, in: s) == (F.usbHeadset.uid, .priority))
        #expect(DevicePolicy.target(.output, in: s) == (F.builtInSpeakers.uid, .priority))
    }

    @Test func blockedMicIsSkipped() {
        let s = state(F.base + [F.btSplitIn, F.continuityMic],
                      input: [F.btSplitIn.uid, F.continuityMic.uid, F.builtInMic.uid])
        #expect(DevicePolicy.target(.input, in: s) == (F.builtInMic.uid, .priority))
    }

    @Test func fallbackPrefersBuiltIn() {
        let s = state([F.usbHeadset, F.btSplitIn, F.builtInMic, F.zoomVirtual, F.builtInSpeakers])
        #expect(DevicePolicy.target(.input, in: s) == (F.builtInMic.uid, .fallback))
        #expect(DevicePolicy.target(.output, in: s) == (F.builtInSpeakers.uid, .fallback))
        let noBuiltIn = state([F.usbHeadset, F.zoomVirtual])
        #expect(DevicePolicy.target(.input, in: noBuiltIn) == (F.usbHeadset.uid, .fallback))
    }

    @Test func runningRuleBeatsPriorityMostRecentLaunchWins() {
        let s = state(F.base + [F.usbHeadset, F.hdmiMonitor],
                      input: [F.builtInMic.uid], output: [F.builtInSpeakers.uid]) { s in
            s.prefs.appRules = [
                AppRule(bundleID: "old.app", appName: "Old", outputUID: F.hdmiMonitor.uid),
                AppRule(bundleID: "new.app", appName: "New", inputUID: F.usbHeadset.uid, outputUID: F.usbHeadset.uid),
            ]
            s.running = [RunningApp(bundleID: "old.app", launchDate: F.t0),
                         RunningApp(bundleID: "new.app", launchDate: F.t0.addingTimeInterval(10))]
        }
        #expect(DevicePolicy.target(.input, in: s) == (F.usbHeadset.uid, .rule))
        #expect(DevicePolicy.target(.output, in: s) == (F.usbHeadset.uid, .rule))
    }

    @Test func frontmostRuleOnlyWhenFrontmost() {
        var s = state(F.base + [F.usbHeadset], input: [F.builtInMic.uid]) { s in
            s.prefs.appRules = [AppRule(bundleID: "a", appName: "A", inputUID: F.usbHeadset.uid, trigger: .frontmost)]
            s.running = [RunningApp(bundleID: "a", launchDate: F.t0)]
        }
        #expect(DevicePolicy.target(.input, in: s).reason == .priority)
        s.frontmost = "a"
        #expect(DevicePolicy.target(.input, in: s) == (F.usbHeadset.uid, .rule))
    }

    @Test func ruleMayUseBlockedMic() {
        let s = state(F.base + [F.btSplitIn], input: [F.builtInMic.uid]) { s in
            s.prefs.appRules = [AppRule(bundleID: "a", appName: "A", inputUID: F.btSplitIn.uid)]
            s.running = [RunningApp(bundleID: "a", launchDate: F.t0)]
        }
        #expect(DevicePolicy.target(.input, in: s) == (F.btSplitIn.uid, .rule))
    }

    @Test func onlyBlockedMicGivesNil() {
        let s = state([F.btSplitIn, F.btSplitOut], input: [F.btSplitIn.uid])
        #expect(DevicePolicy.target(.input, in: s) == (nil, .none))
        #expect(DevicePolicy.target(.output, in: s) == (F.btSplitOut.uid, .fallback))
    }

    @Test func unqualifiedDevicesIgnored() {
        var hidden = F.usbHeadset
        hidden.isHidden = true
        let s = state([hidden, F.builtInMic], input: [hidden.uid])
        #expect(DevicePolicy.target(.input, in: s) == (F.builtInMic.uid, .fallback))
    }
}

@Suite struct HiddenDeviceTests {
    @Test func hiddenDeviceIsNeverChosen() {
        var s = EngineState()
        s.connected = F.base + [F.usbHeadset]
        s.prefs.inputPriority = [F.usbHeadset.uid, F.builtInMic.uid]
        s.prefs.deviceSettings[F.usbHeadset.uid] = DeviceSettings(hidden: true)
        #expect(DevicePolicy.target(.input, in: s) == (F.builtInMic.uid, .priority))
        s.prefs.inputPriority = []
        #expect(DevicePolicy.target(.input, in: s) == (F.builtInMic.uid, .fallback))
    }

    @Test func hiddenNewDeviceDoesNotTakeOver() {
        var e = F.started { p in p.deviceSettings[F.hdmiMonitor.uid] = DeviceSettings(hidden: true) }
        let a = e.reduce(.devicesChanged(F.base + [F.hdmiMonitor]), now: F.t0.addingTimeInterval(100))
        #expect(a.sets.isEmpty)
    }
}
