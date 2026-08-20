import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/migrations/repo_format_v1.dart';
import 'package:dotweave/src/config/migrations/repo_format_v2.dart';
import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/services/config_file.dart';

// Mirror of `services/repo-format.ts`: orchestrates on-disk repository format
// migrations and records the completed format in the manifest.

/// Registry of on-disk repository format migrations, keyed by source format.
/// Add the next step (e.g. `{2: migrateRepositoryFormatV2ToV3}`) when the
/// format evolves. Steps must be contiguous up to
/// `AppConstants.sync.repositoryFormat`.
final RepoFormatMigrationRegistry repositoryFormatMigrationRegistry = {
  0: migrateRepositoryFormatV0ToV1,
  1: migrateRepositoryFormatV1ToV2,
};

/// Brings a repository's on-disk artifacts up to the current format and
/// records the completed format in the manifest. A no-op once the repository
/// is already current. Pass the FULL (unfiltered) config so the rewritten
/// manifest keeps every profile's entries.
Future<ResolvedSyncConfig> ensureRepositoryFormat(
  String syncDirectory,
  ResolvedSyncConfig config,
) async {
  final result = await applyRepositoryFormatMigrations(
    syncDirectory,
    config,
    repositoryFormatMigrationRegistry,
    AppConstants.sync.repositoryFormat,
    AppConstants.sync.minSupportedRepositoryFormat,
  );

  if (!result.migrated) {
    return config;
  }

  final upgraded = ResolvedSyncConfig(
    age: config.age,
    entries: config.entries,
    profiles: config.profiles,
    repositoryFormat: AppConstants.sync.repositoryFormat,
    version: config.version,
  );

  await writeValidatedSyncConfig(
    syncDirectory,
    buildSyncConfigDocument(upgraded),
  );

  return upgraded;
}
