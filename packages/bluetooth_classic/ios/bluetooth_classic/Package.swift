// swift-tools-version:5.9
// Swift Package Manager manifest for the Flutter iOS plugin.
//
// Sources/bluetooth_classic holds the Objective-C ExternalAccessory backend
// (public header under include/); the native-assets build hook compiles the very
// same files for `flutter build`. As an `ffiPlugin` there is no platform-channel
// plugin class — Dart talks to the native code directly via dart:ffi. Flutter's
// SPM integration requires a FlutterFramework dependency.
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
                .linkedFramework("ExternalAccessory")
            ]
        )
    ]
)
