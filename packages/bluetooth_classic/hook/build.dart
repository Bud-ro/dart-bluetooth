// Native-assets build hook.
//
// Compiles the Apple Objective-C backend from source into a code asset so the
// `@Native` bindings in lib/src/platform/macos/macos_bindings.dart resolve from
// a pure-Dart CLI (`dart run`) and a Flutter macOS `flutter build`. The same
// sources are also compiled by the SPM plugin for `flutter run`.
//
// Nothing is built on Windows/Linux (those backends are pure Dart). iOS uses the
// ExternalAccessory sources (added with the iOS backend).
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
    if (os != OS.macOS && os != OS.iOS) {
      // Windows/Linux backends need no native build.
      return;
    }

    final sources = <String>[
      input.packageRoot
          .resolve('native/apple/bluetooth_classic.m')
          .toFilePath(),
    ];

    final builder = CBuilder.library(
      name: _libName,
      assetName: _assetName,
      language: Language.objectiveC,
      sources: sources,
      frameworks: const ['Foundation', 'IOBluetooth'],
      // ARC for the Objective-C wrapper.
      flags: const ['-fobjc-arc'],
    );

    await builder.run(
      input: input,
      output: output,
      logger: null,
    );

    // Ad-hoc sign on macOS so the signed `dart` executable can load the dylib
    // under Library Validation. Harmless if it's already signed.
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
