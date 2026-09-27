// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AudioPilotCore"),
        .executableTarget(
            name: "AudioPilot",
            dependencies: ["AudioPilotCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(name: "AudioPilotCoreTests", dependencies: ["AudioPilotCore"]),
    ]
)
