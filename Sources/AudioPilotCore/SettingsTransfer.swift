import Foundation

/// Settings exported to a file to back them up or move them to another Mac.
public struct SettingsExport: Codable, Equatable, Sendable {
    public static let formatName = "com.techenable.audiopilot.settings"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var preferences: Preferences

    public init(preferences: Preferences, appVersion: String?, exportedAt: Date) {
        format = Self.formatName
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.preferences = preferences
    }
}

public enum SettingsTransfer {
    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notAudioPilot
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notAudioPilot: "This file isn't an AudioPilot settings export."
            case let .newerVersion(v): "This file was exported by a newer AudioPilot (format \(v)). Update AudioPilot first."
            }
        }
    }

    /// The live settings with the active profile brought up to date, ready to write.
    public static func export(_ prefs: Preferences, appVersion: String?, now: Date) throws -> Data {
        var copy = prefs
        copy.storeActiveProfile()
        return try JSONEncoder.store.encode(SettingsExport(preferences: copy, appVersion: appVersion, exportedAt: now))
    }

    /// Reads an export (or a bare `preferences.json`) and merges it onto this Mac's settings.
    public static func importing(_ data: Data, into local: Preferences) throws -> Preferences {
        let decoder = JSONDecoder.store
        let imported: Preferences
        if let file = try? decoder.decode(SettingsExport.self, from: data) {
            guard file.format == SettingsExport.formatName else { throw ImportError.notAudioPilot }
            guard file.version <= SettingsExport.currentVersion else { throw ImportError.newerVersion(file.version) }
            imported = file.preferences
        } else if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  raw["inputPriority"] != nil || raw["outputPriority"] != nil,
                  let prefs = try? decoder.decode(Preferences.self, from: data) {
            imported = prefs
        } else {
            throw ImportError.notAudioPilot
        }
        return merge(imported, into: local)
    }

    /// Takes everything from `imported`, except what belongs to this Mac: devices it has seen
    /// (kept alongside the imported ones) and the login item, which macOS registers per machine.
    public static func merge(_ imported: Preferences, into local: Preferences) -> Preferences {
        var result = imported
        result.knownDevices = imported.knownDevices.merging(local.knownDevices) { _, mine in mine }
        result.launchAtLogin = local.launchAtLogin
        // The active profile must exist; fall back to the first one.
        if result.activeProfileID.map({ id in !result.profiles.contains { $0.id == id } }) ?? !result.profiles.isEmpty {
            result.activeProfileID = result.profiles.first?.id
        }
        return result
    }
}
