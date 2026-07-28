// Dart port of `packages/cli/src/cli/cd.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/services/shell.dart';

final Command<ApplicationContext> cdCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Launch a shell in the sync directory',
    fullDescription:
        'Launch a child shell rooted at the local sync directory. Like chezmoi cd, this opens a new shell session instead of changing the current directory of your existing shell.',
  ),
  func: (context, flags, args) async {
    await launchShellInSyncDirectory(resolveDotweaveSyncDirectoryFromEnv());
  },
  parameters: CommandParameters(
    flags: FlagSet<NoFlags, ApplicationContext>.none(),
    positional: PositionalSet.none(),
  ),
);
