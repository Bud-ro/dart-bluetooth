// swift-tools-version:5.9
// Swift Package Manager manifest for the Flutter macOS plugin.
//
// Compiles the same Objective-C IOBluetooth wrapper used by the native-assets
// build hook (Sources/bluetooth_classic is a symlink to ../../native/apple/macos,
// with the public header under include/). As an `ffiPlugin` there is no
// platform-channel plugin class — Dart talks to the native code directly via
// dart:ffi. Flutter's SPM integration requires a FlutterFramework dependency.
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
