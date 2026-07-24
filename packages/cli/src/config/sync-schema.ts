import { readFile } from "node:fs/promises";
import { isAbsolute, join, posix, relative, sep } from "node:path";
import { z } from "zod";
import { AppConstants } from "#app/config/constants.ts";
import {
  applyConfigMigrations,
  persistMigratedConfig,
} from "#app/config/migration.ts";
import {
  type PlatformKey,
  type PlatformStringValue,
  resolvePlatformValue,
} from "#app/config/platform.ts";
import { assertRepositoryFormatSupported } from "#app/config/repo-format-migration.ts";
import { resolveConfiguredAbsolutePath } from "#app/config/xdg.ts";
import { DotweaveError } from "#app/lib/error.ts";
import { parsePermissionOctal } from "#app/lib/file-mode.ts";
import { parseJsonc, validateJsoncConfigPath } from "#app/lib/jsonc.ts";
import { doPathsOverlap } from "#app/lib/path.ts";
import { ensureTrailingNewline } from "#app/lib/string.ts";
import { formatInputIssues } from "#app/lib/validation.ts";
import { migrateSyncConfigV7ToV8 } from "#app/migrations/sync-v8.ts";

const syncConfigMigrationRegistry = new Map([[7, migrateSyncConfigV7ToV8]]);

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

const requiredTrimmedStringSchema = z
  .string()
  .trim()
  .min(1, "Value must not be empty.");

const syncProfileNameArraySchema = z
  .array(requiredTrimmedStringSchema)
  .min(1, "At least one profile must be specified.");

const syncProfileRegistrySchema = z
  .array(requiredTrimmedStringSchema)
  .default([]);

const platformLocalPathSchema = z.object({
  default: requiredTrimmedStringSchema,
  win: requiredTrimmedStringSchema.optional(),
  mac: requiredTrimmedStringSchema.optional(),
  linux: requiredTrimmedStringSchema.optional(),
  wsl: requiredTrimmedStringSchema.optional(),
});

const localPathSchema = platformLocalPathSchema;
const platformRepoPathSchema = z.object({
  default: requiredTrimmedStringSchema,
  win: requiredTrimmedStringSchema.optional(),
  mac: requiredTrimmedStringSchema.optional(),
  linux: requiredTrimmedStringSchema.optional(),
  wsl: requiredTrimmedStringSchema.optional(),
});

const repoPathSchema = platformRepoPathSchema;

const platformSyncModeSchema = z.object({
  default: z.enum(AppConstants.SYNC.MODES),
  win: z.enum(AppConstants.SYNC.MODES).optional(),
  mac: z.enum(AppConstants.SYNC.MODES).optional(),
  linux: z.enum(AppConstants.SYNC.MODES).optional(),
  wsl: z.enum(AppConstants.SYNC.MODES).optional(),
});

const permissionOctalSchema = z
  .string()
  .regex(
    /^0[0-7]{3}$/,
    "Permission must be a 4-character octal string like '0600' or '0755'.",
  );

const platformPermissionSchema = z.object({
  default: permissionOctalSchema,
  win: permissionOctalSchema.optional(),
  mac: permissionOctalSchema.optional(),
  linux: permissionOctalSchema.optional(),
  wsl: permissionOctalSchema.optional(),
});

const syncConfigEntrySchema = z.object({
  kind: z.enum(["file", "directory"] as const),
  localPath: localPathSchema,
  repoPath: repoPathSchema.optional(),
  profiles: syncProfileNameArraySchema.optional(),
  mode: platformSyncModeSchema.optional(),
  permission: platformPermissionSchema.optional(),
});

const syncConfigAgeSchema = z.object({
  recipients: z
    .array(requiredTrimmedStringSchema)
    .min(1, "At least one age recipient is required."),
});

const syncConfigSchemaV7 = z.object({
  version: z.union([z.literal(7), z.literal(AppConstants.SYNC.CONFIG_VERSION)]),
  // On-disk artifact format marker (see AppConstants.SYNC.REPOSITORY_FORMAT).
  // Optional and additive: an absent field means format 0 (legacy). Not tied to
  // the config `version`, so no config migration is needed to introduce it.
  repositoryFormat: z.number().int().min(0).optional(),
  age: syncConfigAgeSchema.optional(),
  profiles: syncProfileRegistrySchema,
  entries: z.array(syncConfigEntrySchema),
});

export const syncConfigSchema = syncConfigSchemaV7;

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

const syncEntryKinds = ["file", "directory"] as const;

