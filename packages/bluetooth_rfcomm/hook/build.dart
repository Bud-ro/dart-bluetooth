// Native-assets build hook.
//
// Compiles the Apple Objective-C backend from source into a code asset so the
// `@Native` bindings (lib/src/platform/{macos,ios}) resolve from a pure-Dart CLI
// (`dart run`) and from a Flutter app (`flutter build`/`flutter run`). This is
// the single build path for Apple — there is no SPM plugin.
//
// Per target OS:
//   macOS -> src/native/apple/macos/  (IOBluetooth)
//   iOS   -> src/native/apple/ios/    (ExternalAccessory)
// Windows/Linux build nothing (those backends are pure Dart).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _assetName = 'bluetooth_rfcomm.dart';
const _libName = 'bluetooth_rfcomm';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final os = input.config.code.targetOS;
    final (String relDir, List<String> frameworks) = switch (os) {
      OS.macOS => (
        'src/native/apple/macos/',
        const ['Foundation', 'IOBluetooth'],
      ),
      OS.iOS => (
        'src/native/apple/ios/',
        const ['Foundation', 'ExternalAccessory'],
      ),
      _ => ('', const <String>[]),
    };
    if (relDir.isEmpty) return; // Windows/Linux: nothing to build.

    final srcDir = input.packageRoot.resolve(relDir);
    final builder = CBuilder.library(
      name: _libName,
      assetName: _assetName,
      language: Language.objectiveC,
      sources: [srcDir.resolve('bluetooth_rfcomm.m').toFilePath()],
      includes: [srcDir.resolve('include/').toFilePath()],
      frameworks: frameworks,
      // -Wall surfaces native warnings in the build log (goal: warning-free
      // Apple builds). Not -Werror, to avoid failing on third-party SDK headers.
      flags: const ['-fobjc-arc', '-Wall'],
    );

    await builder.run(input: input, output: output, logger: null);

    // Ad-hoc sign on macOS so the signed `dart` executable can load the dylib
    // under Library Validation.
    if (os == OS.macOS) {
      final dylib = input.outputDirectory
          .resolve('lib$_libName.dylib')
          .toFilePath();
      if (File(dylib).existsSync()) {
        final r = await Process.run('codesign', ['-f', '-s', '-', dylib]);
        if (r.exitCode != 0) {
          stderr.writeln('codesign (ad-hoc) failed: ${r.stderr}');
        }
      }
    }
  });
}
