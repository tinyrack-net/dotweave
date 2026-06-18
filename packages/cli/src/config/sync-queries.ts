import { isAbsolute, posix, relative } from "node:path";
import { AppConstants } from "#app/config/constants.ts";
import type {
  PlatformSyncMode,
  ResolvedSyncConfig,
  ResolvedSyncConfigEntry,
  SyncMode,
} from "#app/config/sync-schema.ts";
import { DotweaveError } from "#app/lib/error.ts";

// ---------------------------------------------------------------------------
// Entry lookup
// ---------------------------------------------------------------------------

const matchesEntryPath = (
  entry: Pick<ResolvedSyncConfigEntry, "kind" | "repoPath">,
  repoPath: string,
) => {
  return (
    entry.repoPath === repoPath ||
    (entry.kind === "directory" && repoPath.startsWith(`${entry.repoPath}/`))
  );
};

export const findOwningSyncEntry = (
  config: Pick<ResolvedSyncConfig, "entries">,
  repoPath: string,
): ResolvedSyncConfigEntry | undefined => {
  let best: ResolvedSyncConfigEntry | undefined;

  for (const entry of config.entries) {
    if (
      matchesEntryPath(entry, repoPath) &&
      (best === undefined || entry.repoPath.length > best.repoPath.length)
    ) {
      best = entry;
    }
  }

  return best;
};

type ChildEntryParent =
  | string
  | Pick<ResolvedSyncConfigEntry, "kind" | "localPath" | "repoPath">;

const isNestedRelativePath = (path: string) => {
  return (
    path !== "" &&
    !isAbsolute(path) &&
    path !== ".." &&
    !path.startsWith("../") &&
    !path.startsWith("..\\")
  );
};

const resolveLocalChildRepoPath = (
  parent: Pick<ResolvedSyncConfigEntry, "kind" | "localPath" | "repoPath">,
  child: Pick<ResolvedSyncConfigEntry, "localPath">,
) => {
  if (parent.kind !== "directory") {
    return undefined;
  }

  const relativeLocalPath = relative(parent.localPath, child.localPath);

  if (!isNestedRelativePath(relativeLocalPath)) {
    return undefined;
  }

  return posix.join(parent.repoPath, relativeLocalPath.replaceAll("\\", "/"));
};

export const collectChildEntryPaths = (
  config: Pick<ResolvedSyncConfig, "entries">,
  parent: ChildEntryParent,
): ReadonlySet<string> => {
  const parentRepoPath = typeof parent === "string" ? parent : parent.repoPath;
  const parentEntry = typeof parent === "string" ? undefined : parent;
  const childPaths = new Set<string>();

  for (const entry of config.entries) {
    if (
      entry.repoPath !== parentRepoPath &&
      entry.repoPath.startsWith(`${parentRepoPath}/`)
    ) {
      childPaths.add(entry.repoPath);
    }

    if (parentEntry === undefined || entry === parentEntry) {
      continue;
    }

    const localChildRepoPath = resolveLocalChildRepoPath(parentEntry, entry);

    if (localChildRepoPath !== undefined) {
      childPaths.add(localChildRepoPath);
    }
  }

  return childPaths;
};

export const resolveEntryRelativeRepoPath = (
  entry: Pick<ResolvedSyncConfigEntry, "kind" | "repoPath">,
  repoPath: string,
) => {
  if (entry.kind === "file") {
    return repoPath === entry.repoPath ? "" : undefined;
  }

  if (repoPath === entry.repoPath) {
    return "";
  }

  if (!repoPath.startsWith(`${entry.repoPath}/`)) {
    return undefined;
  }

  return repoPath.slice(entry.repoPath.length + 1);
};

// ---------------------------------------------------------------------------
// Mode / rule resolution
// ---------------------------------------------------------------------------

const resolveProfileForEntry = (
  entry: Pick<ResolvedSyncConfigEntry, "profiles">,
  activeProfile: string | undefined,
): string | undefined => {
  if (entry.profiles.length === 0) {
    return AppConstants.SYNC.DEFAULT_PROFILE;
  }

  const effective =
    activeProfile !== undefined &&
    activeProfile !== AppConstants.SYNC.DEFAULT_PROFILE
      ? activeProfile
      : AppConstants.SYNC.DEFAULT_PROFILE;

  return entry.profiles.includes(effective) ? effective : undefined;
};

export const resolveSyncRule = (
  config: ResolvedSyncConfig,
  repoPath: string,
  activeProfile?: string,
): { mode: SyncMode; profile: string } | undefined => {
  const entry = findOwningSyncEntry(config, repoPath);

  if (entry === undefined) {
    return undefined;
  }

  const profile = resolveProfileForEntry(entry, activeProfile);

  if (profile === undefined) {
    return undefined;
  }

  return { mode: entry.mode, profile };
};

export const resolveSyncMode = (
  config: ResolvedSyncConfig,
  repoPath: string,
  activeProfile?: string,
): SyncMode | undefined => {
  return resolveSyncRule(config, repoPath, activeProfile)?.mode;
};

export const isIgnoredSyncPath = (
  config: ResolvedSyncConfig,
  repoPath: string,
) => {
  return resolveSyncMode(config, repoPath) === "ignore";
};

export const isSecretSyncPath = (
  config: ResolvedSyncConfig,
  repoPath: string,
) => {
  return resolveSyncMode(config, repoPath) === "secret";
};

export const requireManagedSyncMode = (
  config: ResolvedSyncConfig,
  repoPath: string,
  activeProfile?: string,
  context?: string,
) => {
  const mode = resolveSyncMode(config, repoPath, activeProfile);

  if (mode === undefined) {
    throw new DotweaveError(
      "Repository path is not managed by the current sync configuration.",
      {
        code: "UNMANAGED_SYNC_PATH",
        details: [
          `Repository path: ${repoPath}`,
          ...(context === undefined ? [] : [`Context: ${context}`]),
        ],
        hint: "Add the parent path to dotweave, or remove stray artifacts from the sync directory.",
      },
    );
  }

  return mode;
};

// ---------------------------------------------------------------------------
// Profile collection
// ---------------------------------------------------------------------------

export const buildDefaultPlatformMode = (mode: SyncMode): PlatformSyncMode => ({
  default: mode,
});

export const hasPlatformSpecificModeOverride = (
  configuredMode: PlatformSyncMode,
) => {
  return (
    configuredMode.win !== undefined ||
    configuredMode.mac !== undefined ||
    configuredMode.linux !== undefined ||
    configuredMode.wsl !== undefined
  );
};

export const collectAllProfileNames = (
  entries: readonly ResolvedSyncConfigEntry[],
): string[] => {
  const profiles = new Set<string>();

  for (const entry of entries) {
    if (entry.profiles.length === 0) {
      profiles.add(AppConstants.SYNC.DEFAULT_PROFILE);
      continue;
    }

    for (const profile of entry.profiles) {
      profiles.add(profile);
    }
  }

  return [...profiles].sort((left, right) => left.localeCompare(right));
};
