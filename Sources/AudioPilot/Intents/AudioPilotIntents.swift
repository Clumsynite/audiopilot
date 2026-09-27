import AppIntents
import AudioPilotCore

// App Intents: these become Spotlight actions (type "Mute Microphone" and run it in place)
// and actions in the Shortcuts app. They run inside AudioPilot's process.

/// Lets intents reach the running app's model. If macOS launched AudioPilot just to run an intent,
/// the model appears a moment later, so intents wait briefly for it.
@MainActor
enum IntentBridge {
    static weak var model: AppModel?

    static func awaitModel() async throws -> AppModel {
        for _ in 0..<50 {
            if let model { return model }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntentError.notReady
    }
}

nonisolated enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, deviceNotConnected, nothingToSwitch

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "AudioPilot isn't ready yet. Try again in a moment."
        case .deviceNotConnected: "That device isn't connected."
        case .nothingToSwitch: "There's no other device to switch to."
        }
    }
}

// MARK: - Mute

nonisolated struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Microphone Mute"
    static let description = IntentDescription("Mutes or unmutes every microphone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        model.toggleMute(feedback: true)
        return .result(dialog: model.mute.isMuted ? "Microphone muted" : "Microphone on")
    }
}

nonisolated struct MuteMicrophoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Microphone"
    static let description = IntentDescription("Mutes every microphone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        model.setMuted(true, feedback: true)
        return .result(dialog: "Microphone muted")
    }
}

nonisolated struct UnmuteMicrophoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute Microphone"
    static let description = IntentDescription("Unmutes the microphones AudioPilot muted.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        model.setMuted(false, feedback: true)
        return .result(dialog: "Microphone on")
    }
}

// MARK: - Devices

nonisolated struct AudioDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audio Device"
    static let defaultQuery = AudioDeviceQuery()

    /// `output:<uid>` or `input:<uid>` (a `DeviceShortcut` key).
    let id: String
    let name: String
    let isOutput: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: isOutput ? "Output" : "Input")
    }
}

nonisolated struct AudioDeviceQuery: EntityQuery, EntityStringQuery {
    @MainActor
    private func all() async throws -> [AudioDeviceEntity] {
        let model = try await IntentBridge.awaitModel()
        return [Direction.output, .input].flatMap { dir in
            model.devices(dir).map {
                AudioDeviceEntity(id: DeviceShortcut.device(dir, $0.uid).key, name: model.label($0), isOutput: dir == .output)
            }
        }
    }

    func entities(for identifiers: [String]) async throws -> [AudioDeviceEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AudioDeviceEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [AudioDeviceEntity] {
        try await all()
    }
}

struct SwitchDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Audio Device"
    static let description = IntentDescription("Switches the output or input to a connected device.")

    @Parameter(title: "Device")
    var device: AudioDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$device)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        guard let shortcut = DeviceShortcut(key: device.id), model.perform(shortcut) else {
            throw IntentError.deviceNotConnected
        }
        return .result(dialog: "\(device.isOutput ? "Output" : "Input"): \(device.name)")
    }
}

nonisolated struct NextOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Output Device"
    static let description = IntentDescription("Switches to the next connected speaker or headphones.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        guard model.perform(.next(.output)) else { throw IntentError.nothingToSwitch }
        return .result(dialog: "Output: \(model.current(.output)?.name ?? "switched")")
    }
}

nonisolated struct NextInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Input Device"
    static let description = IntentDescription("Switches to the next connected microphone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        guard model.perform(.next(.input)) else { throw IntentError.nothingToSwitch }
        return .result(dialog: "Input: \(model.current(.input)?.name ?? "switched")")
    }
}

// MARK: - Options

struct SetAutoSwitchIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Automatic Device Switching"
    static let description = IntentDescription("Turns automatic device switching on or off.")

    @Parameter(title: "Enabled", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn automatic switching \(\.$enabled)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        model.setAutoSwitch(enabled)
        return .result(dialog: enabled ? "Automatic switching on" : "Automatic switching off")
    }
}

nonisolated struct TogglePushToTalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Push-to-Talk"
    static let description = IntentDescription("Switches the mute shortcut between toggle and push-to-talk.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.awaitModel()
        model.perform("mode.toggle")
        return .result(dialog: model.prefs.hotkeyMode == .pushToTalk ? "Push-to-talk on" : "Toggle mode on")
    }
}

nonisolated struct OpenAudioPilotPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Open AudioPilot"
    static let description = IntentDescription("Opens the AudioPilot panel.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentBridge.awaitModel()
        model.openPanel(false)
        return .result()
    }
}

// MARK: - Spotlight / Siri phrases

nonisolated struct AudioPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleMuteIntent(),
                    phrases: ["Toggle mute in \(.applicationName)", "Toggle \(.applicationName)"],
                    shortTitle: "Toggle Mute", systemImageName: "mic.slash")
        AppShortcut(intent: MuteMicrophoneIntent(),
                    phrases: ["Mute microphone with \(.applicationName)", "Mute mic in \(.applicationName)"],
                    shortTitle: "Mute Microphone", systemImageName: "mic.slash.fill")
        AppShortcut(intent: UnmuteMicrophoneIntent(),
                    phrases: ["Unmute microphone with \(.applicationName)", "Unmute mic in \(.applicationName)"],
                    shortTitle: "Unmute Microphone", systemImageName: "mic.fill")
        AppShortcut(intent: SwitchDeviceIntent(),
                    phrases: ["Switch audio device with \(.applicationName)", "Switch to \(\.$device) with \(.applicationName)"],
                    shortTitle: "Switch Device", systemImageName: "hifispeaker.2")
        AppShortcut(intent: NextOutputIntent(),
                    phrases: ["Next output device in \(.applicationName)"],
                    shortTitle: "Next Output", systemImageName: "speaker.wave.2")
        AppShortcut(intent: NextInputIntent(),
                    phrases: ["Next input device in \(.applicationName)"],
                    shortTitle: "Next Input", systemImageName: "mic")
        AppShortcut(intent: SetAutoSwitchIntent(),
                    phrases: ["Set automatic switching in \(.applicationName)"],
                    shortTitle: "Automatic Switching", systemImageName: "arrow.triangle.2.circlepath")
    }
}
