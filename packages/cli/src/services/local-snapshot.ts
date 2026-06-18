import { lstat, readFile, readlink } from "node:fs/promises";
import { join, posix } from "node:path";
import {
  collectChildEntryPaths,
  findOwningSyncEntry,
  requireManagedSyncMode,
} from "#app/config/sync-queries.ts";
import { DotweaveError } from "#app/lib/error.ts";
import { isExecutableMode } from "#app/lib/file-mode.ts";
import { getPathStats, listDirectoryEntries } from "#app/lib/filesystem.ts";
import { assertStorageSafeRepoPath } from "./repo-artifacts.ts";
import type { EffectiveSyncConfig } from "./sync-context.ts";

export type SnapshotNode =
  | Readonly<{
      type: "directory";
    }>
  | Readonly<{
      executable: boolean;
      secret: boolean;
      type: "file";
      contents: Uint8Array;
    }>
  | Readonly<{
      linkTarget: string;
      type: "symlink";
    }>;

export type FileSnapshotNode = Extract<
  SnapshotNode,
  Readonly<{ type: "file" }>
>;

export type FileLikeSnapshotNode = Extract<
  SnapshotNode,
  Readonly<{ type: "file" | "symlink" }>
>;

const resolveSnapshotExecutable = (
  config: EffectiveSyncConfig,
  repoPath: string,
  filesystemMode: number | bigint,
) => {
  const entry = findOwningSyncEntry(config, repoPath);

  return isExecutableMode(entry?.permission ?? filesystemMode);
};

export const addSnapshotNode = (
  snapshot: Map<string, SnapshotNode>,
  repoPath: string,
  node: SnapshotNode,
) => {
  if (snapshot.has(repoPath)) {
    throw new DotweaveError(`Duplicate sync path generated for ${repoPath}`);
  }

  snapshot.set(repoPath, node);
};

const addLocalNode = async (
  snapshot: Map<string, SnapshotNode>,
  config: EffectiveSyncConfig,
  repoPath: string,
  path: string,
  stats: Awaited<ReturnType<typeof lstat>>,
) => {
  assertStorageSafeRepoPath(repoPath);
  const mode = requireManagedSyncMode(config, repoPath, config.activeProfile);

  if (mode === "ignore") {
    return;
  }

  if (stats.isDirectory()) {
    throw new DotweaveError(
      `Expected a file-like path but found a directory: ${path}`,
    );
  }

  if (stats.isSymbolicLink()) {
    if (mode === "secret") {
      throw new DotweaveError(
        `Secret sync paths must be regular files, not symlinks: ${repoPath}`,
      );
    }

    addSnapshotNode(snapshot, repoPath, {
      linkTarget: await readlink(path),
      type: "symlink",
    });

    return;
  }

  if (!stats.isFile()) {
    throw new DotweaveError(`Unsupported filesystem entry: ${path}`);
  }

  addSnapshotNode(snapshot, repoPath, {
    contents: await readFile(path),
    executable: resolveSnapshotExecutable(config, repoPath, stats.mode),
    secret: mode === "secret",
    type: "file",
  });
};

const walkLocalDirectory = async (
  snapshot: Map<string, SnapshotNode>,
  config: EffectiveSyncConfig,
  localDirectory: string,
  repoPathPrefix: string,
  childEntryPaths: ReadonlySet<string>,
) => {
  const entries = await listDirectoryEntries(localDirectory);

  for (const entry of entries) {
    const localPath = join(localDirectory, entry.name);
    const repoPath = posix.join(repoPathPrefix, entry.name);

    if (childEntryPaths.has(repoPath)) {
      continue;
    }

    const stats = await lstat(localPath);

    if (stats.isDirectory()) {
      assertStorageSafeRepoPath(repoPath);
      await walkLocalDirectory(
        snapshot,
        config,
        localPath,
        repoPath,
        childEntryPaths,
      );
      continue;
    }

    await addLocalNode(snapshot, config, repoPath, localPath, stats);
  }
};

export const buildLocalSnapshot = async (config: EffectiveSyncConfig) => {
  const snapshot = new Map<string, SnapshotNode>();

  for (const entry of config.entries) {
    const stats = await getPathStats(entry.localPath);

    if (stats === undefined) {
      continue;
    }

    const entryMode = requireManagedSyncMode(
      config,
      entry.repoPath,
      config.activeProfile,
    );

    if (entry.kind === "file") {
      if (entryMode === "ignore") {
        continue;
      }

      if (stats.isDirectory()) {
        throw new DotweaveError(
          `Sync entry ${entry.repoPath} expects a file, but found a directory: ${entry.localPath}`,
        );
      }

      await addLocalNode(
        snapshot,
        config,
        entry.repoPath,
        entry.localPath,
        stats,
      );
      continue;
    }

    if (!stats.isDirectory()) {
      throw new DotweaveError(
        `Sync entry ${entry.repoPath} expects a directory: ${entry.localPath}`,
      );
    }

    const childEntryPaths = new Set(collectChildEntryPaths(config, entry));

    if (entryMode === "ignore") {
      continue;
    }

    await walkLocalDirectory(
      snapshot,
      config,
      entry.localPath,
      entry.repoPath,
      childEntryPaths,
    );
    addSnapshotNode(snapshot, entry.repoPath, {
      type: "directory",
    });
  }

  return snapshot;
};
