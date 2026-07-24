// Dart port of `packages/cli/src/cli/profile/add.ts`.

import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/terminal/logger.dart';

final Command profileAddCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Add a sync profile',
    fullDescription:
        'Register a non-default profile in manifest.jsonc so entries can be assigned to it and it can be selected with profile use.',
  ),
  func: (context, flags, positional) async {
    final logger = createCliLogger();
    final result = await addProfile(positional[0] as String);

    logger.success('Added profile ${result.profile}');
    return null;
  },
  parameters: const CommandParameters(
    flags: {},
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Profile name to add',
        parse: stringParser,
        placeholder: 'profile',
      ),
    ]),
  ),
);
