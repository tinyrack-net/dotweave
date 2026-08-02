// Dart port of `src/cli/shared-flags.ts`.
//
// Commands without flags pass `FlagSet.none()` to `CommandParameters`.

import 'dart:io';

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/sync_context.dart';

final FlagBinding<String?, ApplicationContext>
profileFlag = ParsedFlag.optional<String, ApplicationContext>(
  name: 'profile',
  brief:
      "Use a registered profile layer for this command (add non-default profiles with 'dotweave profile add')",
  parse: stringParser,
  placeholder: 'profile',
);

Future<SyncCommandDefaults?> loadSyncCommandDefaults() async {
  final paths = resolveSyncPaths();
  if (!await File(resolveSyncConfigFilePath(paths.syncDirectory)).exists()) {
    return null;
  }
  final config = await readSyncConfig(
    paths.syncDirectory,
    resolveSyncConfigResolutionContext(),
  );
  return config.commands;
}
