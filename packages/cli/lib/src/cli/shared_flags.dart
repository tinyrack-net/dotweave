// Dart port of `packages/cli/src/cli/shared-flags.ts`.
//
// The TS `NoFlags` helper type has no Dart equivalent; commands without flags
// simply pass an empty `flags` map to `CommandParameters`.

import 'package:tinyrack_cli/tinyrack_cli.dart';

const ParsedFlag profileFlag = ParsedFlag(
  brief:
      "Use a registered profile layer for this command (add non-default profiles with 'dotweave profile add')",
  optional: true,
  parse: stringParser,
  placeholder: 'profile',
);
