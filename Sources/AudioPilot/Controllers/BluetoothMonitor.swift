import Foundation
import IOBluetooth
import AudioPilotCore
import os

/// Paired Bluetooth audio devices with battery levels (from `system_profiler`, which needs no
/// permission), plus connect/disconnect (IOBluetooth; macOS asks for Bluetooth access on first use).
final class BluetoothMonitor {
    struct Device: Equatable, Identifiable {
        let address: String       // "64:8F:DB:F6:A6:C1"
        let name: String
        let connected: Bool
        let battery: String?      // "82%", or "L 80% · R 75% · Case 40%"
        var id: String { address }

        /// Audio device UIDs for Bluetooth start with the address, dash-separated.
        func matches(_ uid: String) -> Bool {
            uid.uppercased().hasPrefix(address.replacingOccurrences(of: ":", with: "-").uppercased())
        }
    }

    private(set) var devices: [Device] = []
    var onChange: ([Device]) -> Void = { _ in }
    private var refreshing = false
    private var timer: Timer?
    private nonisolated static let logger = Logger(subsystem: "com.techenable.audiopilot", category: "bluetooth")

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let found = Self.query()
            await MainActor.run { [weak self] in
                guard let self else { return }
                refreshing = false
                if found != devices {
                    devices = found
                    onChange(found)
                }
            }
        }
    }

    func setConnected(_ device: Device, _ connect: Bool) {
        let address = device.address.replacingOccurrences(of: ":", with: "-")
        Task.detached(priority: .userInitiated) {
            guard let bt = IOBluetoothDevice(addressString: address) else { return }
            let status = connect ? bt.openConnection() : bt.closeConnection()
            if status != kIOReturnSuccess {
                Self.logger.error("bluetooth \(connect ? "connect" : "disconnect") failed: \(status)")
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    private nonisolated static let audioTypes = ["headset", "headphones", "speaker", "loudspeaker", "audio", "earbuds"]

    private nonisolated static func query() -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }

        var result: [Device] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in info[key] as? [[String: [String: Any]]] ?? [] {
                for (name, props) in entry {
                    let type = (props["device_minorType"] as? String ?? "").lowercased()
                    guard let address = props["device_address"] as? String,
                          audioTypes.contains(where: type.contains) else { continue }
                    result.append(Device(address: address, name: name, connected: connected, battery: battery(props)))
                }
            }
        }
        return result.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    private nonisolated static func battery(_ props: [String: Any]) -> String? {
        if let main = props["device_batteryLevelMain"] as? String { return main }
        let parts = [("L", "device_batteryLevelLeft"), ("R", "device_batteryLevelRight"), ("Case", "device_batteryLevelCase")]
            .compactMap { label, key in (props[key] as? String).map { "\(label) \($0)" } }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
