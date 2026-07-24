import type { ResolvedSyncConfig } from "#app/config/sync-schema.ts";
import { DotweaveError } from "#app/lib/error.ts";

/**
 * @description
 * A repository format migration rewrites the on-disk artifacts under a sync
 * repository from one format version to the next. Unlike config migrations
 * (pure object transforms), these touch the filesystem, so they are async and
 * receive the repository directory.
 */
export type RepoFormatMigrationFn = (
  repositoryDirectory: string,
  config: ResolvedSyncConfig,
) => Promise<void>;

export type RepoFormatMigrationRegistry = ReadonlyMap<
  number,
  RepoFormatMigrationFn
>;

export type RepoFormatMigrationResult = Readonly<{
  fromFormat: number;
  migrated: boolean;
}>;

/**
 * @description
 * Verifies a repository's on-disk format is within the range this CLI can
 * operate on: not newer than the current format, and not older than the
 * supported floor. Runs on every config read so all commands fail fast with a
 * clear message.
 */
export const assertRepositoryFormatSupported = (
  currentFormat: number,
  targetFormat: number,
  minSupportedFormat: number,
  contextLabel: string,
) => {
  if (currentFormat > targetFormat) {
    throw new DotweaveError(
      `Repository format ${currentFormat} is newer than this CLI supports (max: ${targetFormat}).`,
      {
        code: "REPO_FORMAT_NEWER",
        details: [contextLabel],
        hint: "Upgrade dotweave to the latest version.",
      },
    );
  }

  if (currentFormat < minSupportedFormat) {
    throw new DotweaveError(
      `Repository format ${currentFormat} is older than this CLI supports (min: ${minSupportedFormat}).`,
      {
        code: "REPO_FORMAT_TOO_OLD",
        details: [contextLabel],
        hint: `Run an older dotweave release to migrate this repository up to format ${minSupportedFormat}, then upgrade again.`,
      },
    );
  }
};

/**
 * @description
 * Runs the pending repository-format migrations for a repository, stepping from
 * its current format up to the target. Refuses repositories that are newer than
 * this CLI understands, or older than the supported floor.
 */
export const applyRepositoryFormatMigrations = async (
  repositoryDirectory: string,
  config: ResolvedSyncConfig,
  registry: RepoFormatMigrationRegistry,
  targetFormat: number,
  minSupportedFormat: number,
): Promise<RepoFormatMigrationResult> => {
  const currentFormat = config.repositoryFormat ?? 0;

  assertRepositoryFormatSupported(
    currentFormat,
    targetFormat,
    minSupportedFormat,
    `Repository directory: ${repositoryDirectory}`,
  );

  if (currentFormat === targetFormat) {
    return { fromFormat: currentFormat, migrated: false };
  }

  for (let format = currentFormat; format < targetFormat; format++) {
    const migrateFn = registry.get(format);

    if (migrateFn === undefined) {
      throw new DotweaveError(
        `No repository format migration found for ${format} → ${format + 1}.`,
        {
          code: "REPO_FORMAT_MIGRATION_NOT_FOUND",
          details: [`Repository directory: ${repositoryDirectory}`],
          hint: "Upgrade dotweave to the latest version.",
        },
      );
    }

    try {
      await migrateFn(repositoryDirectory, config);
    } catch (error: unknown) {
      if (error instanceof DotweaveError) {
        throw new DotweaveError(error.message, {
          code: error.code,
          details: [
            ...error.details,
            `Repository directory: ${repositoryDirectory}`,
            `Repository format migration: ${format} → ${format + 1}`,
          ],
          hint: error.hint,
        });
      }

      throw new DotweaveError(
        `Failed to migrate repository format ${format} → ${format + 1}.`,
        {
          code: "REPO_FORMAT_MIGRATION_FAILED",
          details: [
            `Repository directory: ${repositoryDirectory}`,
            ...(error instanceof Error ? [error.message] : []),
          ],
        },
      );
    }
  }

  return { fromFormat: currentFormat, migrated: true };
};