export type SyncConfigEntryKind = (typeof syncEntryKinds)[number];
export type SyncMode = (typeof AppConstants.SYNC.MODES)[number];
export type ConfiguredSyncRepoPath = PlatformStringValue;
export type PlatformSyncMode = z.infer<typeof platformSyncModeSchema>;
export type PlatformPermission = z.infer<typeof platformPermissionSchema>;
export type RawSyncConfig = z.infer<typeof syncConfigSchema>;

export type SyncConfigResolutionContext = Readonly<{
  homeDirectory: string;
  platformKey: PlatformKey;
  readEnv: (name: string) => string | undefined;
  xdgConfigHome: string;
}>;

export type ResolvedSyncConfigEntry = Readonly<{
  configuredMode: PlatformSyncMode;
  configuredLocalPath: PlatformStringValue;
  configuredPermission?: PlatformPermission;
  configuredRepoPath?: ConfiguredSyncRepoPath;
  kind: SyncConfigEntryKind;
  localPath: string;
  profiles: readonly string[];
  profilesExplicit: boolean;
  mode: SyncMode;
  modeExplicit: boolean;
  permission?: number;
  permissionExplicit: boolean;
  repoPath: string;
}>;

export type AgeConfig = Readonly<{
  recipients: readonly string[];
}>;

export type ResolvedSyncConfig = Readonly<{
  age?: AgeConfig;
  entries: readonly ResolvedSyncConfigEntry[];
  profiles?: readonly string[];
  repositoryFormat?: number;
  version: 7 | typeof AppConstants.SYNC.CONFIG_VERSION;
}>;

// ---------------------------------------------------------------------------
// Normalization utilities
// ---------------------------------------------------------------------------

export const normalizeSyncRepoPath = (value: string) => {
  const normalizedValue = posix.normalize(value.replaceAll("\\", "/"));

  if (
    normalizedValue === "" ||
    normalizedValue === "." ||
    normalizedValue.startsWith("../") ||
    normalizedValue.includes("/../") ||
    normalizedValue.startsWith("/")
  ) {
    throw new DotweaveError(
      "Repository path must be a relative POSIX path inside the repository root.",
      {
        code: "INVALID_REPO_PATH",
        details: [`Repository path: ${value}`],
        hint: "Use a relative path like '.config/tool/settings.json' without '..' segments.",
      },
    );
  }

  if (hasReservedSyncArtifactSuffixSegment(normalizedValue)) {
    throw new DotweaveError(
      `Repository path must not use the reserved suffixes ${AppConstants.SYNC.SECRET_ARTIFACT_SUFFIX} or ${AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX}.`,
      {
        code: "RESERVED_ARTIFACT_SUFFIX",
        details: [`Repository path: ${value}`],
        hint: "Rename the path so no segment ends with a reserved artifact suffix.",
      },
    );
  }

  return normalizedValue;
};

export const normalizeSyncProfileName = (
  value: string,
  description = "Profile name",
) => {
  const normalizedValue = value.trim();

  if (normalizedValue.length === 0) {
    throw new DotweaveError(`${description} must not be empty.`, {
      code: "INVALID_PROFILE_NAME",
      details: [`${description}: ${value}`],
      hint: "Use a short profile name like 'work' or 'personal'.",
    });
  }

  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(normalizedValue)) {
    throw new DotweaveError(`${description} contains unsupported characters.`, {
      code: "INVALID_PROFILE_NAME",
      details: [`${description}: ${value}`],
      hint: "Use letters, numbers, dots, underscores, or hyphens, and start with a letter or number.",
    });
  }

  if (normalizedValue.startsWith(".")) {
    throw new DotweaveError(`${description} must not start with '.'.`, {
      code: "INVALID_PROFILE_NAME",
      details: [`${description}: ${value}`],
      hint: "Use a plain name like 'work' instead of hidden-path style names.",
    });
  }

  if (normalizedValue === "." || normalizedValue === "..") {
    throw new DotweaveError(`${description} is invalid.`, {
      code: "INVALID_PROFILE_NAME",
      details: [`${description}: ${value}`],
    });
  }

  if (normalizedValue === "profiles") {
    throw new DotweaveError(
      `${description} conflicts with the reserved profile artifact directory.`,
      {
        code: "INVALID_PROFILE_NAME",
        details: [`${description}: ${value}`],
        hint: "Use a profile name like 'work' or 'personal' instead of 'profiles'.",
      },
    );
  }

  return normalizedValue;
};

