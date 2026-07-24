import 'dart:io';

import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/verify.dart';

Future<int> runVerifyCommand(List<String> args) async {
  if (args.isEmpty || args.first != 'release-tag') {
    throw const ToolException('Usage: verify release-tag');
  }

  parseArgs(args.sublist(1));

  final repoRoot = await getRepoRoot(Directory.current.path);

  await performVerifyReleaseTag(repoRoot: repoRoot);

  return 0;
}
