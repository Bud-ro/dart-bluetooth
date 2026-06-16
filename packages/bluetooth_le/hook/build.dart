// Native-assets build hook.
//
// Compiles the Apple CoreBluetooth backend from source into a code asset so the
// `@Native` bindings (lib/src/platform/apple) resolve from a pure-Dart CLI
// (`dart run`) and from a Flutter app (`flutter build`/`flutter run`). One
// source serves both macOS and iOS (CoreBluetooth is identical); Windows/Linux
// build nothing here (Windows uses Win32 GATT FFI, Linux uses D-Bus).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _assetName = 'bluetooth_le.dart';
const _libName = 'bluetooth_le';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final os = input.config.code.targetOS;
    if (os != OS.macOS && os != OS.iOS) return; // nothing to compile

    const relDir = 'src/native/apple/';
    final srcDir = input.packageRoot.resolve(relDir);
    final builder = CBuilder.library(
      name: _libName,
      assetName: _assetName,
      language: Language.objectiveC,
      sources: [srcDir.resolve('bluetooth_le.m').toFilePath()],
      includes: [srcDir.resolve('include/').toFilePath()],
      frameworks: const ['Foundation', 'CoreBluetooth'],
      // -Wall surfaces native warnings; not -Werror (avoid failing on SDK headers).
      flags: const ['-fobjc-arc', '-Wall'],
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
