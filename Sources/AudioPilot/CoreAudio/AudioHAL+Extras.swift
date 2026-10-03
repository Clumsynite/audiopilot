import AppKit
import AudioToolbox
import CoreAudio
import AudioPilotCore

// MARK: - Sample rate & balance

extension AudioHAL {
    /// Rates the device supports, flattened from its ranges (only common rates for continuous ranges).
    func sampleRates(_ uid: String) -> [Double] {
        guard let id = Self.id(forUID: uid) else { return [] }
        var a = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges) == noErr else { return [] }
        let common: [Double] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            else { common.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { rates.insert($0) } }
        }
        return rates.sorted()
    }

    func sampleRate(_ uid: String) -> Double? {
        guard let id = Self.id(forUID: uid) else { return nil }
        return Self.get(id, Self.address(kAudioDevicePropertyNominalSampleRate), Float64(0))
    }

    func setSampleRate(_ uid: String, _ rate: Double) {
        guard !dryRun, let id = Self.id(forUID: uid) else { return }
        Self.set(id, Self.address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    private static func balanceAddress() -> AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput)
    }

    /// Stereo balance 0 (left) … 0.5 (centre) … 1 (right), or nil if the device has none.
    func balance(_ uid: String) -> Float? {
        guard let id = Self.id(forUID: uid) else { return nil }
        var a = Self.balanceAddress()
        guard AudioHardwareServiceHasProperty(id, &a) else { return nil }
        var value = Float32(0.5)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    func setBalance(_ uid: String, _ value: Float) {
        guard !dryRun, let id = Self.id(forUID: uid) else { return }
        var a = Self.balanceAddress()
        var v = Float32(min(max(value, 0), 1))
        AudioHardwareServiceSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

// MARK: - Which apps are using the microphone

extension AudioHAL {
    struct MicUser: Equatable, Hashable {
        let bundleID: String
        let name: String
    }

    /// An app's audio client: one per process (helpers such as "Google Chrome Helper" are separate
    /// processes, attributed here to their regular app).
    struct AudioProcess: Equatable {
        let object: AudioObjectID
        let bundleID: String
        let name: String
        let isRunningInput: Bool
        let isRunningOutput: Bool
    }

    /// Processes of regular apps that have audio clients (macOS 14.2+ process objects; needs no permission).
    static func audioProcesses() -> [AudioProcess] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &objects) == noErr else { return [] }

        let me = ProcessInfo.processInfo.processIdentifier
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return objects.compactMap { object in
            guard let pid = get(object, address(kAudioProcessPropertyPID), pid_t(0)), pid != me,
                  let app = owningApp(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID), regular: regular),
                  let bundleID = app.bundleIdentifier else { return nil }
            return AudioProcess(object: object, bundleID: bundleID, name: app.localizedName ?? bundleID,
                                isRunningInput: bool(object, address(kAudioProcessPropertyIsRunningInput)),
                                isRunningOutput: bool(object, address(kAudioProcessPropertyIsRunningOutput)))
        }
    }

    /// Regular apps currently capturing audio input.
    static func micUsers() -> [MicUser] {
        var users: [MicUser] = []
        for process in audioProcesses() where process.isRunningInput {
            let user = MicUser(bundleID: process.bundleID, name: process.name)
            if !users.contains(user) { users.append(user) }
        }
        return users
    }

    /// The regular (Dock) app for a pid or bundle ID, walking up from helper processes.
    private static func owningApp(pid: pid_t, bundleID: String?, regular: [NSRunningApplication]) -> NSRunningApplication? {
        if let app = regular.first(where: { $0.processIdentifier == pid }) { return app }
        if let bundleID {
            // "com.google.Chrome.helper" → "com.google.Chrome"
            if let app = regular.first(where: { $0.bundleIdentifier.map { bundleID.hasPrefix($0) } ?? false }) { return app }
        }
        var parent = pid
        for _ in 0..<4 {
            parent = parentPID(of: parent)
            guard parent > 1 else { break }
            if let app = regular.first(where: { $0.processIdentifier == parent }) { return app }
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// Calls `handler` when any input device starts or stops running somewhere.
    func observeInputActivity(_ devices: [AudioDeviceInfo], _ handler: @escaping @MainActor () -> Void) {
        removeInputActivityObservers()
        for dev in devices where dev.hasInput {
            guard let id = Self.id(forUID: dev.uid) else { continue }
            var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
            if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                activityListeners.append((id, addr, block))
            }
        }
    }

    func removeInputActivityObservers() {
        for (id, addr, block) in activityListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        activityListeners = []
    }
}