export const hasReservedSyncArtifactSuffixSegment = (value: string) => {
  return value
    .replaceAll("\\", "/")
    .split("/")
    .some(
      (segment) =>
        segment.endsWith(AppConstants.SYNC.SECRET_ARTIFACT_SUFFIX) ||
        segment.endsWith(AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX),
    );
};

export const deriveRepoPathFromLocalPath = (
  localPath: PlatformStringValue,
  homeDirectory: string,
) => {
  const resolvedDefaultPath = resolveConfiguredAbsolutePath(
    localPath.default,
    homeDirectory,
    undefined,
  );
  const relativePath = relative(homeDirectory, resolvedDefaultPath);

  return normalizeSyncRepoPath(relativePath.replaceAll("\\", "/"));
};

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const validatePathOverlaps = (
  entries: readonly ResolvedSyncConfigEntry[],
  property: "localPath" | "repoPath",
  description: string,
) => {
  for (let index = 0; index < entries.length; index += 1) {
    const currentEntry = entries[index];

    if (currentEntry === undefined) {
      continue;
    }

    for (
      let otherIndex = index + 1;
      otherIndex < entries.length;
      otherIndex += 1
    ) {
      const otherEntry = entries[otherIndex];

      if (otherEntry === undefined) {
        continue;
      }

      const currentValue = currentEntry[property];
      const otherValue = otherEntry[property];

      if (currentValue === otherValue) {
        const isRepoPath = property === "repoPath";

        throw new DotweaveError(
          isRepoPath
            ? `Multiple entries target the same repository path in ${AppConstants.SYNC.CONFIG_FILE_NAME}.`
            : `Duplicate ${description.toLowerCase()} paths in ${AppConstants.SYNC.CONFIG_FILE_NAME}.`,
          {
            code: "DUPLICATE_PATHS",
            details: isRepoPath
              ? [
                  `${currentEntry.localPath} -> ${currentValue}`,
                  `${otherEntry.localPath} -> ${otherValue}`,
                ]
              : [
                  `${currentEntry.repoPath}: ${currentValue}`,
                  `${otherEntry.repoPath}: ${otherValue}`,
                ],
            hint: isRepoPath
              ? "Each entry must use a unique repoPath. Change or remove one of the conflicting entries."
              : `Remove the duplicate entry from ${AppConstants.SYNC.CONFIG_FILE_NAME}.`,
          },
        );
      }

      const isParentChild =
        currentValue.startsWith(`${otherValue}/`) ||
        currentValue.startsWith(`${otherValue}${sep}`) ||
        otherValue.startsWith(`${currentValue}/`) ||
        otherValue.startsWith(`${currentValue}${sep}`);

      if (isParentChild) {
        continue;
      }

      const overlaps =
        property === "repoPath"
          ? false
          : doPathsOverlap(currentValue, otherValue);

      if (overlaps) {
        throw new DotweaveError(
          `${description} paths must not overlap in ${AppConstants.SYNC.CONFIG_FILE_NAME}.`,
          {
            code: "OVERLAPPING_PATHS",
            details: [
              `${currentEntry.repoPath}: ${currentValue}`,
              `${otherEntry.repoPath}: ${otherValue}`,
            ],
            hint: "Split overlapping entries so each tracked root owns a distinct path.",
          },
        );
      }
    }
  }
};

export const validateResolvedSyncConfigEntries = (
  entries: readonly ResolvedSyncConfigEntry[],
) => {
  validatePathOverlaps(entries, "repoPath", "Repository");
  validatePathOverlaps(entries, "localPath", "Local");
};

const normalizeProfileRegistry = (profiles: readonly string[]) => {
  const normalizedProfiles = profiles.map((profile) =>
    normalizeSyncProfileName(profile),
  );
  const seenProfiles = new Set<string>();

  for (const profile of normalizedProfiles) {
    if (profile === AppConstants.SYNC.DEFAULT_PROFILE) {
      throw new DotweaveError(
        `Profile '${AppConstants.SYNC.DEFAULT_PROFILE}' is implicit and must not be listed in manifest profiles.`,
        {
          code: "INVALID_PROFILE_REGISTRY",
          hint: `Remove '${AppConstants.SYNC.DEFAULT_PROFILE}' from profiles in ${AppConstants.SYNC.CONFIG_FILE_NAME}.`,
        },
      );
    }

    if (seenProfiles.has(profile)) {
      throw new DotweaveError(`Duplicate profile '${profile}' in manifest.`, {
        code: "DUPLICATE_PROFILE",
        hint: `Remove duplicate profile names from profiles in ${AppConstants.SYNC.CONFIG_FILE_NAME}.`,
      });
    }

    seenProfiles.add(profile);
  }

  return normalizedProfiles;
};

