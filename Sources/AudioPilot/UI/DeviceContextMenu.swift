import AudioPilotCore
import SwiftUI

/// Right-click menu for a device row in the panel.
struct DeviceContextMenu: View {
    @ObservedObject var model: AppModel
    let dev: AudioDeviceInfo
    let dir: Direction

    var body: some View {
        Button("Use \(model.label(dev))") { model.pick(dir, dev.uid) }
        Divider()
        Button("Rename…") { model.openDeviceSettings(dev.uid) }
        Menu("Icon") {
            Button("Automatic") { model.editDevice(dev.uid) { $0.icon = nil } }
            Divider()
            ForEach(DeviceIconChoices.all, id: \.self) { symbol in
                Button { model.editDevice(dev.uid) { $0.icon = symbol } } label: { Label(DeviceIconChoices.title(symbol), systemImage: symbol) }
            }
        }
        let rates = model.engine.hal.sampleRates(dev.uid)
        if rates.count > 1 {
            let current = model.engine.hal.sampleRate(dev.uid)
            Menu("Sample Rate") {
                ForEach(rates, id: \.self) { rate in
                    Button { model.engine.hal.setSampleRate(dev.uid, rate); model.refresh() } label: {
                        if rate == current { Label(DeviceIconChoices.rateName(rate), systemImage: "checkmark") }
                        else { Text(DeviceIconChoices.rateName(rate)) }
                    }
                }
            }
        }
        if dir == .output, model.engine.hal.balance(dev.uid) != nil {
            Menu("Balance") {
                Button("Left") { model.engine.hal.setBalance(dev.uid, 0.25) }
                Button("Centre") { model.engine.hal.setBalance(dev.uid, 0.5) }
                Button("Right") { model.engine.hal.setBalance(dev.uid, 0.75) }
                Divider()
                Button("Fine-tune in Settings…") { model.openDeviceSettings(dev.uid) }
            }
        }
        if let bt = model.bluetooth.first(where: { $0.connected && $0.matches(dev.uid) }) {
            Divider()
            Button("Disconnect \(bt.name)") { model.setBluetoothConnected(bt, false) }
        }
        Divider()
        Button("Hide This Device") { model.editDevice(dev.uid) { $0.hidden = true } }
        Button("Device Settings…") { model.openDeviceSettings(dev.uid) }
    }
}

enum DeviceIconChoices {
    static let all: [String] = [
        "headphones", "airpods", "airpodspro", "airpodsmax", "earbuds", "beats.headphones",
        "hifispeaker", "hifispeaker.2", "speaker.wave.2", "homepod", "display", "tv",
        "laptopcomputer", "desktopcomputer", "mic", "music.mic", "iphone", "gamecontroller",
        "car", "waveform", "radio", "guitars",
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    static func title(_ symbol: String) -> String {
        symbol.replacingOccurrences(of: ".", with: " ").capitalized
    }

    static func rateName(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }
}
