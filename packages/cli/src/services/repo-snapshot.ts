import { lstat, readFile, readlink } from "node:fs/promises";
import { join } from "node:path";
import {
  findOwningSyncEntry,
  requireManagedSyncMode,
  resolveSyncRule,
} from "#app/config/sync-queries.ts";
import { decryptSecretFile } from "#app/lib/crypto.ts";
import { DotweaveError, wrapUnknownError } from "#app/lib/error.ts";
import { isExecutableMode } from "#app/lib/file-mode.ts";
import { getPathStats, listDirectoryEntries } from "#app/lib/filesystem.ts";
import { toPosixLinkTarget } from "#app/lib/path.ts";
import { addSnapshotNode, type SnapshotNode } from "./local-snapshot.ts";
import {
  assertStorageSafeRepoPath,
  collectArtifactProfiles,
  parseArtifactRelativePath,
  readCommittedProfileRegistry,
  resolveArtifactRelativePath,
} from "./repo-artifacts.ts";
import type { EffectiveSyncConfig } from "./sync-context.ts";

type RepositorySnapshotConfig = EffectiveSyncConfig;

const isActiveStorageProfile = (
  storageProfile: string,
  config: RepositorySnapshotConfig,
  repoPath: string,
) => {
  const rule = resolveSyncRule(config, repoPath, config.activeProfile);

  if (rule === undefined || rule.mode === "ignore") {
    return false;
  }

  return rule.profile === storageProfile;
};

const resolveSnapshotExecutable = (
  config: RepositorySnapshotConfig,
  repoPath: string,
  artifactMode: number | bigint,
) => {
  const entry = findOwningSyncEntry(config, repoPath);

  return isExecutableMode(entry?.permission ?? artifactMode);
};

const readArtifactLeaf = async (
  absolutePath: string,
  storagePath: string,
  config: RepositorySnapshotConfig,
  snapshot: Map<string, SnapshotNode>,
) => {
  const artifact = parseArtifactRelativePath(storagePath);

  if (!isActiveStorageProfile(artifact.profile, config, artifact.repoPath)) {
    return;
  }

  assertStorageSafeRepoPath(artifact.repoPath);
  const rule = resolveSyncRule(config, artifact.repoPath, config.activeProfile);

  if (rule === undefined) {
    throw new DotweaveError(
      "Repository path is not managed by the current sync configuration.",
      {
        code: "UNMANAGED_SYNC_PATH",
        details: [
          `Repository path: ${artifact.repoPath}`,
          `Context: ${storagePath}`,
        ],
        hint: "Add the parent path to dotweave, or remove stray artifacts from the sync directory.",
      },
    );
  }

  if (rule.profile !== artifact.profile) {
    throw new DotweaveError(
      "Repository artifact is stored under the wrong profile directory.",
      {
        code: "REPO_PROFILE_MISMATCH",
        details: [
          `Repository path: ${artifact.repoPath}`,
          `Stored profile: ${artifact.profile}`,
          `Expected profile: ${rule.profile}`,
        ],
      },
    );
  }

  if (rule.mode === "ignore") {
    return;
  }

  if (artifact.secret) {
    if (rule.mode !== "secret") {
      throw new DotweaveError(
        "Plain sync path is stored as a secret artifact in the repository.",
        {
          code: "PLAIN_STORED_SECRET",
          details: [`Repository path: ${storagePath}`],
        },
      );
    }

    const stats = await lstat(absolutePath);

    if (!stats.isFile()) {
      throw new DotweaveError(
        "Secret repository artifacts must be regular files, not symlinks.",
        {
          code: "SECRET_ARTIFACT_SYMLINK",
          details: [`Repository path: ${storagePath}`],
        },
      );
    }

    let contents: Uint8Array;

    try {
      contents = await decryptSecretFile(
        await readFile(absolutePath, "utf8"),
        config.age.identityFile,
      );
    } catch (error: unknown) {
      throw wrapUnknownError(
        "Failed to decrypt a secret repository artifact.",
        error,
        {
          code: "SECRET_ARTIFACT_DECRYPT_FAILED",
          details: [
            `Repository path: ${storagePath}`,
            `Identity file: ${config.age.identityFile}`,
          ],
        },
      );
    }

    addSnapshotNode(snapshot, artifact.repoPath, {
      contents,
      executable: resolveSnapshotExecutable(
        config,
        artifact.repoPath,
        stats.mode,
      ),
      secret: true,
      type: "file",
    });

    return;
  }

  const mode = requireManagedSyncMode(
    config,
    artifact.repoPath,
    config.activeProfile,
    storagePath,
  );

  if (artifact.symlink) {
    if (mode === "secret") {
      throw new DotweaveError(
        "Secret sync path is stored as a plain artifact in the repository.",
        {
          code: "SECRET_STORED_PLAIN",
          details: [`Repository path: ${storagePath}`],
        },
      );
    }

    const symlinkStats = await lstat(absolutePath);

    if (!symlinkStats.isFile()) {
      throw new DotweaveError(
        "Symlink repository artifacts must be regular metadata files.",
        {
          code: "SYMLINK_ARTIFACT_NOT_FILE",
          details: [`Repository path: ${storagePath}`],
        },
      );
    }

    addSnapshotNode(snapshot, artifact.repoPath, {
      linkTarget: toPosixLinkTarget(await readFile(absolutePath, "utf8")),
      type: "symlink",
    });

    return;
  }

  const stats = await lstat(absolutePath);

  if (stats.isSymbolicLink()) {
    // Repository format 0 compatibility: symlinks stored as physical links
    // (pre-.dotweave.symlink). Still read them so format-0 repositories keep
    // working; `migrations/repo-format-v1.ts` rewrites them to the portable
    // metadata-file format on the next push.
    //
    // REMOVAL: when AppConstants.SYNC.MIN_SUPPORTED_REPOSITORY_FORMAT is raised
    // to 1, delete this branch together with repo-format-v1.ts and its registry
    // entry; format-0 repositories are then refused with REPO_FORMAT_TOO_OLD.
    if (mode === "secret") {
      throw new DotweaveError(
        "Secret sync path is stored as a plain artifact in the repository.",
        {
          code: "SECRET_STORED_PLAIN",
          details: [`Repository path: ${storagePath}`],
        },
      );
    }

    addSnapshotNode(snapshot, artifact.repoPath, {
      linkTarget: toPosixLinkTarget(await readlink(absolutePath)),
      type: "symlink",
    });

    return;
  }

  if (!stats.isFile()) {
    throw new DotweaveError(
      "Repository contains an unsupported plain artifact type.",
      {
        code: "UNSUPPORTED_REPO_ENTRY",
        details: [`Repository path: ${storagePath}`],
      },
    );
  }

  if (mode === "secret") {
    throw new DotweaveError(
      "Secret sync path is stored as a plain artifact in the repository.",
      {
        code: "SECRET_STORED_PLAIN",
        details: [`Repository path: ${storagePath}`],
      },
    );
  }

  addSnapshotNode(snapshot, artifact.repoPath, {
    contents: await readFile(absolutePath),
    executable: resolveSnapshotExecutable(
      config,
      artifact.repoPath,
      stats.mode,
    ),
    secret: false,
    type: "file",
  });
};

