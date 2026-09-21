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
    // External dependencies:
    // - MapLibre Native iOS: vector map rendering at 60fps, offline-capable
    // - Apple MapKit Search: native framework (no SDK needed)
    // - Valhalla Routing: C++ engine via ObjC++ wrapper (no Swift package)
    dependencies: [
        .package(
            url: "https://github.com/maplibre/maplibre-gl-native-distribution",
            from: "6.7.1"
        ),
    ],
    targets: [
        .target(
            name: "ESP32NavNative",
            dependencies: [
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ],
            path: "Sources"
        ),
    ]
)
