// Dart port of `src/cli/profile/use.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/services/profile.dart';

final Command<ApplicationContext> profileUseCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Set or clear the active sync profile',
    fullDescription:
        'Write ~/.config/dotweave/settings.jsonc so plain push, pull, status, and doctor commands use the selected registered profile by default. Omit the profile name to clear the active profile.',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);

    final profile = args;
    final result = profile != null
        ? await setActiveProfile(profile)
        : await clearActiveProfile();

    if (result.action == 'use') {
      logger.success('Active profile set to ${result.activeProfile}');
    } else {
      logger.success('Active profile cleared');
    }

    // Mirror of the TS truthiness check `if (result.warning)`.
    final warning = result.warning;
    if (warning != null && warning.isNotEmpty) {
      logger.warn(warning);
    }
  },
  parameters: CommandParameters(
    flags: FlagSet<NoFlags, ApplicationContext>.none(),
    positional: PositionalSet.one(
      Positional.optional<String, ApplicationContext>(
        brief: 'Profile name to activate (omit to clear)',
        parse: stringParser,
        placeholder: 'profile',
      ),
    ),
  ),
);
