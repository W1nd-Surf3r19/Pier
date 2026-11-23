// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pier",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Pier",
            path: "Sources/Pier",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOBluetooth"),
            ]
        ),
        .testTarget(name: "PierTests", dependencies: ["Pier"], path: "Tests/PierTests"),
    ],
    swiftLanguageModes: [.v5]
)
