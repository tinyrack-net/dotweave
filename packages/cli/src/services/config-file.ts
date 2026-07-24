import { AppConstants } from "#app/config/constants.ts";
import {
  formatSyncConfig,
  type RawSyncConfig,
  type ResolvedSyncConfig,
  resolveSyncConfigFilePath,
  syncConfigSchema,
  validateRawSyncConfigProfileRegistry,
} from "#app/config/sync-schema.ts";
import { writeTextFileAtomically } from "#app/lib/filesystem.ts";

export const sortSyncConfigEntries = (
  entries: readonly RawSyncConfig["entries"][number][],
) => {
  return [...entries].sort((left, right) => {
    return left.localPath.default.localeCompare(right.localPath.default);
  });
};

export const buildSyncConfigDocument = (
  config: ResolvedSyncConfig,
): RawSyncConfig => {
  const entries = sortSyncConfigEntries(
    config.entries.map((entry): RawSyncConfig["entries"][number] => ({
      kind: entry.kind,
      localPath: entry.configuredLocalPath,
      ...(entry.configuredRepoPath === undefined
        ? {}
        : { repoPath: entry.configuredRepoPath }),
      ...(entry.modeExplicit ? { mode: entry.configuredMode } : {}),
      ...(entry.permissionExplicit
        ? { permission: entry.configuredPermission }
        : {}),
      ...(entry.profilesExplicit ? { profiles: [...entry.profiles] } : {}),
    })),
  );

  return {
    version: AppConstants.SYNC.CONFIG_VERSION,
    // Preserve the actual on-disk format marker rather than forcing the current
    // value: rewriting the manifest (e.g. on track/untrack) must not claim the
    // repository was format-migrated. Only ensureRepositoryFormat advances it.
    ...(config.repositoryFormat === undefined
      ? {}
      : { repositoryFormat: config.repositoryFormat }),
    ...(config.age === undefined
      ? {}
      : {
          age: {
            recipients: [...config.age.recipients],
          },
        }),
    profiles: [...(config.profiles ?? [])],
    entries,
  } as RawSyncConfig;
};

export const writeValidatedSyncConfig = async (
  syncDirectory: string,
  config: RawSyncConfig,
) => {
  const parsed = syncConfigSchema.parse(config);
  validateRawSyncConfigProfileRegistry(parsed);

  await writeTextFileAtomically(
    resolveSyncConfigFilePath(syncDirectory),
    formatSyncConfig(config),
  );

  return config;
};
