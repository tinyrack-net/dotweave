import { AppConstants } from "#app/config/constants.ts";
import {
  applyRepositoryFormatMigrations,
  type RepoFormatMigrationRegistry,
} from "#app/config/repo-format-migration.ts";
import type { ResolvedSyncConfig } from "#app/config/sync-schema.ts";
import { migrateRepositoryFormatV0ToV1 } from "#app/migrations/repo-format-v1.ts";
import {
  buildSyncConfigDocument,
  writeValidatedSyncConfig,
} from "./config-file.ts";

/**
 * @description
 * Registry of on-disk repository format migrations, keyed by source format.
 * Add the next step (e.g. `[1, migrateRepositoryFormatV1ToV2]`) when the format
 * evolves. Steps must be contiguous up to AppConstants.SYNC.REPOSITORY_FORMAT.
 */
export const repositoryFormatMigrationRegistry: RepoFormatMigrationRegistry =
  new Map([[0, migrateRepositoryFormatV0ToV1]]);

/**
 * @description
 * Brings a repository's on-disk artifacts up to the current format and records
 * the completed format in the manifest. A no-op once the repository is already
 * current. Pass the FULL (unfiltered) config so the rewritten manifest keeps
 * every profile's entries.
 */
export const ensureRepositoryFormat = async (
  syncDirectory: string,
  config: ResolvedSyncConfig,
): Promise<ResolvedSyncConfig> => {
  const result = await applyRepositoryFormatMigrations(
    syncDirectory,
    config,
    repositoryFormatMigrationRegistry,
    AppConstants.SYNC.REPOSITORY_FORMAT,
    AppConstants.SYNC.MIN_SUPPORTED_REPOSITORY_FORMAT,
  );

  if (!result.migrated) {
    return config;
  }

  const upgraded: ResolvedSyncConfig = {
    ...config,
    repositoryFormat: AppConstants.SYNC.REPOSITORY_FORMAT,
  };

  await writeValidatedSyncConfig(
    syncDirectory,
    buildSyncConfigDocument(upgraded),
  );

  return upgraded;
};
