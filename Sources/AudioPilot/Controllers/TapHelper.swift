import AppKit
import CoreAudio
import os
import Security

/// Per-app audio runs in a child process (this executable with `--tap-helper`) that lives only while some app
/// is rerouted. macOS lists the process that made a tap under System Audio Recording for as long as it runs,
/// so AudioPilot itself never makes one and the listing goes when the helper exits.
///
/// The helper is reachable only through the pipes it inherits: no XPC name, socket or port. It exits unless its
/// parent is AudioPilot (same signing identity), and when the pipe closes. The protocol carries routes in and
/// results out, never audio: captured sound only goes to the chosen output device.
nonisolated enum TapProtocol {
    struct Route: Codable, Equatable, Sendable {
        var bundleID: String
        var appName: String
        var processes: [AudioObjectID]
        var outputUID: String
        var gain: Float
    }

    /// The full set of routes wanted now; anything not listed is released.
    struct Request: Codable, Sendable {
        var routes: [Route]
    }

    /// Per bundle ID: nil when routed, else why not.
    struct Reply: Codable, Sendable {
        var errors: [String: String]
    }
}

/// AudioPilot's side: starts the helper on demand, sends it the wanted routes, stops it when none are left.
final class TapHelperClient {
    private var process: Process?
    private var input: FileHandle?
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "taps")
    /// Errors from the helper's last reply, by bundle ID.
    var onReply: ([String: String]) -> Void = { _ in }

    var isRunning: Bool { process?.isRunning ?? false }

    func apply(_ routes: [TapProtocol.Route]) {
        if routes.isEmpty {
            stop()
            return
        }
        if !isRunning, !start() { return }
        // The helper re-checks its sessions on every request, so keep sending while routes exist (the
        // router's one-second tick); identical requests are cheap.
        send(TapProtocol.Request(routes: routes))
    }

    func stop() {
        guard let process else { return }
        // Closing the pipe is the helper's signal to release everything and exit.
        try? input?.close()
        input = nil
        self.process = nil
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
        logger.notice("tap helper stopped")
    }

    private func start() -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--tap-helper"]
        let toHelper = Pipe(), fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        let lines = LineBuffer()
        fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for line in lines.append(data) {
                guard let reply = try? JSONDecoder().decode(TapProtocol.Reply.self, from: line) else { continue }
                DispatchQueue.main.async { self?.onReply(reply.errors) }
            }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.input = nil
                self.logger.notice("tap helper exited (\(p.terminationStatus))")
            }
        }
        do {
            try process.run()
        } catch {
            logger.error("tap helper didn't start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        self.process = process
        input = toHelper.fileHandleForWriting
        logger.notice("tap helper started")
        return true
    }

    private func send(_ request: TapProtocol.Request) {
        guard let input, var data = try? JSONEncoder().encode(request) else { return }
        data.append(UInt8(ascii: "\n"))
        do { try input.write(contentsOf: data) } catch { stop() }
    }
}

/// Splits a byte stream into lines; a read can end mid-line.
nonisolated private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(pending[pending.startIndex..<end])
            pending = pending[pending.index(after: end)...]
        }
        return lines
    }
}

/// The helper's side: reads requests from stdin, keeps a TapSession per wanted route, replies with errors.
enum TapHelperMain {
    nonisolated(unsafe) private static var sessions: [String: TapSession] = [:]
    nonisolated(unsafe) private static var failed: [String: (key: String, at: Date)] = [:]
    private static let retryDelay: TimeInterval = 15

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard parentIsAudioPilot() else {
            FileHandle.standardError.write(Data("--tap-helper is only started by AudioPilot itself.\n".utf8))
            exit(64)
        }
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let request = try? JSONDecoder().decode(TapProtocol.Request.self, from: Data(line.utf8)) else { continue }
                DispatchQueue.main.async { reply(apply(request.routes)) }
            }
            // Pipe closed: AudioPilot stopped the helper or quit. Hand every app back before exiting.
            DispatchQueue.main.async {
                sessions.values.forEach { $0.stop() }
                exit(0)
            }
        }
        dispatchMain()
    }

    private static func apply(_ routes: [TapProtocol.Route]) -> [String: String] {
        let now = Date()
        var errors: [String: String] = [:]
        let wanted = Set(routes.map(\.bundleID))
        for bundleID in sessions.keys where !wanted.contains(bundleID) {
            sessions.removeValue(forKey: bundleID)?.stop()
        }
        for route in routes {
            if let session = sessions[route.bundleID], session.processes == route.processes,
               session.outputUID == route.outputUID, session.isAlive {
                session.setGain(route.gain)
                continue
            }
            sessions.removeValue(forKey: route.bundleID)?.stop()
            let key = "\(route.processes)|\(route.outputUID)"
            if let failure = failed[route.bundleID], failure.key == key, now.timeIntervalSince(failure.at) < retryDelay {
                errors[route.bundleID] = "Couldn't route; retrying shortly"
                continue
            }
            do {
                sessions[route.bundleID] = try TapSession(processes: route.processes, outputUID: route.outputUID,
                                                          name: "AudioPilot – \(route.appName)", gain: route.gain)
                failed[route.bundleID] = nil
            } catch {
                failed[route.bundleID] = (key, now)
                errors[route.bundleID] = "\(error)"
            }
        }
        return errors
    }

    private static func reply(_ errors: [String: String]) {
        guard var data = try? JSONEncoder().encode(TapProtocol.Reply(errors: errors)) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }

    /// The parent must satisfy this executable's own designated requirement: the same signing identity, or
    /// for an ad-hoc build the very same binary.
    private static func parentIsAudioPilot() -> Bool {
        var me: SecCode?, staticMe: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement else { return false }
        var parent: SecCode?
        let attributes = [kSecGuestAttributePid: getppid()] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent else { return false }
        return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
    }
}
