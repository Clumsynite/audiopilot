import AppKit
import AudioPilotCore
import Combine
import os
import Security

/// Checks the download site for a newer release, downloads and verifies it, then swaps it in for the
/// running copy and relaunches. The site's update.json is Ed25519-signed (see scripts/update-key.swift);
/// the zip must match its digest, and the new app must carry the running copy's signing identity.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(UpdateManifest, Double)
        /// Downloaded, verified and unpacked; `install()` swaps it in.
        case ready(UpdateManifest, URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The notes of the release now running, once after it was installed by `install()`.
    @Published private(set) var justUpdated: (version: String, notes: String)?

    static let checkInterval: TimeInterval = 6 * 3600
    static let offline = "Couldn't reach the update site."

    private let feedURL: URL?
    private let publicKey: Data?
    private let installedBuild: Int
    private let installedVersion: String
    private let dryRun: Bool
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "update")
    private let defaults = UserDefaults.standard
    private lazy var session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return config
    }())

    init(dryRun: Bool, bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        feedURL = (info["APUpdateURL"] as? String).flatMap(URL.init(string:))
        publicKey = (info["APUpdatePublicKey"] as? String).flatMap { Data(base64Encoded: $0) }
        installedBuild = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        installedVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        self.dryRun = dryRun
        if let saved = defaults.dictionary(forKey: Keys.installed), saved["build"] as? Int == installedBuild,
           let notes = saved["notes"] as? String {
            justUpdated = (installedVersion, notes)
        }
    }

    /// Only a bundled release build with a feed and key configured checks; `swift run` and dry runs never do.
    var enabled: Bool {
        feedURL != nil && publicKey != nil && installedBuild > 0 && !dryRun && Bundle.main.bundleURL.pathExtension == "app"
    }

    var version: String { installedVersion }

    var lastChecked: Date? { defaults.object(forKey: Keys.lastChecked) as? Date }

    /// Checks shortly after launch and then hourly, each time only if the last check is `checkInterval` old.
    /// `isOn`: check on a schedule. `autoInstall`: then download, and install once `isQuiet` (or at quit).
    func startAutomaticChecks(isOn: @escaping () -> Bool, autoInstall: @escaping () -> Bool, isQuiet: @escaping () -> Bool) {
        guard enabled else { return }
        autoCheckOn = isOn
        autoInstallOn = autoInstall
        self.isQuiet = isQuiet
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.autoCheck() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoCheck() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var autoCheckOn: () -> Bool = { false }
    private var autoInstallOn: () -> Bool = { false }
    private var isQuiet: () -> Bool = { false }
    private var quietTimer: Timer?

    private func autoCheck() {
        guard autoCheckOn(), Date().timeIntervalSince(lastChecked ?? .distantPast) >= Self.checkInterval else { return }
        check()
    }

    /// Automatic updates move on by themselves: download what's found, then install when nothing would be interrupted.
    private func advance() {
        guard autoInstallOn() else { return }
        switch state {
        case .available: download()
        case .ready: installWhenQuiet()
        default: break
        }
    }

    private func installWhenQuiet() {
        quietTimer?.invalidate()
        if isQuiet() {
            install()
            return
        }
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.installWhenQuiet() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    /// At quit, a downloaded update replaces this copy without relaunching (when automatic updates are on).
    func installOnQuit() {
        guard autoInstallOn(), case .ready = state else { return }
        startInstaller(relaunch: false)
    }

    func check() {
        guard enabled, let feedURL, let publicKey else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        Task {
            let result: UpdateCheck
            do {
                async let manifest = fetch(feedURL)
                async let signature = fetch(feedURL.appendingPathExtension("sig"))
                let (data, sigText) = try await (manifest, signature)
                let sig = Data(base64Encoded: String(decoding: sigText, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()
                result = UpdatePolicy.evaluate(data: data, signature: sig, publicKey: publicKey,
                                               manifestHost: feedURL.host ?? "", installedBuild: installedBuild,
                                               system: ProcessInfo.processInfo.operatingSystemVersion)
            } catch {
                logger.notice("check failed: \(error.localizedDescription, privacy: .public)")
                result = .unknown
            }
            switch result {
            case let .available(manifest):
                defaults.set(Date(), forKey: Keys.lastChecked)
                state = .available(manifest)
                advance()
            case .upToDate:
                defaults.set(Date(), forKey: Keys.lastChecked)
                state = .upToDate
            case .unknown:
                state = .failed(Self.offline)
            }
        }
    }

    func download() {
        guard case let .available(manifest) = state, let url = URL(string: manifest.url) else { return }
        state = .downloading(manifest, 0)
        Task {
            do {
                let app = try await fetchAndUnpack(manifest, from: url)
                state = .ready(manifest, app)
                advance()
            } catch {
                logger.error("update failed: \(String(describing: error), privacy: .public)")
                state = .failed(String(describing: error))
            }
        }
    }

    /// Quits, lets a small script replace this copy with the new one, and relaunches it.
    func install() {
        guard startInstaller(relaunch: true) else { return }
        NSApp.terminate(nil)
    }

    @discardableResult
    private func startInstaller(relaunch: Bool) -> Bool {
        guard case let .ready(manifest, newApp) = state else { return false }
        quietTimer?.invalidate()
        let target = Bundle.main.bundleURL
        if let problem = Self.installProblem(target) {
            state = .failed(problem)
            return false
        }
        let script = newApp.deletingLastPathComponent().appendingPathComponent("install.sh")
        do {
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path,
                                 relaunch ? "1" : "0"]
            try process.run()
        } catch {
            state = .failed("Couldn't start the installer: \(error.localizedDescription)")
            return false
        }
        defaults.set(["build": manifest.build, "notes": manifest.notes], forKey: Keys.installed)
        return true
    }

    func dismissJustUpdated() {
        justUpdated = nil
        defaults.removeObject(forKey: Keys.installed)
    }

    func openDownloadPage() {
        guard let feedURL, let page = URL(string: "/", relativeTo: feedURL) else { return }
        NSWorkspace.shared.open(page)
    }

    // MARK: Steps

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The update site answered with an error.") }
        return data
    }

    private func fetchAndUnpack(_ manifest: UpdateManifest, from url: URL) async throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techenable.audiopilot/Update")
        // One update at a time, so failed attempts never pile up.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let progress = ProgressRelay { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(manifest, fraction)
            }
        }
        let (temp, response) = try await session.download(from: url, delegate: progress)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download failed. Try again.") }
        let zip = dir.appendingPathComponent("AudioPilot.zip")
        try FileManager.default.moveItem(at: temp, to: zip)

        guard try UpdatePolicy.sha256(of: zip) == manifest.sha256.lowercased() else {
            throw Failure("The download didn't match the published file, so it was discarded. Try again.")
        }
        let unpacked = dir.appendingPathComponent("unpacked")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("AudioPilot.app")
        try verify(app, manifest)
        try? FileManager.default.removeItem(at: zip)
        return app
    }

    /// Same app, the promised build, and a valid signature from the running copy's identity (when it has one).
    private func verify(_ app: URL, _ manifest: UpdateManifest) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              Int(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "") == manifest.build else {
            throw Failure("The download isn't the AudioPilot build it should be.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("Couldn't read the new version's signature.")
        }
        let requirement = Self.ownRequirement()
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("The new version isn't signed like this one (\(status)), so it wasn't installed.")
        }
    }

    /// The running copy's designated requirement, unless it's ad-hoc signed (then the requirement is just
    /// its own hash, which no other build can meet, and the signed manifest is the check).
    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func installProblem(_ target: URL) -> String? {
        if target.path.contains("/AppTranslocation/") {
            return "Move AudioPilot to the Applications folder, open it from there, then update."
        }
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent), FileManager.default.isWritableFile(atPath: target.path) else {
            return "AudioPilot can't replace itself in \(parent). Download the update from the website instead."
        }
        return nil
    }

    // Waits for AudioPilot to quit, swaps the bundles (putting the old one back if the move fails), relaunches.
    private static let installScript = """
    #!/bin/sh
    pid="$1"; new="$2"; target="$3"; relaunch="$4"; old="$(dirname "$new")/old.app"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    rm -rf "$old"
    if mv "$target" "$old"; then
      if mv "$new" "$target"; then rm -rf "$old"; else mv "$old" "$target"; fi
    fi
    xattr -dr com.apple.quarantine "$target" 2>/dev/null
    [ "$relaunch" = 1 ] && open "$target"
    """

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.terminationHandler = { p in
                p.terminationStatus == 0 ? done.resume() : done.resume(throwing: Failure("Couldn't unpack the update."))
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }

    private enum Keys {
        static let lastChecked = "updateLastChecked"
        static let installed = "updateInstalled"
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// Download progress from URLSession's delegate callbacks.
private final class ProgressRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
