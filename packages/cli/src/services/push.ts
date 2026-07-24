import { join } from "node:path";
import { AppConstants } from "#app/config/constants.ts";
import type { ResolvedSyncConfig } from "#app/config/sync-schema.ts";
import { getPathStats, removePathAtomically } from "#app/lib/filesystem.ts";
import { requireGitRepository } from "#app/lib/git.ts";
import { limitConcurrency } from "#app/lib/promise.ts";
import { buildLocalSnapshot, type SnapshotNode } from "./local-snapshot.ts";
import {
  buildArtifactKey,
  buildRepoArtifacts,
  collectArtifactLeafKeys,
  collectExistingArtifactKeys,
  nearestEntryOwnsArtifact,
  parseArtifactRelativePath,
  type RepoArtifact,
  resolveArtifactLogicalPath,
  resolveArtifactRelativePath,
  writeArtifactsToDirectory,
} from "./repo-artifacts.ts";
import { ensureRepositoryFormat } from "./repo-format.ts";
import { ensureManagedSecretArtifactIgnoreRules } from "./repository-ignore.ts";
import {
  type EffectiveSyncConfig,
  loadSyncConfig,
  resolveSyncPaths,
} from "./sync-context.ts";

export type PushRequest = Readonly<{
  dryRun: boolean;
  profile?: string;
}>;

export type PushResult = Readonly<{
  deletedArtifactCount: number;
  directoryCount: number;
  dryRun: boolean;
  encryptedFileCount: number;
  plainFileCount: number;
  symlinkCount: number;
}>;

export type PushPlan = Readonly<{
  artifacts: readonly RepoArtifact[];
  counts: ReturnType<typeof buildPushCounts>;
  deletedArtifactKeys?: ReadonlySet<string>;
  deletedArtifactCount: number;
  desiredArtifactKeys: ReadonlySet<string>;
  existingArtifactKeys: ReadonlySet<string>;
  staleReplacementDirectoryRoots?: readonly string[];
  snapshot: ReadonlyMap<string, SnapshotNode>;
}>;

const buildPushCounts = (snapshot: ReadonlyMap<string, SnapshotNode>) => {
  let directoryCount = 0;
  let encryptedFileCount = 0;
  let plainFileCount = 0;
  let symlinkCount = 0;

  for (const node of snapshot.values()) {
    if (node.type === "directory") {
      directoryCount += 1;
      continue;
    }

    if (node.type === "symlink") {
      symlinkCount += 1;
      continue;
    }

    if (node.secret) {
      encryptedFileCount += 1;
    } else {
      plainFileCount += 1;
    }
  }

  return {
    directoryCount,
    encryptedFileCount,
    plainFileCount,
    symlinkCount,
  };
};

export const buildPushPlan = async (
  config: EffectiveSyncConfig,
  syncDirectory: string,
  ownershipConfig: Pick<ResolvedSyncConfig, "entries" | "profiles"> = config,
): Promise<PushPlan> => {
  const snapshot = await buildLocalSnapshot(config);
  const artifacts = await buildRepoArtifacts(snapshot, config);
  const artifactKeyPairs = artifacts.map((artifact) => {
    return { artifact, key: buildArtifactKey(artifact) };
  });
  const desiredArtifactKeys = new Set(
    artifactKeyPairs.map(({ key }) => {
      return key;
    }),
  );
  const existingArtifactKeys = await collectExistingArtifactKeys(
    syncDirectory,
    config,
    ownershipConfig,
  );
  const staleArtifactKeys = [...existingArtifactKeys].filter((key) => {
    return !desiredArtifactKeys.has(key);
  });
  const staleArtifactKeySet = new Set(staleArtifactKeys);
  const replacementPlan = await collectStaleReplacementDirectoryRoots(
    syncDirectory,
    artifacts,
    staleArtifactKeySet,
    ownershipConfig,
  );
  const writableArtifacts = artifactKeyPairs.flatMap(({ artifact, key }) => {
    return replacementPlan.protectedArtifactKeys.has(key) ? [] : [artifact];
  });
  const writableArtifactKeys = new Set(
    writableArtifacts.map((artifact) => {
      return buildArtifactKey(artifact);
    }),
  );
  const deletedArtifactKeys = new Set([
    ...staleArtifactKeys,
    ...replacementPlan.deletedArtifactKeys,
  ]);

  return {
    artifacts: writableArtifacts,
    counts: buildPushCounts(snapshot),
    deletedArtifactCount: deletedArtifactKeys.size,
    deletedArtifactKeys,
    desiredArtifactKeys: writableArtifactKeys,
    existingArtifactKeys,
    staleReplacementDirectoryRoots: replacementPlan.roots,
    snapshot,
  };
};

