import 'dart:io';

import 'package:dotweave_tools/src/lib/appimage.dart';
import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/git.dart';

Future<int> runAppimageCommand(List<String> args) async {
  if (args.isEmpty || args.first != 'build') {
    throw const ToolException(
      'Usage: appimage build --executable-path <path> '
      '--output-path <path> --arch <x86_64|aarch64>',
    );
  }

  final parsed = parseArgs(
    args.sublist(1),
    valueOptions: const {'executable-path', 'output-path', 'arch'},
  );
  final repoRoot = await getRepoRoot(Directory.current.path);

  await performAppImageBuild(
    repoRoot: repoRoot,
    executablePath: parsed.requireOption('executable-path'),
    outputPath: parsed.requireOption('output-path'),
    arch: parsed.requireOption('arch'),
  );

  return 0;
}
