import AppKit
import AudioPilotCore

/// Tracks running regular apps and the frontmost app for per-app rules.
final class AppWatcher {
    private let onChange: ([RunningApp], String?) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?

    init(onChange: @escaping ([RunningApp], String?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit() }
            })
        }
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitDebounced() }
        })
        emit()
    }

    private func emitDebounced() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.emit() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func emit() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { RunningApp(bundleID: $0, launchDate: app.launchDate ?? .distantPast) } }
        onChange(running, NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
