import AppKit
import AudioPilotCore
import CoreAudio
import os

/// Applies per-app output and volume settings with process taps. A tap only runs while its app is
/// playing (plus a short grace period), so idle apps don't keep an output device busy.
final class AppAudioRouter {
    /// An app with audio clients right now, for the panel and Settings.
    struct App: Equatable, Identifiable {
        let bundleID: String
        let name: String
        let isPlaying: Bool
        var id: String { bundleID }
    }

    static let idleGrace: TimeInterval = 20
    private static let retryDelay: TimeInterval = 15

    private let dryRun: Bool
    private var sessions: [String: TapSession] = [:]
    private var lastPlaying: [String: Date] = [:]
    /// Last failed setup per app (processes + device), so a broken route isn't retried every second.
    private var failed: [String: (key: String, at: Date)] = [:]
    private var timer: Timer?
    private var ticks = 0
    /// Routes a dry run would have made, so each is printed once.
    private var dryRunRoutes: [String: String] = [:]
    private var listener: AudioObjectPropertyListenerBlock?
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "taps")

    /// Wired by the AppDelegate: current settings, system output and devices.
    var context: () -> (settings: [AppAudioSetting], defaultOutput: String?, connected: [AudioDeviceInfo]) = { ([], nil, []) }
    var onChange: () -> Void = {}

    private(set) var apps: [App] = []
    /// Why an app's setting isn't applied right now, by bundle ID.
    private(set) var problems: [String: String] = [:]
    /// Bundle IDs currently rerouted.
    var routed: Set<String> { Set(sessions.keys) }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    func start() {
        guard Self.isSupported else { return }
        // New or departing audio clients; the timer covers apps starting and stopping playback.
        var addr = AudioHAL.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioHAL.system, &addr, DispatchQueue.main, block) == noErr {
            listener = block
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reconcile()
    }

    /// Every second while something is configured; otherwise just keeps the app list fresh.
    private func tick() {
        ticks += 1
        if !context().settings.isEmpty || ticks % 3 == 0 { reconcile() }
    }

    /// Ends every reroute so apps play normally again.
    func stop() {
        timer?.invalidate()
        timer = nil
        if let listener {
            var addr = AudioHAL.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioHAL.system, &addr, DispatchQueue.main, listener)
        }
        listener = nil
        sessions.values.forEach { $0.stop() }
        sessions = [:]
    }

    func reconcile() {
        guard Self.isSupported else { return }
        let (settings, defaultOutput, connected) = context()
        let now = Date()
        let processes = AudioHAL.audioProcesses()
        let permission = AudioCapturePermission.status

        var problems: [String: String] = [:]
        var wanted: Set<String> = []
        for setting in settings {
            let mine = processes.filter { $0.bundleID == setting.bundleID }
            if mine.contains(where: \.isRunningOutput) { lastPlaying[setting.bundleID] = now }
            guard !mine.isEmpty, let last = lastPlaying[setting.bundleID],
                  now.timeIntervalSince(last) < Self.idleGrace else { continue }

            switch AppAudioPlan.outcome(for: setting, defaultOutput: defaultOutput, connected: connected) {
            case .untouched:
                continue
            case let .unsupported(reason):
                problems[setting.bundleID] = reason
            case let .route(route):
                guard permission != .denied else {
                    problems[setting.bundleID] = "Needs System Audio Recording permission"
                    continue
                }
                wanted.insert(setting.bundleID)
                apply(setting, route, processes: mine.map(\.object).sorted(), now: now, problems: &problems)
            }
        }
        for bundleID in sessions.keys where !wanted.contains(bundleID) {
            sessions.removeValue(forKey: bundleID)?.stop()
            log("released \(bundleID)")
        }
        lastPlaying = lastPlaying.filter { now.timeIntervalSince($0.value) < Self.idleGrace }

        var apps: [App] = []
        for process in processes where !apps.contains(where: { $0.bundleID == process.bundleID }) {
            let playing = processes.contains { $0.bundleID == process.bundleID && $0.isRunningOutput }
            apps.append(App(bundleID: process.bundleID, name: process.name, isPlaying: playing))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if apps != self.apps || problems != self.problems {
            self.apps = apps
            self.problems = problems
            onChange()
        }
    }

    private func apply(_ setting: AppAudioSetting, _ route: AppAudioPlan.Route, processes: [AudioObjectID],
                       now: Date, problems: inout [String: String]) {
        let bundleID = setting.bundleID
        if let session = sessions[bundleID], session.processes == processes, session.outputUID == route.outputUID,
           session.isAlive {
            session.setGain(route.gain)
            return
        }
        // A new helper process or a different device: rebuild the route.
        sessions.removeValue(forKey: bundleID)?.stop()
        let key = "\(processes)|\(route.outputUID)"
        if let failure = failed[bundleID], failure.key == key, now.timeIntervalSince(failure.at) < Self.retryDelay {
            problems[bundleID] = problems[bundleID] ?? self.problems[bundleID]
            return
        }
        if dryRun {
            let line = "route \(bundleID) → \(route.outputUID) gain \(route.gain)"
            if dryRunRoutes[bundleID] != line { print("DRYRUN \(line)") }
            dryRunRoutes[bundleID] = line
            return
        }
        do {
            sessions[bundleID] = try TapSession(processes: processes, outputUID: route.outputUID,
                                                name: "AudioPilot – \(setting.appName)", gain: route.gain)
            failed[bundleID] = nil
            log("routed \(bundleID) → \(route.outputUID) gain \(route.gain)")
        } catch {
            failed[bundleID] = (key, now)
            problems[bundleID] = "\(error)"
            log("route \(bundleID) failed: \(error)")
        }
    }

    private func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
