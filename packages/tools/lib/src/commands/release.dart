import 'dart:io';

import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/release.dart';
import 'package:dotweave_tools/src/lib/version.dart';

void _log(String message) {
  stdout.writeln('[release] $message');
}

Future<int> runReleaseCommand(List<String> args) async {
  final parsed = parseArgs(
    args,
    booleanFlags: const {'dry-run'},
    aliases: const {'n': 'dry-run'},
  );

  if (parsed.positionals.length != 1) {
    throw const ToolException('Usage: release <patch|minor|major> [--dry-run]');
  }

  final releaseType = parseReleaseType(parsed.positionals.single);
  final logger = ReleaseLogger(
    info: _log,
    start: (message) => _log('▶ $message'),
  );

  final result = await performRelease(
    cwd: Directory.current.path,
    dryRun: parsed.flag('dry-run'),
    logger: logger,
    releaseType: releaseType,
  );

  if (result.dryRun) {
    _log(
      '✔ Dry run: would release ${result.version} '
      'from ${result.previousTag} to ${result.tag}',
    );

    return 0;
  }

  _log(
    '✔ Released ${result.version} '
    'from ${result.previousTag} to ${result.tag}',
  );

  return 0;
}
