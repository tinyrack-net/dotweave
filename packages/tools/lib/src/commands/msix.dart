import 'dart:io';

import 'package:dotweave_tools/src/lib/args.dart';
import 'package:dotweave_tools/src/lib/error.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/msix.dart';

Future<int> runMsixCommand(List<String> args) async {
  if (args.isEmpty) {
    throw const ToolException('Usage: msix <build|bundle> [options]');
  }

  final subcommand = args.first;
  final rest = args.sublist(1);

  switch (subcommand) {
    case 'build':
      return _runBuild(rest);
    case 'bundle':
      return _runBundle(rest);
    default:
      throw ToolException('Unknown msix subcommand: $subcommand');
  }
}

Future<int> _runBuild(List<String> args) async {
  final parsed = parseArgs(
    args,
    valueOptions: const {
      'arch',
      'executable-path',
      'output-path',
      'package-root',
    },
  );
  final repoRoot = await getRepoRoot(Directory.current.path);

  await performMsixBuild(
    arch: parseMsixArchitecture(parsed.requireOption('arch')),
    executablePath: parsed.requireOption('executable-path'),
    repoRoot: repoRoot,
    outputPath: parsed.option('output-path'),
    packageRoot: parsed.option('package-root'),
  );

  return 0;
}

Future<int> _runBundle(List<String> args) async {
  final parsed = parseArgs(
    args,
    valueOptions: const {'output-path', 'package-dir'},
  );
  final repoRoot = await getRepoRoot(Directory.current.path);

  await performMsixBundle(
    repoRoot: repoRoot,
    outputPath: parsed.option('output-path'),
    packageDir: parsed.option('package-dir'),
  );

  return 0;
}
