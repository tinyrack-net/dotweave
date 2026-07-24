import 'dart:io';

import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/sign.dart';

Future<int> runSignCommand(List<String> args) async {
  if (args.isEmpty || args.first != 'macos') {
    throw const ToolException(
      'Usage: sign macos --executable-path <path> [--skip-notarize]',
    );
  }

  final parsed = parseArgs(
    args.sublist(1),
    valueOptions: const {'executable-path'},
    booleanFlags: const {'skip-notarize'},
  );
  final repoRoot = await getRepoRoot(Directory.current.path);

  await performMacosSign(
    repoRoot: repoRoot,
    executablePath: parsed.requireOption('executable-path'),
    skipNotarize: parsed.flag('skip-notarize'),
  );

  return 0;
}
