import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

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
