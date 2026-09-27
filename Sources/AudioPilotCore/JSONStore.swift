import Foundation

/// Small JSON file store. In `readOnly` mode it never creates, writes or renames files.
public struct JSONStore: Sendable {
    public let directory: URL
    public let readOnly: Bool

    public init(directory: URL, readOnly: Bool = false) {
        self.directory = directory
        self.readOnly = readOnly
    }

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static var defaultDirectory: URL {
        applicationSupport.appendingPathComponent("AudioPilot", isDirectory: true)
    }

    /// The app was called MuteMe before; its settings live in this folder.
    public static let legacyFolderName = "MuteMe"

    /// Picks the settings folder, carrying MuteMe's settings over on first launch. The legacy
    /// folder is copied, never moved or deleted. Read-only callers read the legacy folder in place.
    public static func prepareDirectory(in base: URL = applicationSupport, readOnly: Bool) -> URL {
        let fm = FileManager.default
        let current = base.appendingPathComponent("AudioPilot", isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        guard !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) else { return current }
        if readOnly { return legacy }
        return (try? fm.copyItem(at: legacy, to: current)) != nil ? current : legacy
    }

    public func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    /// Returns the decoded value and whether a usable file existed.
    /// A corrupt file is moved aside to `<name>.corrupt-<unix>.json` (unless read-only) and treated as missing.
    public func load<T: Decodable>(_ type: T.Type, name: String) -> (value: T?, existed: Bool) {
        let file = url(name)
        guard let data = try? Data(contentsOf: file) else { return (nil, false) }
        do {
            return (try JSONDecoder.store.decode(T.self, from: data), true)
        } catch {
            if !readOnly {
                let backup = directory.appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: backup)
            }
            return (nil, false)
        }
    }

    /// Writes atomically. Returns false in read-only mode or on failure.
    @discardableResult
    public func save<T: Encodable>(_ value: T, name: String) -> Bool {
        guard !readOnly else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.store.encode(value)
            try data.write(to: url(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

extension JSONEncoder {
    static var store: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var store: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
