// Dart port of `packages/cli/src/cli/profile/use.ts`.

import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/terminal/logger.dart';

final Command profileUseCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Set or clear the active sync profile',
    fullDescription:
        'Write ~/.config/dotweave/settings.jsonc so plain push, pull, status, and doctor commands use the selected registered profile by default. Omit the profile name to clear the active profile.',
  ),
  func: (context, flags, positional) async {
    final logger = createCliLogger();

    final profile = positional[0] as String?;
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
    return null;
  },
  parameters: const CommandParameters(
    flags: {},
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Profile name to activate (omit to clear)',
        optional: true,
        parse: stringParser,
        placeholder: 'profile',
      ),
    ]),
  ),
);