const validateProfileReferences = (
  references: Iterable<readonly [string, readonly string[]]>,
  profiles: readonly string[],
) => {
  const availableProfiles = new Set([
    AppConstants.SYNC.DEFAULT_PROFILE,
    ...profiles,
  ]);

  for (const [entryLabel, entryProfiles] of references) {
    for (const profile of entryProfiles) {
      const normalizedProfile = normalizeSyncProfileName(profile);

      if (!availableProfiles.has(normalizedProfile)) {
        throw new DotweaveError(`Unknown profile '${normalizedProfile}'.`, {
          code: "UNKNOWN_PROFILE",
          details: [`Entry: ${entryLabel}`],
          hint: `Add it with 'dotweave profile add ${normalizedProfile}', or remove it from the entry profiles.`,
        });
      }
    }
  }
};

const validateEntryProfileReferences = (
  entries: readonly ResolvedSyncConfigEntry[],
  profiles: readonly string[],
) => {
  validateProfileReferences(
    entries.map((entry) => [entry.repoPath, entry.profiles] as const),
    profiles,
  );
};

export const validateRawSyncConfigProfileRegistry = (
  config: Pick<RawSyncConfig, "entries" | "profiles">,
) => {
  const profiles = normalizeProfileRegistry(config.profiles ?? []);

  validateProfileReferences(
    config.entries.map(
      (entry, index) =>
        [
          entry.repoPath?.default ?? entry.localPath.default ?? `#${index}`,
          entry.profiles ?? [],
        ] as const,
    ),
    profiles,
  );

  return profiles;
};

const collectLegacyProfileRegistry = (
  entries: readonly { profiles?: readonly string[] }[],
) => {
  const profiles = new Set<string>();

  for (const entry of entries) {
    if (entry.profiles === undefined) {
      continue;
    }

    for (const profile of entry.profiles) {
      const normalizedProfile = normalizeSyncProfileName(profile);
      if (normalizedProfile !== AppConstants.SYNC.DEFAULT_PROFILE) {
        profiles.add(normalizedProfile);
      }
    }
  }

  return [...profiles].sort((left, right) => left.localeCompare(right));
};

// ---------------------------------------------------------------------------
// Internal parsing helpers
// ---------------------------------------------------------------------------

const defaultSyncMode: PlatformSyncMode = {
  default: AppConstants.SYNC.MODES[0],
};

const resolveSyncModeForPlatform = (
  configuredMode: PlatformSyncMode,
  platformKey: PlatformKey,
): SyncMode => {
  if (platformKey === "wsl") {
    return configuredMode.wsl ?? configuredMode.linux ?? configuredMode.default;
  }

  return configuredMode[platformKey] ?? configuredMode.default;
};

const resolveSyncPermissionForPlatform = (
  configuredPermission: PlatformPermission,
  platformKey: PlatformKey,
): number => {
  if (platformKey === "wsl") {
    const raw =
      configuredPermission.wsl ??
      configuredPermission.linux ??
      configuredPermission.default;
    return parsePermissionOctal(raw);
  }

  const raw = configuredPermission[platformKey] ?? configuredPermission.default;
  return parsePermissionOctal(raw);
};

const normalizeConfiguredRepoPath = (
  repoPath: ConfiguredSyncRepoPath,
): ConfiguredSyncRepoPath => {
  const result: Record<string, string> = {
    default: normalizeSyncRepoPath(repoPath.default),
  };

  for (const key of ["win", "mac", "linux", "wsl"] as const) {
    if (repoPath[key] !== undefined) {
      result[key] = normalizeSyncRepoPath(repoPath[key]);
    }
  }

  return result as ConfiguredSyncRepoPath;
};

