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
    dependencies: [
        // Ferrostar: Modern Rust-based Navigation Core with Swift bindings
        .package(
            url: "https://github.com/stadiamaps/ferrostar.git",
            from: "0.26.0"
        ),
        // MapLibre Native for iOS: High-performance vector tile rendering
        .package(
            url: "https://github.com/maplibre/maplibre-gl-native-distribution.git",
            from: "6.21.2"
        ),
    ],
    targets: [
        .target(
            name: "ESP32NavNative",
            dependencies: [
                .product(name: "FerrostarCore", package: "ferrostar"),
                .product(name: "FerrostarSwiftUI", package: "ferrostar"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ],
            path: "Sources"
        ),
    ]
)