export const buildPushPlanPreview = (plan: PushPlan) => {
  const createdOrUpdated = [
    ...new Set(plan.artifacts.map((artifact) => artifact.repoPath)),
  ].sort((left, right) => {
    return left.localeCompare(right);
  });
  const deletedArtifactKeys =
    plan.deletedArtifactKeys ??
    new Set(
      [...plan.existingArtifactKeys].filter((key) => {
        return !plan.desiredArtifactKeys.has(key);
      }),
    );
  const deleted = [...deletedArtifactKeys].sort((left, right) => {
    return left.localeCompare(right);
  });

  return [...createdOrUpdated.slice(0, 4), ...deleted.slice(0, 4)].slice(0, 6);
};

export const buildPushResultFromPlan = (
  plan: PushPlan,
  dryRun: boolean,
): PushResult => {
  return {
    deletedArtifactCount: plan.deletedArtifactCount,
    dryRun,
    ...plan.counts,
  };
};

const collectStaleReplacementDirectoryRoots = async (
  syncDirectory: string,
  artifacts: readonly RepoArtifact[],
  staleArtifactKeys: ReadonlySet<string>,
  ownershipConfig: Pick<ResolvedSyncConfig, "entries" | "profiles">,
) => {
  const roots: string[] = [];
  const deletedArtifactKeys = new Set<string>();
  const protectedArtifactKeys = new Set<string>();

  for (const artifact of artifacts) {
    if (artifact.kind === "directory") {
      continue;
    }

    const relativePath = resolveArtifactRelativePath(artifact);
    const logicalPath = resolveArtifactLogicalPath(artifact);
    const artifactPath = join(syncDirectory, ...relativePath.split("/"));
    const stats = await getPathStats(artifactPath);

    if (stats?.isDirectory() !== true) {
      continue;
    }

    const parsedRoot = parseArtifactRelativePath(relativePath);
    const inactiveDirectoryOwner = nearestEntryOwnsArtifact(
      ownershipConfig.entries,
      parsedRoot,
      "directory",
    );

    if (inactiveDirectoryOwner) {
      protectedArtifactKeys.add(buildArtifactKey(artifact));
      continue;
    }

    const leafKeys = new Set<string>();
    await collectArtifactLeafKeys(
      artifactPath,
      leafKeys,
      logicalPath,
      undefined,
      true,
    );

    if (leafKeys.size === 0) {
      roots.push(relativePath);
      deletedArtifactKeys.add(`${logicalPath}/`);
      continue;
    }

    if (
      [...leafKeys].every((leafKey) => {
        return staleArtifactKeys.has(leafKey);
      })
    ) {
      roots.push(relativePath);
      continue;
    }

    protectedArtifactKeys.add(buildArtifactKey(artifact));
  }

  return { deletedArtifactKeys, protectedArtifactKeys, roots };
};

export const pushChanges = async (
  request: PushRequest,
): Promise<PushResult> => {
  const { syncDirectory } = resolveSyncPaths();

  await requireGitRepository(syncDirectory);

  const { effectiveConfig: config, fullConfig } = await loadSyncConfig(
    syncDirectory,
    {
      ...(request.profile === undefined ? {} : { profile: request.profile }),
    },
  );

  // Bring the repository up to the current on-disk format (e.g. convert legacy
  // physical symlinks to metadata files) before planning, so the plan reflects
  // the migrated state. Skipped on dry-run since it writes to the repository.
  if (!request.dryRun) {
    await ensureRepositoryFormat(syncDirectory, fullConfig);
  }

  const plan = await buildPushPlan(config, syncDirectory, fullConfig);

  if (!request.dryRun) {
    await ensureManagedSecretArtifactIgnoreRules(syncDirectory);

    await limitConcurrency(
      AppConstants.SYNC.DEFAULT_CONCURRENCY,
      plan.staleReplacementDirectoryRoots ?? [],
      async (relativePath) => {
        await removePathAtomically(
          join(syncDirectory, ...relativePath.split("/")),
        );
      },
    );

    await limitConcurrency(
      AppConstants.SYNC.DEFAULT_CONCURRENCY,
      [...plan.existingArtifactKeys].filter((key) => {
        return !plan.desiredArtifactKeys.has(key);
      }),
      async (staleKey) => {
        const relativePath = staleKey.endsWith("/")
          ? staleKey.slice(0, -1)
          : staleKey;

        await removePathAtomically(
          join(syncDirectory, "profiles", ...relativePath.split("/")),
        );
      },
    );

    await writeArtifactsToDirectory(syncDirectory, plan.artifacts, config.age);
  }

  return buildPushResultFromPlan(plan, request.dryRun);
};
