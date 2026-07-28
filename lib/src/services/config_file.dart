import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/filesystem.dart';

// Mirror of `services/config-file.ts`: manifest document construction and
// validated atomic writes.

List<SyncConfigEntry> sortSyncConfigEntries(List<SyncConfigEntry> entries) {
  return [...entries]..sort((left, right) {
    return compareLocaleLike(
      left.localPath.defaultValue,
      right.localPath.defaultValue,
    );
  });
}

RawSyncConfig buildSyncConfigDocument(ResolvedSyncConfig config) {
  final entries = sortSyncConfigEntries([
    for (final entry in config.entries)
      SyncConfigEntry(
        kind: entry.kind,
        localPath: entry.configuredLocalPath,
        repoPath: entry.configuredRepoPath,
        mode: entry.modeExplicit ? entry.configuredMode : null,
        permission: entry.permissionExplicit
            ? entry.configuredPermission
            : null,
        profiles: entry.profilesExplicit ? [...entry.profiles] : null,
      ),
  ]);

  return RawSyncConfig(
    version: AppConstants.sync.configVersion,
    // Preserve the actual on-disk format marker rather than forcing the
    // current value: rewriting the manifest (e.g. on track/untrack) must not
    // claim the repository was format-migrated. Only ensureRepositoryFormat
    // advances it.
    repositoryFormat: config.repositoryFormat,
    age: config.age == null
        ? null
        : AgeConfig(recipients: [...config.age!.recipients]),
    profiles: [...(config.profiles ?? const <String>[])],
    entries: entries,
  );
}

Future<RawSyncConfig> writeValidatedSyncConfig(
  String syncDirectory,
  RawSyncConfig config,
) async {
  final parsed = parseRawSyncConfig(config.toJson());
  validateRawSyncConfigProfileRegistry(parsed);

  await writeTextFileAtomically(
    resolveSyncConfigFilePath(syncDirectory),
    formatSyncConfig(config),
  );

  return config;
}
