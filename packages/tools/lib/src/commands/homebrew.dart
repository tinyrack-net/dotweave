import 'dart:io';

import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/homebrew.dart';

Future<int> runHomebrewCommand(List<String> args) async {
  if (args.isEmpty || args.first != 'generate') {
    throw const ToolException(
      'Usage: homebrew generate --version <v> --artifacts-dir <dir>',
    );
  }

  final parsed = parseArgs(
    args.sublist(1),
    valueOptions: const {'version', 'artifacts-dir'},
  );
  final repoRoot = await getRepoRoot(Directory.current.path);

  await performHomebrewGenerate(
    version: parsed.requireOption('version'),
    artifactsDir: parsed.requireOption('artifacts-dir'),
    repoRoot: repoRoot,
  );

  return 0;
}
