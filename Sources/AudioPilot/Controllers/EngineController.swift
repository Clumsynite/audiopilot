import Foundation
import AudioPilotCore
import os

/// Imperative shell around the pure `Engine`: feeds it HAL/app events and executes its actions.
final class EngineController {
    private(set) var engine: Engine
    let hal: AudioHAL
    let store: JSONStore
    let dryRun: Bool
    private(set) var recent: [String] = []
    private var observers: [() -> Void] = []
    private var burst: [DispatchWorkItem] = []
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "engine")
    /// Called after an automatic (not user-picked) switch succeeds.
    var onAutoSwitch: ((Direction, String) -> Void)?
    /// Called for each device that appeared (true) or went away (false).
    var onDeviceConnection: ((AudioDeviceInfo, Bool) -> Void)?
    private var handlingUserPick = false

    var state: EngineState { engine.state }
    var prefs: Preferences { engine.state.prefs }

    init(prefs: Preferences, hal: AudioHAL, store: JSONStore, dryRun: Bool) {
        self.engine = Engine(prefs: prefs)
        self.hal = hal
        self.store = store
        self.dryRun = dryRun
    }

    func observe(_ callback: @escaping () -> Void) {
        observers.append(callback)
    }

    func start(prefsExisted: Bool) {
        send(.start(devices: hal.devices(), defaults: hal.defaults(), prefsExisted: prefsExisted))
    }

    /// Any CoreAudio change: re-read the device list first so topology is known before a default change.
    func halChanged(devices: [AudioDeviceInfo]) {
        if devices != engine.state.connected {
            let before = engine.state.connected
            send(.devicesChanged(devices))
            let oldUIDs = Set(before.map(\.uid)), newUIDs = Set(devices.map(\.uid))
            devices.filter { !oldUIDs.contains($0.uid) }.forEach { onDeviceConnection?($0, true) }
            before.filter { !newUIDs.contains($0.uid) }.forEach { onDeviceConnection?($0, false) }
        }
        for dir in Direction.allCases {
            let uid = hal.defaultUID(dir)
            if uid != engine.state.current[dir] {
                send(.defaultChanged(dir, uid))
            }
        }
    }

    func send(_ event: EngineEvent) {
        if case .userPicked = event { handlingUserPick = true }
        defer { handlingUserPick = false }
        run(engine.reduce(event, now: Date()))
    }

    func editSettings(_ body: (inout Preferences) -> Void) {
        run(engine.editSettings(body))
    }

    private func run(_ actions: [EngineAction]) {
        for action in actions {
            switch action {
            case let .setDefault(dir, uid):
                if let error = hal.setDefault(dir, uid: uid) {
                    record("error: \(error)")
                    engine.clearPending(dir)
                } else {
                    record("switched \(dir.short) → \(name(uid))")
                    if !handlingUserPick { onAutoSwitch?(dir, uid) }
                }
            case let .setSystemOutput(uid):
                if let error = hal.setSystemOutput(uid: uid) { record("error: \(error)") }
            case .savePrefs:
                if dryRun { print("DRYRUN savePrefs") } else { store.save(engine.state.prefs, name: "preferences") }
            case let .log(message):
                if dryRun { print("DRYRUN \(message)") }
                logger.info("\(message, privacy: .public)")
                if !message.hasPrefix("decision") { record(message) }
            case .scheduleRetryBurst:
                burst.forEach { $0.cancel() }
                burst = [0.05, 0.35, 1.0, 2.5].map { delay in
                    let item = DispatchWorkItem { [weak self] in self?.send(.tick) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                    return item
                }
            case let .scheduleTick(delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.send(.tick) }
            }
        }
        observers.forEach { $0() }
    }

    private func record(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        recent.insert("\(stamp)  \(line)", at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        logger.notice("\(line, privacy: .public)")
    }

    func name(_ uid: String) -> String {
        if let custom = engine.state.prefs.deviceSettings[uid]?.customName { return custom }
        return engine.state.connected.first { $0.uid == uid }?.name ?? engine.state.prefs.knownDevices[uid]?.name ?? uid
    }
}
