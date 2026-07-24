import { writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

import { DotweaveError } from "#app/lib/error.ts";
import { writeTextFileAtomically } from "#app/lib/filesystem.ts";
import { ensureTrailingNewline } from "#app/lib/string.ts";

export type ConfigMigrationFn = (
  config: Record<string, unknown>,
) => Record<string, unknown>;

export type ConfigMigrationRegistry = ReadonlyMap<number, ConfigMigrationFn>;

export type ConfigMigrationResult = Readonly<{
  config: unknown;
  migrated: boolean;
  originalVersion?: number;
}>;

const withMigrationContext = (
  error: DotweaveError,
  filePath: string,
  fromVersion: number,
) => {
  return new DotweaveError(error.message, {
    code: error.code,
    details: [
      ...error.details,
      `Config file: ${filePath}`,
      `Migration: ${fromVersion} → ${fromVersion + 1}`,
    ],
    hint: error.hint,
  });
};

export const applyConfigMigrations = (
  rawConfig: unknown,
  registry: ConfigMigrationRegistry,
  targetVersion: number,
  filePath: string,
): ConfigMigrationResult => {
  if (
    typeof rawConfig !== "object" ||
    rawConfig === null ||
    Array.isArray(rawConfig)
  ) {
    return { config: rawConfig, migrated: false };
  }

  const configObject = rawConfig as Record<string, unknown>;
  // biome-ignore lint/complexity/useLiteralKeys: noPropertyAccessFromIndexSignature requires bracket notation
  const version = configObject["version"];

  if (typeof version !== "number") {
    return { config: rawConfig, migrated: false };
  }

  if (version === targetVersion) {
    return { config: rawConfig, migrated: false, originalVersion: version };
  }

  if (version > targetVersion) {
    throw new DotweaveError(
      `Config file version ${version} is newer than this CLI supports (max: ${targetVersion}).`,
      {
        code: "CONFIG_NEWER_VERSION",
        details: [`Config file: ${filePath}`],
        hint: "Upgrade dotweave to the latest version.",
      },
    );
  }

  let current = configObject;

  for (let v = version; v < targetVersion; v++) {
    const migrateFn = registry.get(v);

    if (migrateFn === undefined) {
      throw new DotweaveError(
        `No migration path found for config version ${v} → ${v + 1}.`,
        {
          code: "CONFIG_MIGRATION_NOT_FOUND",
          details: [`Config file: ${filePath}`],
          hint: "Upgrade dotweave to the latest version.",
        },
      );
    }

    try {
      current = migrateFn(current);
    } catch (error: unknown) {
      if (error instanceof DotweaveError) {
        throw withMigrationContext(error, filePath, v);
      }

      throw new DotweaveError(
        `Failed to migrate config from version ${v} to ${v + 1}.`,
        {
          code: "CONFIG_MIGRATION_FAILED",
          details: [
            `Config file: ${filePath}`,
            `Migration: ${v} → ${v + 1}`,
            ...(error instanceof Error ? [error.message] : []),
          ],
        },
      );
    }
  }

  return { config: current, migrated: true, originalVersion: version };
};

/**
 * @description
 * Persists a migrated config: writes a `.v<originalVersion>.bak` backup of the
 * original raw config, then atomically rewrites the file with the migrated one.
 * Shared by every config reader so backup/rewrite behaves identically, and is
 * always called AFTER semantic validation so an invalid migration is never
 * persisted.
 */
export const persistMigratedConfig = async (
  filePath: string,
  originalRawConfig: unknown,
  migratedConfig: unknown,
  originalVersion: number,
): Promise<void> => {
  const backupPath = join(
    dirname(filePath),
    `${basename(filePath)}.v${originalVersion}.bak`,
  );
  await writeFile(
    backupPath,
    ensureTrailingNewline(JSON.stringify(originalRawConfig, null, 2)),
    "utf8",
  );

  await writeTextFileAtomically(
    filePath,
    ensureTrailingNewline(JSON.stringify(migratedConfig, null, 2)),
  );
};

/**
 * Applies sequential config migrations from the detected version up to targetVersion.
 * Creates a backup file before the first migration step, then saves the result.
 * Returns the migrated config (or the original if no migration was needed).
 */
export const runConfigMigrations = async (
  rawConfig: unknown,
  registry: ConfigMigrationRegistry,
  targetVersion: number,
  filePath: string,
): Promise<unknown> => {
  const { config, migrated, originalVersion } = applyConfigMigrations(
    rawConfig,
    registry,
    targetVersion,
    filePath,
  );

  if (!migrated || originalVersion === undefined) {
    return config;
  }

  await persistMigratedConfig(filePath, rawConfig, config, originalVersion);

  return config;
};
