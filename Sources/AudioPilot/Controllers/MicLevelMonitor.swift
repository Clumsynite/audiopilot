import AVFoundation
import os

/// Live input level for the panel meter. Opens the default input only while the panel is open and
/// the mic isn't muted (a muted device only delivers silence), and needs microphone permission.
final class MicLevelMonitor {
    private var engine: AVAudioEngine?
    var onLevel: (Float) -> Void = { _ in }
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "meter")

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Asks for microphone access if it hasn't been decided yet.
    static func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in done(granted) }
        }
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        guard engine == nil, Self.authorized else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.rms(buffer)
            Task { @MainActor in self?.onLevel(level) }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            logger.error("meter start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onLevel(0)
    }

    /// RMS of the first channel mapped to 0…1 on a -60…0 dB scale.
    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (db + 60) / 60))
    }
}

/// AirPods "press stem to mute" (macOS 14+). The system delivers the press to apps using the mic,
/// so this is experimental: it works best while a call app (or the level meter) has the mic open.
enum AirPodsMute {
    static func enable(_ onToggle: @escaping @MainActor (Bool) -> Void) {
        guard #available(macOS 14.0, *) else { return }
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { muted in
                Task { @MainActor in onToggle(muted) }
                return true
            }
        } catch {
            Logger(subsystem: "com.techenable.audiopilot", category: "airpods")
                .error("stem mute unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func disable() {
        guard #available(macOS 14.0, *) else { return }
        try? AVAudioApplication.shared.setInputMuteStateChangeHandler(nil)
    }

    /// Keeps the system's idea of our mute state in line with AudioPilot's, so the next press flips it.
    static func sync(_ muted: Bool) {
        guard #available(macOS 14.0, *) else { return }
        try? AVAudioApplication.shared.setInputMuted(muted)
    }
}
