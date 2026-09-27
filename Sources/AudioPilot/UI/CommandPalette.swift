import AppKit
import AudioPilotCore
import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    let icon: String
    var keywords: String = ""
    var isCurrent = false
    var tint: Color?
    /// Themes etc. keep the panel open so you can see the effect.
    var keepsPanelOpen = false
    let run: () -> Void
}

/// All commands the palette offers, built from live state.
enum PaletteCommands {
    static func all(_ model: AppModel) -> [PaletteCommand] {
        var list: [PaletteCommand] = []
        let prefs = model.prefs
        let muted = model.mute.isMuted

        list.append(PaletteCommand(id: "mute", title: muted ? "Unmute Microphone" : "Mute Microphone",
                                   subtitle: KeyNames.string(prefs.hotkey), icon: muted ? "mic.fill" : "mic.slash.fill",
                                   keywords: "mute unmute microphone mic silence toggle") {
            model.toggleMute(feedback: true)
        })

        for dir in [Direction.output, .input] {
            for dev in model.devices(dir) {
                let blocked = dir == .input && model.isBlocked(dev.uid)
                let isCurrent = model.engine.state.current[dir] == dev.uid
                list.append(PaletteCommand(
                    id: "\(dir.rawValue):\(dev.uid)",
                    title: model.label(dev),
                    subtitle: prefs.deviceShortcuts[DeviceShortcut.device(dir, dev.uid).key].map(KeyNames.string)
                        ?? ((dir == .output ? "Output" : "Input") + (blocked ? " · mic off" : "")),
                    icon: model.icon(dev, dir),
                    keywords: dev.name.lowercased() + " " + (dir == .output ? "output speaker speakers headphones sound play switch" : "input microphone mic record switch"),
                    isCurrent: isCurrent) {
                    model.pick(dir, dev.uid)
                })
            }
        }

        for dir in [Direction.output, .input] {
            let key = DeviceShortcut.next(dir).key
            list.append(PaletteCommand(id: key, title: dir == .output ? "Next Output Device" : "Next Input Device",
                                       subtitle: prefs.deviceShortcuts[key].map(KeyNames.string) ?? "",
                                       icon: dir == .output ? "speaker.wave.2" : "mic",
                                       keywords: "next cycle switch rotate " + (dir == .output ? "output speaker" : "input microphone")) {
                model.perform(.next(dir))
            })
        }

        for profile in prefs.profiles {
            list.append(PaletteCommand(id: "profile:\(profile.id.uuidString)", title: profile.name, subtitle: "Profile",
                                       icon: "rectangle.stack", keywords: "profile location place setup",
                                       isCurrent: prefs.activeProfileID == profile.id) {
                model.switchProfile(profile.id)
            })
        }

        let auto = prefs.autoSwitchEnabled
        list.append(PaletteCommand(id: "auto", title: auto ? "Pause Auto-switch" : "Resume Auto-switch",
                                   icon: auto ? "pause.circle" : "wand.and.stars",
                                   keywords: "auto switch automatic pause resume priority") {
            model.setAutoSwitch(!auto)
        })
        let ptt = prefs.hotkeyMode == .pushToTalk
        list.append(PaletteCommand(id: "mode", title: ptt ? "Use Toggle Mute Mode" : "Use Push-to-Talk Mode",
                                   icon: "hand.tap",
                                   keywords: "push to talk ptt toggle mode hold walkie") {
            model.setHotKeyMode(ptt ? .toggle : .pushToTalk)
        })
        list.append(PaletteCommand(id: "overlay", title: prefs.showMutedOverlay ? "Hide Floating Mute Indicator" : "Show Floating Mute Indicator",
                                   icon: "capsule",
                                   keywords: "overlay indicator floating pill badge", keepsPanelOpen: true) {
            model.edit { $0.showMutedOverlay.toggle() }
        })

        for theme in PanelTheme.allCases {
            list.append(PaletteCommand(id: "theme:\(theme.rawValue)", title: theme.title,
                                       subtitle: "Theme", icon: "paintpalette",
                                       keywords: "theme appearance color look glass style",
                                       isCurrent: model.theme == theme, keepsPanelOpen: true) {
                model.setTheme(theme)
            })
        }

        list.append(PaletteCommand(id: "settings", title: "Open Settings…", subtitle: "⌘,", icon: "gearshape",
                                   keywords: "settings preferences options configure") { model.openSettings() })
        list.append(PaletteCommand(id: "about", title: "About AudioPilot", icon: "info.circle",
                                   keywords: "about version info") { model.openAbout() })
        list.append(PaletteCommand(id: "quit", title: "Quit AudioPilot", subtitle: "⌘Q", icon: "power",
                                   keywords: "quit exit close") { NSApp.terminate(nil) })
        return list
    }

    /// Simple fuzzy score: prefix > word prefix > substring > subsequence. Nil = no match.
    static func score(_ query: String, _ command: PaletteCommand) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let title = command.title.lowercased()
        let haystack = title + " " + command.subtitle.lowercased() + " " + command.keywords
        if title.hasPrefix(q) { return 1000 - title.count }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 800 - title.count }
        if title.contains(q) { return 600 - title.count }
        let words = q.split(separator: " ")
        if words.allSatisfy({ haystack.contains($0) }) { return 400 - title.count }
        var idx = haystack.startIndex
        var gaps = 0
        for ch in q where ch != " " {
            guard let found = haystack[idx...].firstIndex(of: ch) else { return nil }
            gaps += haystack.distance(from: idx, to: found)
            idx = haystack.index(after: found)
        }
        return max(1, 200 - gaps)
    }

    static func filter(_ query: String, _ commands: [PaletteCommand]) -> [PaletteCommand] {
        // Keep the unfiltered list short: themes only appear once you search.
        let pool = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? commands.filter { !$0.id.hasPrefix("theme:") } : commands
        return pool.enumerated()
            .compactMap { i, c in score(query, c).map { (c, $0, i) } }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }
}

struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    @FocusState private var focused: Bool

    var body: some View {
        let results = ui.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search devices and commands", text: $ui.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { ui.runSelected() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if results.isEmpty {
                Text("No results").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                PaletteRow(command: command, selected: index == ui.selection, accent: model.theme.accent)
                                    .id(command.id)
                                    .onTapGesture { ui.selection = index; ui.runSelected() }
                                    .onHover { if $0 { ui.selection = index } }
                            }
                        }
                        .padding(5)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: ui.selection) { _, new in
                        if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                    }
                }
            }
        }
        .glassSurface(cornerRadius: 14)
        .onAppear { focused = true }
        .onChange(of: ui.query) { _, _ in ui.selection = 0 }
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let selected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.icon)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 18)
            Text(command.title).font(.system(size: 13)).lineLimit(1)
            if command.isCurrent {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            }
            Spacer()
            if !command.subtitle.isEmpty {
                Text(command.subtitle).font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Small keyboard-key label.
struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }
}
