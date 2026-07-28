// Dart port of `src/cli/shared-flags.ts`.
//
// Commands without flags pass `FlagSet.none()` to `CommandParameters`.

import 'package:cliweave/cliweave.dart';

final FlagBinding<String?, ApplicationContext>
profileFlag = ParsedFlag.optional<String, ApplicationContext>(
  name: 'profile',
  brief:
      "Use a registered profile layer for this command (add non-default profiles with 'dotweave profile add')",
  parse: stringParser,
  placeholder: 'profile',
);
