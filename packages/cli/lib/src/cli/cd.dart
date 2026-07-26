// Dart port of `packages/cli/src/cli/cd.ts`.

import 'dart:io' as io;

import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/services/shell.dart';

final Command cdCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Launch a shell in the sync directory',
    fullDescription:
        'Launch a child shell rooted at the local sync directory. Like chezmoi cd, this opens a new shell session instead of changing the current directory of your existing shell.',
  ),
  func: (context, flags, positional) async {
    final syncDirectory = resolveDotweaveSyncDirectoryFromEnv();

    await io.Directory(syncDirectory).create(recursive: true);
    await launchShellInDirectory(syncDirectory);
    return null;
  },
  parameters: const CommandParameters(flags: {}),
);
