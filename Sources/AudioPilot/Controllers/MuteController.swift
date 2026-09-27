import CoreAudio
import Foundation
import AudioPilotCore
import os

/// Mutes every physical input, keeps it muted across device switches, wake and outside changes,
/// and persists what it did so a relaunch (or crash) never loses the user's real volumes.
final class MuteController {
    static let remuteCap = 3
    static let remuteWindow: TimeInterval = 10
    static let selfWriteGrace: TimeInterval = 0.5

    private(set) var state: MuteState
    /// UID → name of inputs that can't be muted (no mute/volume control, or the write didn't stick).
    private(set) var unmutable: [String: String] = [:]
    private(set) var cantHold: Set<String> = []

    let store: JSONStore
    let dryRun: Bool
    private var devices: [AudioDeviceInfo] = []
    private var observers: [() -> Void] = []
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var selfWriteUntil: [String: Date] = [:]
    private var remutes: [String: [Date]] = [:]
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "mute")
    /// Called when another app mutes (true) or unmutes (false) an input while AudioPilot isn't muting.
    var onExternalChange: ((AudioDeviceInfo, Bool) -> Void)?
    private var observedSilent: [String: Bool] = [:]

    var isMuted: Bool { state.isMuted }

    init(store: JSONStore, dryRun: Bool) {
        self.store = store
        self.dryRun = dryRun
        state = store.load(MuteState.self, name: "mute-state").value ?? MuteState()
    }

    func observe(_ callback: @escaping () -> Void) {
        observers.append(callback)
    }

    static func physicalInputs(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        devices.filter { $0.hasInput && $0.isAlive && $0.transport != .virtual && $0.transport != .aggregate }
    }

    /// `--dry-run --test-mute`: report the method each input would use, without writing anything.
    static func printMethods(_ devices: [AudioDeviceInfo]) {
        for dev in physicalInputs(devices) {
            let method = AudioHAL.id(forUID: dev.uid).flatMap(MuteDriver.method(for:))
            print("DRYRUN mute-method \(dev.uid) \(method?.rawValue ?? "unmutable")")
        }
    }

    func start(devices: [AudioDeviceInfo], pushToTalk: Bool) {
        self.devices = devices
        rebuildListeners()
        if pushToTalk { state.isMuted = true }
        if state.isMuted { muteAll() } else { restoreLeftovers() }
        notify()
    }

    func toggle() {
        setMuted(!state.isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard muted != state.isMuted else { return }
        if muted {
            state.isMuted = true
            muteAll()
        } else {
            // Clear the flag before restoring so our own restore doesn't trigger a re-mute.
            state.isMuted = false
            restoreLeftovers()
        }
        save()
        notify()
    }

    func devicesChanged(_ devices: [AudioDeviceInfo]) {
        self.devices = devices
        rebuildListeners()
        if state.isMuted { muteAll() } else { restoreLeftovers() }
        notify()
    }

    func wake() {
        if state.isMuted { muteAll() }
        notify()
    }

    func removeListeners() {
        for (id, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        listeners = []
    }

    // MARK: - Internals

    private func muteAll() {
        for dev in Self.physicalInputs(devices) {
            if dryRun {
                print("DRYRUN mute \(dev.uid)")
                continue
            }
            guard let id = AudioHAL.id(forUID: dev.uid) else { continue }
            if let existing = state.devices[dev.uid], MuteDriver.isHeld(id, existing) { continue }
            selfWriteUntil[dev.uid] = Date().addingTimeInterval(Self.selfWriteGrace)
            if let record = MuteDriver.mute(id, existing: state.devices[dev.uid]) {
                state.devices[dev.uid] = record
                unmutable[dev.uid] = nil
            } else {
                unmutable[dev.uid] = dev.name
                logger.error("can't mute \(dev.name, privacy: .public)")
            }
        }
        save()
    }

    /// Unmutes devices AudioPilot muted that are connected now; records for absent devices are kept
    /// so their saved volume is restored when they come back.
    private func restoreLeftovers() {
        guard !state.devices.isEmpty else { return }
        let connected = Set(devices.map(\.uid))
        for (uid, record) in state.devices where connected.contains(uid) {
            if dryRun {
                print("DRYRUN unmute \(uid)")
                continue
            }
            if let id = AudioHAL.id(forUID: uid) {
                selfWriteUntil[uid] = Date().addingTimeInterval(Self.selfWriteGrace)
                MuteDriver.unmute(id, record)
                observedSilent[uid] = Self.isSilent(id)
            }
            state.devices[uid] = nil
        }
        unmutable = [:]
        cantHold = []
        save()
    }

    private func rebuildListeners() {
        removeListeners()
        guard !dryRun else { return }
        for dev in Self.physicalInputs(devices) {
            guard let id = AudioHAL.id(forUID: dev.uid) else { continue }
            let uid = dev.uid
            observedSilent[uid] = Self.isSilent(id)
            let els = [kAudioObjectPropertyElementMain] + MuteDriver.channelElements(id)
            for el in els {
                for addr in [MuteDriver.muteAddress(el), MuteDriver.volumeAddress(el)] where AudioHAL.has(id, addr) {
                    var a = addr
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.externalChange(uid) }
                    }
                    if AudioObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main, block) == noErr {
                        listeners.append((id, addr, block))
                    }
                }
            }
        }
    }

    /// Whether the device is currently silenced by its mute switch or a zero input volume.
    private static func isSilent(_ id: AudioDeviceID) -> Bool {
        (MuteDriver.readMute(id) ?? false) || (MuteDriver.readVolume(id).map { $0 < 0.001 } ?? false)
    }

    private func externalChange(_ uid: String) {
        if let until = selfWriteUntil[uid], Date() < until { return }
        if !state.isMuted {
            guard let id = AudioHAL.id(forUID: uid), let dev = devices.first(where: { $0.uid == uid }) else { return }
            let silent = Self.isSilent(id)
            if observedSilent[uid] != silent {
                observedSilent[uid] = silent
                onExternalChange?(dev, silent)
            }
            return
        }
        guard let record = state.devices[uid], let id = AudioHAL.id(forUID: uid) else { return }
        guard !MuteDriver.isHeld(id, record) else { return }
        let now = Date()
        var times = (remutes[uid] ?? []).filter { now.timeIntervalSince($0) < Self.remuteWindow }
        guard times.count < Self.remuteCap else {
            if cantHold.insert(uid).inserted {
                logger.error("\(uid, privacy: .public) keeps unmuting; giving up")
                notify()
            }
            return
        }
        times.append(now)
        remutes[uid] = times
        selfWriteUntil[uid] = now.addingTimeInterval(Self.selfWriteGrace)
        _ = MuteDriver.mute(id, existing: record)
        logger.notice("re-muted \(uid, privacy: .public) after outside change")
    }

    private func save() {
        guard !dryRun else { return }
        store.save(state, name: "mute-state")
    }

    private func notify() {
        observers.forEach { $0() }
    }
}
