import AppKit
@preconcurrency import CoreSpotlight
import AudioPilotCore
import UniformTypeIdentifiers
import os

/// Publishes AudioPilot's actions and devices to Spotlight. Choosing a result reopens AudioPilot with the
/// item's ID, which runs through `AppModel.perform(_:)`.
final class SpotlightIndexer {
    static let domain = "com.techenable.audiopilot.actions"

    private let model: AppModel
    private var lastSignature = ""
    private var pending: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "spotlight")

    init(model: AppModel) {
        self.model = model
    }

    struct Entry: Equatable {
        let id: String
        let title: String
        let detail: String
        let keywords: [String]
        let symbol: String
    }

    /// Stable entries (titles don't depend on mute state, so the index rarely changes).
    func entries() -> [Entry] {
        var list: [Entry] = [
            Entry(id: "mute.toggle", title: "Toggle Microphone Mute", detail: "AudioPilot · mute or unmute every mic",
                  keywords: ["mute", "unmute", "microphone", "mic", "silence"], symbol: "mic.slash.fill"),
            Entry(id: "mute.on", title: "Mute Microphone", detail: "AudioPilot", keywords: ["mute", "mic", "silence"], symbol: "mic.slash"),
            Entry(id: "mute.off", title: "Unmute Microphone", detail: "AudioPilot", keywords: ["unmute", "mic", "live"], symbol: "mic"),
            Entry(id: "next:output", title: "Next Output Device", detail: "AudioPilot · cycle speakers and headphones",
                  keywords: ["output", "speaker", "headphones", "switch", "next"], symbol: "speaker.wave.2"),
            Entry(id: "next:input", title: "Next Input Device", detail: "AudioPilot · cycle microphones",
                  keywords: ["input", "microphone", "switch", "next"], symbol: "mic"),
            Entry(id: "auto.toggle", title: "Toggle Automatic Device Switching", detail: "AudioPilot option",
                  keywords: ["auto", "automatic", "switching", "priority", "pause"], symbol: "arrow.triangle.2.circlepath"),
            Entry(id: "mode.toggle", title: "Toggle Push-to-Talk", detail: "AudioPilot option",
                  keywords: ["push", "talk", "ptt", "mode", "hold"], symbol: "hand.tap"),
            Entry(id: "overlay.toggle", title: "Toggle Floating Mute Indicator", detail: "AudioPilot option",
                  keywords: ["overlay", "indicator", "floating"], symbol: "capsule"),
            Entry(id: "settings", title: "AudioPilot Settings", detail: "Devices, shortcuts, app rules, appearance",
                  keywords: ["settings", "preferences", "options", "shortcuts", "rules"], symbol: "gearshape"),
            Entry(id: "palette", title: "AudioPilot Command Palette", detail: "Search devices and commands",
                  keywords: ["search", "palette", "commands"], symbol: "magnifyingglass"),
        ]
        for theme in PanelTheme.allCases {
            list.append(Entry(id: "theme:\(theme.rawValue)", title: "AudioPilot Theme: \(theme.title)", detail: "Appearance option",
                              keywords: ["theme", "appearance", theme.rawValue], symbol: "paintpalette"))
        }
        for profile in model.prefs.profiles {
            list.append(Entry(id: "profile:\(profile.id.uuidString)", title: "AudioPilot Profile: \(profile.name)",
                              detail: "Switch device priorities and rules", keywords: ["profile", profile.name],
                              symbol: "rectangle.stack"))
        }
        // Every device AudioPilot knows, connected or not (switching needs it connected).
        let known = model.prefs.knownDevices.sorted { $0.value.name < $1.value.name }
        for (uid, device) in known where device.transport.isPhysical && model.prefs.deviceSettings[uid]?.hidden != true {
            let label = model.prefs.deviceSettings[uid]?.customName ?? device.name
            if device.hasOutput {
                list.append(Entry(id: DeviceShortcut.device(.output, uid).key, title: "Switch Output to \(label)",
                                  detail: "AudioPilot · output device", keywords: ["output", "speaker", "headphones", "sound", device.name],
                                  symbol: "speaker.wave.2"))
            }
            if device.hasInput {
                list.append(Entry(id: DeviceShortcut.device(.input, uid).key, title: "Switch Input to \(label)",
                                  detail: "AudioPilot · input device", keywords: ["input", "microphone", "mic", device.name],
                                  symbol: "mic"))
            }
        }
        return list
    }

    /// Re-indexes after a short delay, and only if the entries changed.
    func scheduleReindex() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reindex() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    func reindex() {
        guard model.prefs.spotlightEnabled else {
            clear()
            return
        }
        let entries = entries()
        let signature = entries.map { "\($0.id)|\($0.title)" }.joined(separator: "\n")
        guard signature != lastSignature else { return }
        lastSignature = signature

        let items = entries.map { entry -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .item)
            attrs.title = entry.title
            attrs.displayName = entry.title
            attrs.contentDescription = entry.detail
            attrs.keywords = entry.keywords + ["AudioPilot"]
            attrs.thumbnailData = Self.symbolPNG(entry.symbol)
            return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: Self.domain, attributeSet: attrs)
        }
        let index = CSSearchableIndex.default()
        let logger = logger
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in
            index.indexSearchableItems(items) { error in
                if let error { logger.error("spotlight index failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func clear() {
        lastSignature = ""
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in }
    }

    private static func symbolPNG(_ name: String) -> Data? {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
