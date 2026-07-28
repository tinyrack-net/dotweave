// Dart port of `packages/cli/src/cli/profile/add.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/services/profile.dart';

final Command<ApplicationContext> profileAddCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Add a sync profile',
    fullDescription:
        'Register a non-default profile in manifest.jsonc so entries can be assigned to it and it can be selected with profile use.',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);
    final result = await addProfile(args);

    logger.success('Added profile ${result.profile}');
  },
  parameters: CommandParameters(
    flags: FlagSet<NoFlags, ApplicationContext>.none(),
    positional: PositionalSet.one(
      Positional.required<String, ApplicationContext>(
        brief: 'Profile name to add',
        parse: stringParser,
        placeholder: 'profile',
      ),
    ),
  ),
);
