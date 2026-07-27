// Dart port of `packages/cli/src/cli/profile/list.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/services/profile.dart';

final Command profileListCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Show configured and active sync profiles',
    fullDescription:
        'List the implicit default profile and manifest-registered profiles, and show which profile is active through ~/.config/dotweave/settings.jsonc.',
  ),
  func: (context, flags, positional) async {
    final logger = loggerFor(context);

    final result = await listProfiles();

    logger.info('Profiles');

    final profiles = [...result.availableProfiles];
    logger.list(
      profiles
          .map((name) => name == result.activeProfile ? '$name (active)' : name)
          .toList(),
      highlightLast: false,
    );

    final activeProfileWarning = result.activeProfileWarning;
    if (activeProfileWarning != null) {
      logger.warn(activeProfileWarning);
    }
    return null;
  },
  parameters: const CommandParameters(flags: {}),
);
