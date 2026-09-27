import AppKit
import AudioPilotCore

/// Tracks which apps are capturing the microphone and triggers auto-mute when a call starts.
/// Device-level "is running somewhere" listeners are the trigger (per-process listeners never
/// fire on macOS 26); a slow timer is a backstop.
final class MicUsageMonitor {
    private let hal: AudioHAL
    private(set) var users: [AudioHAL.MicUser] = []
    var onChange: (_ users: [AudioHAL.MicUser], _ started: [AudioHAL.MicUser]) -> Void = { _, _ in }
    private var timer: Timer?

    init(hal: AudioHAL) {
        self.hal = hal
    }

    func start(devices: [AudioDeviceInfo]) {
        devicesChanged(devices)
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func devicesChanged(_ devices: [AudioDeviceInfo]) {
        hal.observeInputActivity(devices) { [weak self] in
            // Process state settles a moment after the device starts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
    }

    func refresh() {
        let now = AudioHAL.micUsers()
        guard now != users else { return }
        let started = now.filter { !users.contains($0) }
        users = now
        onChange(now, started)
    }
}