const walkArtifactTree = async (
  rootDirectory: string,
  config: RepositorySnapshotConfig,
  snapshot: Map<string, SnapshotNode>,
  prefix = "",
) => {
  const entries = await listDirectoryEntries(rootDirectory);

  for (const entry of entries) {
    const absolutePath = join(rootDirectory, entry.name);
    const storagePath = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
    const stats = await lstat(absolutePath);

    if (stats.isDirectory()) {
      await walkArtifactTree(absolutePath, config, snapshot, storagePath);
      continue;
    }

    await readArtifactLeaf(absolutePath, storagePath, config, snapshot);
  }
};

export const buildRepositorySnapshot = async (
  syncDirectory: string,
  config: RepositorySnapshotConfig,
) => {
  const snapshot = new Map<string, SnapshotNode>();
  const artifactProfiles = collectArtifactProfiles(config);
  const committedProfiles = await readCommittedProfileRegistry(syncDirectory);

  if (committedProfiles !== undefined) {
    for (const profile of committedProfiles) {
      artifactProfiles.add(profile);
    }
  }

  await Promise.all(
    [...artifactProfiles].map(async (profile) => {
      const profileDirectory = join(syncDirectory, "profiles", profile);
      const profileStats = await getPathStats(profileDirectory);

      if (profileStats?.isDirectory()) {
        await walkArtifactTree(
          profileDirectory,
          config,
          snapshot,
          `profiles/${profile}`,
        );
      }
    }),
  );

  for (const entry of config.entries) {
    if (entry.kind !== "directory") {
      continue;
    }

    const rule = resolveSyncRule(config, entry.repoPath, config.activeProfile);

    if (rule === undefined) {
      continue;
    }

    const hasTrackedChildren = [...snapshot.keys()].some((repoPath) => {
      return repoPath.startsWith(`${entry.repoPath}/`);
    });
    const expectedPath = join(
      syncDirectory,
      ...resolveArtifactRelativePath({
        category: "plain",
        profile: rule.profile,
        repoPath: entry.repoPath,
      }).split("/"),
    );
    const expectedStats = await getPathStats(expectedPath);

    if (expectedStats !== undefined && !expectedStats.isDirectory()) {
      throw new DotweaveError(
        "Directory sync entry is not stored as a directory in the repository.",
        {
          code: "DIRECTORY_ENTRY_NOT_DIRECTORY",
          details: [`Repository path: ${entry.repoPath}`],
        },
      );
    }

    if (
      (expectedStats?.isDirectory() ?? false) &&
      (rule.mode !== "ignore" || hasTrackedChildren)
    ) {
      addSnapshotNode(snapshot, entry.repoPath, { type: "directory" });
    }
  }

  return snapshot;
};