const resolveSyncEntryLocalPath = (
  value: PlatformStringValue,
  context: SyncConfigResolutionContext,
) => {
  const { platformKey, homeDirectory, xdgConfigHome, readEnv } = context;
  const platformPath = resolvePlatformValue(value, platformKey);
  let resolvedLocalPath: string;

  try {
    resolvedLocalPath = resolveConfiguredAbsolutePath(
      platformPath,
      homeDirectory,
      xdgConfigHome,
      readEnv,
    );
  } catch (error: unknown) {
    throw new DotweaveError(
      error instanceof Error
        ? error.message
        : `Invalid sync entry local path: ${platformPath}`,
    );
  }

  const relativePath = relative(homeDirectory, resolvedLocalPath);

  if (relativePath === "") {
    throw new DotweaveError(
      "Sync entry local path cannot be the home directory itself.",
      {
        code: "ENTRY_ROOT_DISALLOWED",
        details: [
          `Configured path: ${platformPath}`,
          `Home directory: ${homeDirectory}`,
        ],
        hint: "Track a file or subdirectory inside HOME instead.",
      },
    );
  }

  if (
    isAbsolute(relativePath) ||
    relativePath.startsWith("..") ||
    relativePath === ".."
  ) {
    throw new DotweaveError("Sync entry local path must stay inside HOME.", {
      code: "ENTRY_OUTSIDE_HOME",
      details: [
        `Configured path: ${platformPath}`,
        `Home directory: ${homeDirectory}`,
      ],
      hint: "Use a path under HOME, such as '~/...'.",
    });
  }

  return resolvedLocalPath;
};

const findNearestParentEntry = (
  entries: ReadonlyMap<string, ResolvedSyncConfigEntry>,
  childRepoPath: string,
): ResolvedSyncConfigEntry | undefined => {
  let best: ResolvedSyncConfigEntry | undefined;

  for (const entry of entries.values()) {
    if (
      entry.kind === "directory" &&
      childRepoPath !== entry.repoPath &&
      childRepoPath.startsWith(`${entry.repoPath}/`) &&
      (best === undefined || entry.repoPath.length > best.repoPath.length)
    ) {
      best = entry;
    }
  }

  return best;
};

const applyEntryInheritance = (
  entries: ResolvedSyncConfigEntry[],
  platformKey: PlatformKey,
): ResolvedSyncConfigEntry[] => {
  const sorted = [...entries].sort(
    (a, b) => a.repoPath.length - b.repoPath.length,
  );

  const resolved = new Map<string, ResolvedSyncConfigEntry>();

  for (const entry of sorted) {
    const parent = findNearestParentEntry(resolved, entry.repoPath);

    const inheritedMode =
      !entry.modeExplicit && parent !== undefined
        ? parent.configuredMode
        : entry.configuredMode;

    const inheritedProfiles =
      !entry.profilesExplicit && parent !== undefined
        ? parent.profiles
        : entry.profiles;

    const inheritedPermission =
      !entry.permissionExplicit && parent !== undefined
        ? parent.configuredPermission
        : entry.configuredPermission;

    resolved.set(entry.repoPath, {
      ...entry,
      configuredMode: inheritedMode,
      configuredPermission: inheritedPermission,
      profiles: inheritedProfiles,
      mode: resolveSyncModeForPlatform(inheritedMode, platformKey),
      permission:
        inheritedPermission !== undefined
          ? resolveSyncPermissionForPlatform(inheritedPermission, platformKey)
          : undefined,
    });
  }

  return entries.map((e) => {
    const entry = resolved.get(e.repoPath);

    if (entry === undefined) {
      throw new Error(`Missing resolved entry for ${e.repoPath}`);
    }

    return entry;
  });
};

// ---------------------------------------------------------------------------
// Public API: parsing & serialization
// ---------------------------------------------------------------------------

