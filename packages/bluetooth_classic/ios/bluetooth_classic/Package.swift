// swift-tools-version:5.9
// Swift Package Manager manifest for the Flutter iOS plugin.
//
// Compiles the same ExternalAccessory backend used by the native-assets build
// hook (Sources/bluetooth_classic is a symlink to ../../native/apple/ios). As an
// `ffiPlugin` there is no platform-channel plugin class — Dart talks to the
// native code directly via dart:ffi.
//
// The host app must declare its accessory protocol strings in
// UISupportedExternalAccessoryProtocols (Info.plist) for any MFi accessory to be
// usable. Non-MFi devices are not reachable via ExternalAccessory; use BLE.
import PackageDescription

let package = Package(
    name: "bluetooth_classic",
    platforms: [
        .iOS("12.0")
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
                .linkedFramework("ExternalAccessory")
            ]
        )
    ]
)
