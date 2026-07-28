// Dart port of `packages/cli/src/cli/profile/remove.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/services/profile.dart';

final Command<ApplicationContext> profileRemoveCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Remove a sync profile',
    fullDescription:
        'Unregister an unused non-default profile from manifest.jsonc. Reassign or clear tracked entry assignments before removing a referenced profile.',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);
    final result = await removeProfile(args);

    logger.success('Removed profile ${result.profile}');
  },
  parameters: CommandParameters(
    flags: FlagSet<NoFlags, ApplicationContext>.none(),
    positional: PositionalSet.one(
      Positional.required<String, ApplicationContext>(
        brief: 'Profile name to remove',
        parse: stringParser,
        placeholder: 'profile',
      ),
    ),
  ),
);
