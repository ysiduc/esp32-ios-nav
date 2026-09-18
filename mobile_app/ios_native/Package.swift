// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ESP32NavNative",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ESP32NavNative",
            targets: ["ESP32NavNative"]
        ),
    ],
    // No external dependencies needed:
    // - Map:     MapKit (built-in iOS framework, free)
    // - Routing: MKDirections (built-in, no API key)
    // - Search:  MKLocalSearch (built-in, no API key)
    dependencies: [],
    targets: [
        .target(
            name: "ESP32NavNative",
            dependencies: [],
            path: "Sources"
        ),
    ]
)
