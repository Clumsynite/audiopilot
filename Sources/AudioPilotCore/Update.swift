import CryptoKit
import Foundation

/// What the download site says the newest release is (`update.json`, written by the release workflow).
/// `update.json.sig` next to it is an Ed25519 signature of these exact bytes, so the manifest and the
/// zip digest it carries can't be swapped even though ad-hoc and self-signed builds have no Apple identity.
public struct UpdateManifest: Codable, Equatable, Sendable {
    /// CFBundleShortVersionString, for display.
    public var version: String
    /// CFBundleVersion (the commit count on main), which decides what's newer.
    public var build: Int
    public var url: String
    public var sha256: String
    public var size: Int
    /// The release's CHANGELOG.md section (Markdown).
    public var notes: String
    public var published: String?
    public var minimumSystemVersion: String?

    public init(version: String, build: Int, url: String, sha256: String, size: Int, notes: String,
                published: String? = nil, minimumSystemVersion: String? = nil) {
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.notes = notes
        self.published = published
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public enum UpdateCheck: Equatable, Sendable {
    case upToDate
    case available(UpdateManifest)
    /// Couldn't tell: offline, bad signature, or a manifest that doesn't make sense. Never shown as "up to date".
    case unknown
}

public enum UpdatePolicy {
    /// Decodes and judges a fetched manifest. Only a correctly signed, newer build served over https
    /// from the manifest's own host, with a full digest, is ever offered.
    public static func evaluate(data: Data, signature: Data, publicKey: Data, manifestHost: String,
                                installedBuild: Int, system: OperatingSystemVersion) -> UpdateCheck {
        guard verify(data, signature: signature, publicKey: publicKey),
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else { return .unknown }
        return evaluate(manifest, manifestHost: manifestHost, installedBuild: installedBuild, system: system)
    }

    public static func evaluate(_ manifest: UpdateManifest, manifestHost: String, installedBuild: Int,
                                system: OperatingSystemVersion) -> UpdateCheck {
        let url = URL(string: manifest.url)
        let hex = manifest.sha256.allSatisfy { $0.isHexDigit }
        guard manifest.build > 0, manifest.sha256.count == 64, hex, url?.scheme == "https",
              url?.host?.lowercased() == manifestHost.lowercased() else { return .unknown }
        guard manifest.build > installedBuild else { return .upToDate }
        if let minimum = manifest.minimumSystemVersion.flatMap(parseVersion),
           !ProcessInfo.compare(system, atLeast: minimum) {
            return .upToDate
        }
        return .available(manifest)
    }

    public static func verify(_ data: Data, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func parseVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.compactMap { $0 }
        return OperatingSystemVersion(majorVersion: p[0], minorVersion: p.count > 1 ? p[1] : 0,
                                      patchVersion: p.count > 2 ? p[2] : 0)
    }
}

extension ProcessInfo {
    static func compare(_ v: OperatingSystemVersion, atLeast m: OperatingSystemVersion) -> Bool {
        (v.majorVersion, v.minorVersion, v.patchVersion) >= (m.majorVersion, m.minorVersion, m.patchVersion)
    }
}

/// The notes of a release as simple blocks: `### Heading` and `- item` lines (continuations folded in).
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case item(String)
        case text(String)
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.item(String(line.dropFirst(2))))
            } else if raw.hasPrefix(" "), case let .item(previous)? = out.last {
                out[out.count - 1] = .item(previous + " " + line)
            } else {
                out.append(.text(line))
            }
        }
        return out
    }
}
