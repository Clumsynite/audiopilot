import AppKit
import AudioPilotCore
import SwiftUI

/// Panel color themes. Each is a soft gradient tint laid over (Liquid) glass.
enum PanelTheme: String, CaseIterable, Identifiable {
    case glass, aurora, sunset, ocean, forest, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Clear Glass"
        case .aurora: "Aurora"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .graphite: "Graphite"
        }
    }

    /// Gradient stops for the backdrop blobs.
    var colors: [Color] {
        switch self {
        case .glass: [.white.opacity(0.0), .white.opacity(0.0)]
        case .aurora: [Color(red: 0.49, green: 0.33, blue: 0.98), Color(red: 0.11, green: 0.78, blue: 0.75), Color(red: 0.93, green: 0.36, blue: 0.75)]
        case .sunset: [Color(red: 1.0, green: 0.48, blue: 0.29), Color(red: 0.96, green: 0.26, blue: 0.52), Color(red: 1.0, green: 0.78, blue: 0.3)]
        case .ocean: [Color(red: 0.12, green: 0.45, blue: 0.98), Color(red: 0.1, green: 0.8, blue: 0.95), Color(red: 0.32, green: 0.3, blue: 0.9)]
        case .forest: [Color(red: 0.13, green: 0.7, blue: 0.45), Color(red: 0.55, green: 0.8, blue: 0.3), Color(red: 0.05, green: 0.5, blue: 0.5)]
        case .graphite: [Color(white: 0.45), Color(white: 0.2), Color(white: 0.6)]
        }
    }

    var accent: Color {
        self == .glass ? .accentColor : colors[0]
    }

    var tintOpacity: Double {
        switch self {
        case .glass: 0
        case .graphite: 0.08
        default: 0.12
        }
    }

    static func from(_ raw: String) -> PanelTheme { PanelTheme(rawValue: raw) ?? .glass }
}

/// Soft blurred color blobs behind the panel content.
struct ThemeBackdrop: View {
    let theme: PanelTheme

    var body: some View {
        GeometryReader { geo in
            let c = theme.colors
            ZStack {
                Circle().fill(c[0]).frame(width: geo.size.width * 0.9)
                    .offset(x: -geo.size.width * 0.35, y: -geo.size.height * 0.3)
                Circle().fill(c[min(1, c.count - 1)]).frame(width: geo.size.width * 0.8)
                    .offset(x: geo.size.width * 0.4, y: geo.size.height * 0.1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .blur(radius: 80)
            .opacity(theme.tintOpacity)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint),
                             in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    /// Glass circle for icon buttons.
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.background(tint.map { AnyShapeStyle($0.opacity(0.3)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

/// SF Symbol for a device.
enum DeviceIcon {
    static func name(_ dev: AudioDeviceInfo, _ dir: Direction) -> String {
        let symbol = raw(dev, dir)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : (dir == .input ? "mic" : "headphones")
    }

    private static func raw(_ dev: AudioDeviceInfo, _ dir: Direction) -> String {
        let n = dev.name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        switch dev.transport {
        case .builtIn: return dir == .input ? "laptopcomputer" : (n.contains("headphone") ? "headphones" : "laptopcomputer")
        case .bluetooth, .bluetoothLE: return n.contains("buds") ? "earbuds" : "headphones"
        case .usb, .thunderbolt, .pci, .fireWire, .avb:
            return dir == .input && !dev.hasOutput ? "mic" : (n.contains("speaker") ? "hifispeaker" : "headphones")
        case .hdmi, .displayPort: return "display"
        case .airPlay: return "airplayaudio"
        case .continuityWired, .continuityWireless: return "iphone"
        case .virtual: return "waveform"
        case .aggregate: return "square.stack.3d.up"
        default: return dir == .input ? "mic" : "speaker.wave.2"
        }
    }
}
