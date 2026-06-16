// swift-tools-version:5.9
// Swift Package Manager manifest for the Flutter macOS plugin.
//
// This compiles the same Objective-C IOBluetooth wrapper used by the
// native-assets build hook (Sources/bluetooth_classic is a symlink to
// ../../native/apple), so `flutter run`/`flutter build` on macOS link the
// backend without waiting on native-assets-during-`flutter run`. As an
// `ffiPlugin` there is no platform-channel plugin class — Dart talks to the
// native code directly via dart:ffi.
import PackageDescription

let package = Package(
    name: "bluetooth_classic",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "bluetooth-classic", targets: ["bluetooth_classic"])
    ],
    targets: [
        .target(
            name: "bluetooth_classic",
            cSettings: [
                .headerSearchPath(".")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
