// Native-assets build hook.
//
// Compiles the Apple Objective-C backend from source into a code asset so the
// `@Native` bindings (lib/src/platform/{macos,ios}) resolve from a pure-Dart CLI
// (`dart run`) and a Flutter `flutter build`. The same sources are also compiled
// by the SPM plugins for `flutter run`.
//
// Per target OS:
//   macOS -> native/apple/macos/bluetooth_classic.m  (IOBluetooth)
//   iOS   -> native/apple/ios/bluetooth_classic.m    (ExternalAccessory)
// Windows/Linux build nothing (those backends are pure Dart).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _assetName = 'bluetooth_classic.dart';
const _libName = 'bluetooth_classic';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final os = input.config.code.targetOS;
    final (String subdir, List<String> frameworks) = switch (os) {
      OS.macOS => ('macos', const ['Foundation', 'IOBluetooth']),
      OS.iOS => ('ios', const ['Foundation', 'ExternalAccessory']),
      _ => ('', const <String>[]),
    };
    if (subdir.isEmpty) return; // Windows/Linux: nothing to build.

    final srcDir = input.packageRoot.resolve('native/apple/$subdir/');
    final builder = CBuilder.library(
      name: _libName,
      assetName: _assetName,
      language: Language.objectiveC,
      sources: [srcDir.resolve('bluetooth_classic.m').toFilePath()],
      includes: [srcDir.resolve('include/').toFilePath()],
      frameworks: frameworks,
      flags: const ['-fobjc-arc'],
    );

    await builder.run(input: input, output: output, logger: null);

    // Ad-hoc sign on macOS so the signed `dart` executable can load the dylib
    // under Library Validation.
    if (os == OS.macOS) {
      final dylib =
          input.outputDirectory.resolve('lib$_libName.dylib').toFilePath();
      if (File(dylib).existsSync()) {
        final r = await Process.run('codesign', ['-f', '-s', '-', dylib]);
        if (r.exitCode != 0) {
          stderr.writeln('codesign (ad-hoc) failed: ${r.stderr}');
        }
      }
    }
  });
}
