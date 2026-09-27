import Foundation
import AudioPilotCore
import os

/// Runs the user's connect/disconnect commands for a device.
enum ScriptRunner {
    private nonisolated static let logger = Logger(subsystem: "com.techenable.audiopilot", category: "scripts")

    static func run(for dev: AudioDeviceInfo, connected: Bool, settings: DeviceSettings?, label: String, dryRun: Bool) {
        guard let command = connected ? settings?.onConnect : settings?.onDisconnect, !command.isEmpty else { return }
        if dryRun {
            print("DRYRUN script \(connected ? "connect" : "disconnect") \(dev.uid): \(command)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["AUDIOPILOT_DEVICE_NAME"] = label
        env["AUDIOPILOT_DEVICE_UID"] = dev.uid
        env["AUDIOPILOT_EVENT"] = connected ? "connected" : "disconnected"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let name = label
        process.terminationHandler = { p in
            logger.notice("script for \(name, privacy: .public) exited \(p.terminationStatus)")
        }
        do { try process.run() } catch {
            logger.error("script for \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