export const parseSyncConfig = (
  input: unknown,
  context: SyncConfigResolutionContext,
): ResolvedSyncConfig => {
  const { platformKey, homeDirectory } = context;
  const result = syncConfigSchema.safeParse(input);

  if (!result.success) {
    throw new DotweaveError("Sync configuration is invalid.", {
      code: "CONFIG_VALIDATION_FAILED",
      details: formatInputIssues(result.error.issues).split("\n"),
      hint: `Fix the invalid fields in ${AppConstants.SYNC.CONFIG_FILE_NAME}, then run the command again.`,
    });
  }

  const profiles = normalizeProfileRegistry(
    result.data.version === 7
      ? collectLegacyProfileRegistry(result.data.entries)
      : result.data.profiles,
  );

  const rawEntries = result.data.entries.map((entry) => {
    const resolvedLocalPath = resolveSyncEntryLocalPath(
      entry.localPath,
      context,
    );
    const configuredRepoPath =
      entry.repoPath === undefined
        ? undefined
        : normalizeConfiguredRepoPath(entry.repoPath);
    const repoPath =
      configuredRepoPath === undefined
        ? deriveRepoPathFromLocalPath(entry.localPath, homeDirectory)
        : resolvePlatformValue(configuredRepoPath, platformKey);

    if (entry.profiles !== undefined && entry.profiles.length > 0) {
      for (const profile of entry.profiles) {
        normalizeSyncProfileName(profile);
      }
    }
    const profiles =
      entry.profiles !== undefined && entry.profiles.length > 0
        ? entry.profiles
        : [];

    const configuredMode = entry.mode ?? defaultSyncMode;
    const configuredPermission = entry.permission;

    return {
      configuredMode,
      configuredLocalPath: entry.localPath,
      configuredPermission,
      ...(configuredRepoPath === undefined ? {} : { configuredRepoPath }),
      kind: entry.kind,
      localPath: resolvedLocalPath,
      profiles,
      profilesExplicit: entry.profiles !== undefined,
      mode: resolveSyncModeForPlatform(configuredMode, platformKey),
      modeExplicit: entry.mode !== undefined,
      permission:
        configuredPermission !== undefined
          ? resolveSyncPermissionForPlatform(configuredPermission, platformKey)
          : undefined,
      permissionExplicit: entry.permission !== undefined,
      repoPath,
    } satisfies ResolvedSyncConfigEntry;
  });

  validateResolvedSyncConfigEntries(rawEntries);

  const entries = applyEntryInheritance(rawEntries, platformKey);
  validateEntryProfileReferences(entries, profiles);

  const age =
    result.data.age === undefined
      ? undefined
      : {
          recipients: [...new Set(result.data.age.recipients)],
        };

  return {
    ...(age === undefined ? {} : { age }),
    entries,
    profiles,
    ...(result.data.repositoryFormat === undefined
      ? {}
      : { repositoryFormat: result.data.repositoryFormat }),
    version: result.data.version,
  };
};

export const createInitialSyncConfig = (age: {
  recipients: string[];
}): RawSyncConfig => {
  return {
    version: AppConstants.SYNC.CONFIG_VERSION,
    // A freshly created repository is at the current format by construction.
    repositoryFormat: AppConstants.SYNC.REPOSITORY_FORMAT,
    age,
    profiles: [],
    entries: [],
  };
};

export const formatSyncConfig = (config: RawSyncConfig) => {
  return ensureTrailingNewline(JSON.stringify(config, null, 2));
};

export const resolveSyncConfigFilePath = (syncDirectory: string) => {
  return join(syncDirectory, AppConstants.SYNC.CONFIG_FILE_NAME);
};

export const readSyncConfig = async (
  syncDirectory: string,
  context: SyncConfigResolutionContext,
): Promise<ResolvedSyncConfig> => {
  const filePath = await validateJsoncConfigPath(
    resolveSyncConfigFilePath(syncDirectory),
  );
  try {
    const contents = await readFile(filePath, "utf8");
    const parsed = parseJsonc(contents);
    const migration = applyConfigMigrations(
      parsed,
      syncConfigMigrationRegistry,
      AppConstants.SYNC.CONFIG_VERSION,
      filePath,
    );
    const resolved = parseSyncConfig(migration.config, context);

    assertRepositoryFormatSupported(
      resolved.repositoryFormat ?? 0,
      AppConstants.SYNC.REPOSITORY_FORMAT,
      AppConstants.SYNC.MIN_SUPPORTED_REPOSITORY_FORMAT,
      `Config file: ${filePath}`,
    );

    // Persist only after validation succeeds, via the shared writer, so an
    // invalid migration result is never written to disk.
    if (migration.migrated && migration.originalVersion !== undefined) {
      await persistMigratedConfig(
        filePath,
        parsed,
        migration.config,
        migration.originalVersion,
      );
    }

    return resolved;
  } catch (error: unknown) {
    if (error instanceof DotweaveError) {
      throw error;
    }

    if (error instanceof SyntaxError) {
      throw new DotweaveError("Sync configuration is not valid JSON.", {
        code: "CONFIG_INVALID_JSON",
        details: [`Config file: ${filePath}`, error.message],
        hint: `Fix the JSON syntax in ${AppConstants.SYNC.CONFIG_FILE_NAME}, then run the command again.`,
      });
    }

    throw new DotweaveError("Failed to read sync configuration.", {
      code: "CONFIG_READ_FAILED",
      details: [
        `Config file: ${filePath}`,
        ...(error instanceof Error ? [error.message] : []),
      ],
      hint: "Run 'dotweave init' if the sync directory has not been initialized yet.",
    });
  }
};
