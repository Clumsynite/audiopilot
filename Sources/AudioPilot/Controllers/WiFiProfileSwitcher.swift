import CoreLocation
import CoreWLAN
import AudioPilotCore
import os

/// Switches profiles when the Wi-Fi network changes. macOS only reveals the network name (SSID)
/// to apps with Location access, so permission is requested only once a profile names a network.
final class WiFiProfileSwitcher: NSObject, CWEventDelegate, CLLocationManagerDelegate {
    private let model: AppModel
    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private var monitoring = false
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "profiles")

    init(model: AppModel) {
        self.model = model
        super.init()
        location.delegate = self
    }

    /// Current network name, or nil (not on Wi-Fi, or no Location access yet).
    var currentSSID: String? { client.interface()?.ssid() }

    var authorization: CLAuthorizationStatus { location.authorizationStatus }

    func requestAccess() {
        location.requestWhenInUseAuthorization()
    }

    /// Starts or stops watching depending on whether any profile is tied to a network.
    func update() {
        let wanted = model.prefs.profiles.contains { $0.wifiSSID != nil }
        if wanted && !monitoring {
            if authorization == .notDetermined { requestAccess() }
            client.delegate = self
            do {
                try client.startMonitoringEvent(with: .ssidDidChange)
                monitoring = true
            } catch {
                logger.error("wifi monitoring failed: \(error.localizedDescription, privacy: .public)")
            }
            check()
        } else if !wanted && monitoring {
            try? client.stopMonitoringAllEvents()
            monitoring = false
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.check() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.check() }
    }

    private func check() {
        guard let ssid = currentSSID,
              let profile = model.prefs.profiles.first(where: { $0.wifiSSID == ssid }),
              profile.id != model.prefs.activeProfileID else { return }
        logger.notice("network \(ssid, privacy: .private) → profile \(profile.name, privacy: .public)")
        model.switchProfile(profile.id, announce: true)
    }
}
