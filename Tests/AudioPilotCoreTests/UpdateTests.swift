import CryptoKit
import Foundation
import Testing
@testable import AudioPilotCore

@Suite struct UpdateTests {
    let key = Curve25519.Signing.PrivateKey()
    let host = "audiopilot.example.dev"
    let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    func manifest(build: Int = 120, url: String? = nil, sha: String = String(repeating: "a", count: 64),
                  minimum: String? = "14.0") -> UpdateManifest {
        UpdateManifest(version: "0.3.0", build: build, url: url ?? "https://\(host)/AudioPilot-0.3.0.zip",
                       sha256: sha, size: 1000, notes: "", minimumSystemVersion: minimum)
    }

    func signed(_ m: UpdateManifest) throws -> (Data, Data) {
        let data = try JSONEncoder().encode(m)
        return (data, try key.signature(for: data))
    }

    @Test func offersNewerSignedBuild() throws {
        let m = manifest()
        let (data, sig) = try signed(m)
        let check = UpdatePolicy.evaluate(data: data, signature: sig, publicKey: key.publicKey.rawRepresentation,
                                          manifestHost: host, installedBuild: 100, system: macOS15)
        #expect(check == .available(m))
    }

    @Test func sameOrOlderBuildIsUpToDate() {
        #expect(UpdatePolicy.evaluate(manifest(build: 100), manifestHost: host, installedBuild: 100, system: macOS15) == .upToDate)
        #expect(UpdatePolicy.evaluate(manifest(build: 90), manifestHost: host, installedBuild: 100, system: macOS15) == .upToDate)
    }

    @Test func rejectsBadSignature() throws {
        let (data, _) = try signed(manifest())
        let other = try Curve25519.Signing.PrivateKey().signature(for: data)
        let check = UpdatePolicy.evaluate(data: data, signature: other, publicKey: key.publicKey.rawRepresentation,
                                          manifestHost: host, installedBuild: 100, system: macOS15)
        #expect(check == .unknown)
        let tampered = data + Data(" ".utf8)
        let (_, sig) = try signed(manifest())
        #expect(UpdatePolicy.evaluate(data: tampered, signature: sig, publicKey: key.publicKey.rawRepresentation,
                                      manifestHost: host, installedBuild: 100, system: macOS15) == .unknown)
    }

    @Test func rejectsOtherHostsPlainHTTPAndBadDigests() {
        for m in [manifest(url: "https://evil.example.com/AudioPilot.zip"), manifest(url: "http://\(host)/AudioPilot.zip"),
                  manifest(sha: "abc"), manifest(sha: String(repeating: "z", count: 64)), manifest(build: 0)] {
            #expect(UpdatePolicy.evaluate(m, manifestHost: host, installedBuild: 100, system: macOS15) == .unknown)
        }
    }

    @Test func skipsBuildsNeedingNewerMacOS() {
        let m = manifest(minimum: "26.1")
        #expect(UpdatePolicy.evaluate(m, manifestHost: host, installedBuild: 100, system: macOS15) == .upToDate)
    }

    @Test func notesBlocks() {
        let notes = "### Added\n- Pick the sounds in **Settings**, with a\n  button to hear each one.\n\n### Fixed\n- A bug"
        #expect(ReleaseNotes.blocks(notes) == [
            .heading("Added"), .item("Pick the sounds in **Settings**, with a button to hear each one."),
            .heading("Fixed"), .item("A bug"),
        ])
    }
}
