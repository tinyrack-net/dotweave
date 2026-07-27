// Dart port of `packages/cli/src/cli/cd.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/services/shell.dart';

final Command cdCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Launch a shell in the sync directory',
    fullDescription:
        'Launch a child shell rooted at the local sync directory. Like chezmoi cd, this opens a new shell session instead of changing the current directory of your existing shell.',
  ),
  func: (context, flags, positional) async {
    await launchShellInSyncDirectory(resolveDotweaveSyncDirectoryFromEnv());
    return null;
  },
  parameters: const CommandParameters(flags: {}),
);
