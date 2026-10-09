import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// Per-app audio's tap process, started by AudioPilot only (see TapHelper.swift).
if CommandLine.arguments.contains("--tap-helper") {
    TapHelperMain.run()
}

let flags = Flags()

if flags.listDevices {
    print(DeviceTable.render(AudioHAL(dryRun: true)))
    exit(0)
}

if CommandLine.arguments.contains("--mic-users") {
    let users = AudioHAL.micUsers()
    print(users.isEmpty ? "No app is using the microphone." : users.map { "\($0.name) (\($0.bundleID))" }.joined(separator: "\n"))
    exit(0)
}

if CommandLine.arguments.contains("--app-audio") {
    let processes = AudioHAL.audioProcesses()
    let apps = Dictionary(grouping: processes, by: \.bundleID).sorted { $0.key < $1.key }
    print(apps.isEmpty ? "No app has audio clients." : apps.map { id, procs in
        "\(procs[0].name) (\(id)): \(procs.count) process\(procs.count == 1 ? "" : "es")\(procs.contains(where: \.isRunningOutput) ? ", playing" : "")"
    }.joined(separator: "\n"))
    exit(0)
}

// Plays one app through a process tap for a few seconds at the given volume, then hands it back.
// Needs System Audio Recording permission (macOS asks the first time).
if let i = CommandLine.arguments.firstIndex(of: "--test-tap"), CommandLine.arguments.count > i + 1 {
    let args = CommandLine.arguments
    let bundleID = args[i + 1]
    let volume = args.count > i + 2 ? Float(args[i + 2]) ?? 0.3 : 0.3
    let seconds = args.count > i + 3 ? Double(args[i + 3]) ?? 6 : 6
    let processes = AudioHAL.audioProcesses().filter { $0.bundleID == bundleID }
    guard !processes.isEmpty, let output = AudioHAL(dryRun: true).defaultUID(.output) else {
        print("\(bundleID) has no audio clients (or there's no output device).")
        exit(1)
    }
    print("permission: \(AudioCapturePermission.status), \(processes.count) process(es), output \(output)")
    do {
        let session = try TapSession(processes: processes.map(\.object).sorted(), outputUID: output,
                                     name: "AudioPilot test", gain: volume * volume)
        for second in 1...Int(seconds) {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            print("\(second)s alive=\(session.isAlive) peak=\(String(format: "%.3f", session.takePeak()))")
        }
        session.stop()
        print("released")
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}

// Asks the download site what's newest, the same way the app does, and prints the answer.
if CommandLine.arguments.contains("--check-update") {
    let updater = Updater(dryRun: false)
    guard updater.enabled else {
        print("Updates are off for this build (needs a bundled release build with a feed and key).")
        exit(1)
    }
    updater.check()
    while updater.state == .checking { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print("installed \(updater.version): \(updater.state)")
    exit(0)
}

if flags.testMute {
    guard flags.dryRun else {
        print("--test-mute requires --dry-run")
        exit(2)
    }
    MuteController.printMethods(AudioHAL(dryRun: true).devices())
    exit(0)
}

// NSApplication.delegate is weak, so keep a strong reference for the app's lifetime.
let delegate = AppDelegate(flags: flags)
let app = NSApplication.shared
app.delegate = delegate
app.run()
