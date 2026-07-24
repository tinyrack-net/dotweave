// Dart port of `packages/cli/src/cli/profile/remove.ts`.

import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/terminal/logger.dart';

final Command profileRemoveCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Remove a sync profile',
    fullDescription:
        'Unregister an unused non-default profile from manifest.jsonc. Reassign or clear tracked entry assignments before removing a referenced profile.',
  ),
  func: (context, flags, positional) async {
    final logger = createCliLogger();
    final result = await removeProfile(positional[0] as String);

    logger.success('Removed profile ${result.profile}');
    return null;
  },
  parameters: const CommandParameters(
    flags: {},
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Profile name to remove',
        parse: stringParser,
        placeholder: 'profile',
      ),
    ]),
  ),
);
