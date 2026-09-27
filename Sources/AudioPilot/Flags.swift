import Foundation

struct Flags {
    var listDevices = false
    var dryRun = false
    var dryRunSeconds: Double = 5
    var testMute = false
    /// With --dry-run: show the UI (panel, palette, settings) without any side effects.
    var showPanel: String?

    init(_ args: [String] = Array(CommandLine.arguments.dropFirst())) {
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--list-devices": listDevices = true
            case "--dry-run": dryRun = true
            case "--test-mute": testMute = true
            case "--show-panel": showPanel = "panel"
            case "--show-palette": showPanel = "palette"
            case "--show-settings": showPanel = it.next() ?? "general"
            case "--show-about": showPanel = "about"
            case "--show-hud": showPanel = "hud-" + (it.next() ?? "muted")
            case "--dry-run-seconds":
                if let v = it.next().flatMap(Double.init) { dryRunSeconds = v }
            default: break
            }
        }
    }
}
