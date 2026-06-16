// swift-tools-version:5.9
// Swift Package Manager manifest for the Flutter macOS plugin.
//
// Sources/bluetooth_classic holds the Objective-C IOBluetooth wrapper (public
// header under include/); the native-assets build hook compiles the very same
// files for the pure-Dart CLI. As an `ffiPlugin` there is no platform-channel
// plugin class — Dart talks to the native code directly via dart:ffi. Flutter's
// SPM integration requires a FlutterFramework dependency.
import PackageDescription

let package = Package(
    name: "bluetooth_classic",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "bluetooth-classic", targets: ["bluetooth_classic"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "bluetooth_classic",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
