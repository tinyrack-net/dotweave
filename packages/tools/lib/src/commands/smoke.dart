import 'dart:io';

import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/smoke.dart';

Future<int> runSmokeCommand(List<String> args) async {
  final parsed = parseArgs(args, valueOptions: const {'executable-path'});
  final repoRoot = await getRepoRoot(Directory.current.path);

  await performSmoke(
    repoRoot: repoRoot,
    executablePath: parsed.requireOption('executable-path'),
  );

  return 0;
}
