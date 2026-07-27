import 'dart:io';

import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/validate.dart';

const String _usage = 'Usage: validate [dart-static|dart-tests]';

Future<int> runValidateCommand(List<String> args) async {
  if (args.length > 1 || (args.isNotEmpty && args.first.startsWith('-'))) {
    throw const ToolException(_usage);
  }

  final targetName = args.isEmpty ? null : args.single;
  final target = targetName == null
      ? ValidationTarget.dartAll
      : ValidationTarget.fromCliName(targetName);

  if (target == null) {
    throw ToolException('Unknown validation target: $targetName\n$_usage');
  }

  final repoRoot = await getRepoRoot(Directory.current.path);

  return runValidation(repoRoot: repoRoot, target: target);
}
