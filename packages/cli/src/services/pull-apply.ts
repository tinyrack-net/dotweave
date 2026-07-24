import { realpathSync } from "node:fs";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
} from "node:fs/promises";
import { basename, dirname, join, posix } from "node:path";
import { AppConstants } from "#app/config/constants.ts";
import {
  collectChildEntryPaths,
  findOwningSyncEntry,
  resolveSyncRule,
} from "#app/config/sync-queries.ts";
import type {
  ResolvedSyncConfig,
  ResolvedSyncConfigEntry,
} from "#app/config/sync-schema.ts";
import {
  fileContentsEqual,
  shouldNormalizeTextLineEndings,
} from "#app/lib/content.ts";
import { DotweaveError } from "#app/lib/error.ts";
import {
  buildSearchableDirectoryMode,
  isExecutableMode,
  supportsPosixFileModes,
} from "#app/lib/file-mode.ts";
import {
  createSymlink,
  getFollowedPathStats,
  getPathStats,
  listDirectoryEntries,
  removePathAtomically,
  replacePathAtomically,
  writeFileNode,
} from "#app/lib/filesystem.ts";
import {
  buildDirectoryKey,
  normalizeLinkTarget,
  toNativeLinkTarget,
} from "#app/lib/path.ts";
import { limitConcurrency } from "#app/lib/promise.ts";
import type { FileLikeSnapshotNode, SnapshotNode } from "./local-snapshot.ts";
import type { EffectiveSyncConfig } from "./sync-context.ts";

export type EntryMaterialization =
  | Readonly<{
      desiredKeys: ReadonlySet<string>;
      type: "absent";
    }>
  | Readonly<{
      desiredKeys: ReadonlySet<string>;
      node: FileLikeSnapshotNode;
      type: "file";
    }>
  | Readonly<{
      desiredKeys: ReadonlySet<string>;
      nodes: ReadonlyMap<string, FileLikeSnapshotNode>;
      type: "directory";
    }>;

export const buildDesiredDirectoryKeys = (
  entry: ResolvedSyncConfigEntry,
  desiredNodes: ReadonlyMap<string, FileLikeSnapshotNode>,
) => {
  const desiredDirectoryKeys = new Set<string>([
    buildDirectoryKey(entry.repoPath),
  ]);

  for (const relativePath of desiredNodes.keys()) {
    const segments = relativePath.split("/");

    for (let index = 1; index < segments.length; index += 1) {
      desiredDirectoryKeys.add(
        buildDirectoryKey(
          posix.join(entry.repoPath, ...segments.slice(0, index)),
        ),
      );
    }
  }

  return desiredDirectoryKeys;
};

export const buildEntryMaterialization = (
  entry: ResolvedSyncConfigEntry,
  snapshot: ReadonlyMap<string, SnapshotNode>,
  config: Pick<ResolvedSyncConfig, "entries">,
): EntryMaterialization => {
  if (entry.kind === "file") {
    const node = snapshot.get(entry.repoPath);

    if (node === undefined) {
      return {
        desiredKeys: new Set<string>(),
        type: "absent",
      };
    }

    if (node.type === "directory") {
      throw new DotweaveError(
        "File sync entry resolves to a directory in the repository.",
        {
          code: "FILE_ENTRY_RESOLVES_DIRECTORY",
          details: [`Repository path: ${entry.repoPath}`],
          hint: "Run 'dotweave push' or fix the repository so this path is stored as a file.",
        },
      );
    }

    return {
      desiredKeys: new Set<string>([entry.repoPath]),
      node,
      type: "file",
    };
  }

  const rootNode = snapshot.get(entry.repoPath);

  if (rootNode !== undefined && rootNode.type !== "directory") {
    throw new DotweaveError(
      "Directory sync entry resolves to a file in the repository.",
      {
        code: "DIRECTORY_ENTRY_RESOLVES_FILE",
        details: [`Repository path: ${entry.repoPath}`],
        hint: "Run 'dotweave push' or fix the repository so this path is stored as a directory.",
      },
    );
  }

  const nodes = new Map<string, FileLikeSnapshotNode>();
  const desiredKeys = new Set<string>();
  const childEntryPaths = collectChildEntryPaths(config, entry);

  for (const [repoPath, node] of snapshot.entries()) {
    if (!repoPath.startsWith(`${entry.repoPath}/`)) {
      continue;
    }

    if (node.type === "directory") {
      continue;
    }

    if (childEntryPaths.has(repoPath)) {
      continue;
    }

    if (findOwningSyncEntry(config, repoPath) !== entry) {
      continue;
    }

    const relativePath = repoPath.slice(entry.repoPath.length + 1);

    nodes.set(relativePath, node);
    desiredKeys.add(repoPath);
  }

  if (rootNode === undefined && nodes.size === 0) {
    return {
      desiredKeys,
      type: "absent",
    };
  }

  desiredKeys.add(buildDirectoryKey(entry.repoPath));

  return {
    desiredKeys,
    nodes,
    type: "directory",
  };
};

const materializedDirectoryModeMatches = (
  actualMode: number,
  fileMode?: number,
) => {
  if (!supportsPosixFileModes()) {
    return true;
  }

  if (fileMode === undefined) {
    return true;
  }

  const maskedActualMode = actualMode & 0o777;

  return maskedActualMode === (buildSearchableDirectoryMode(fileMode) & 0o777);
};

const materializedFileModeMatches = (
  actualMode: number,
  executable: boolean,
  fileMode?: number,
) => {
  if (!supportsPosixFileModes()) {
    return true;
  }

  const maskedActualMode = actualMode & 0o777;

  if (fileMode === undefined) {
    return isExecutableMode(maskedActualMode) === executable;
  }

  return maskedActualMode === (fileMode & 0o777);
};

const isMaterializedFileLikeNodeCurrent = async (
  targetPath: string,
  node: FileLikeSnapshotNode,
  fileMode?: number,
) => {
  const stats = await getPathStats(targetPath);

  if (stats === undefined) {
    return false;
  }

  if (node.type === "symlink") {
    if (!stats.isSymbolicLink()) {
      return false;
    }

    const currentLinkTarget = await readlink(targetPath);

    return (
      normalizeLinkTarget(currentLinkTarget, dirname(targetPath)) ===
      normalizeLinkTarget(node.linkTarget, dirname(targetPath))
    );
  }

  if (!stats.isFile()) {
    return false;
  }

  const currentContents = await readFile(targetPath);

  return (
    fileContentsEqual(node.contents, currentContents, {
      normalizeTextLineEndings: shouldNormalizeTextLineEndings(),
    }) && materializedFileModeMatches(stats.mode, node.executable, fileMode)
  );
};

const resolveStagingParentDirectory = (targetPath: string) => {
  const parentDirectory = dirname(targetPath);

  if (process.platform !== "win32") {
    return parentDirectory;
  }

  try {
    return realpathSync.native(parentDirectory);
  } catch {
    return parentDirectory;
  }
};

const stageAndReplacePath = async (
  targetPath: string,
  node: FileLikeSnapshotNode,
  fileMode?: number,
) => {
  await mkdir(dirname(targetPath), { recursive: true });
  const stagingDirectory = await mkdtemp(
    join(
      resolveStagingParentDirectory(targetPath),
      `.${basename(targetPath)}.dotweave-sync-`,
    ),
  );
  const stagedPath = join(stagingDirectory, basename(targetPath));

  try {
    if (node.type === "symlink") {
      await createSymlink(toNativeLinkTarget(node.linkTarget), stagedPath);
    } else {
      await writeFileNode(stagedPath, node, fileMode);
    }

    await replacePathAtomically(targetPath, stagedPath);
  } finally {
    await rm(stagingDirectory, { force: true, recursive: true });
  }
};

const stageAndReplaceDirectoryPath = async (
  targetPath: string,
  fileMode?: number,
) => {
  await mkdir(dirname(targetPath), { recursive: true });
  const stagingDirectory = await mkdtemp(
    join(
      resolveStagingParentDirectory(targetPath),
      `.${basename(targetPath)}.dotweave-sync-`,
    ),
  );

  try {
    if (fileMode !== undefined) {
      await chmod(stagingDirectory, buildSearchableDirectoryMode(fileMode));
    }

    await replacePathAtomically(targetPath, stagingDirectory);
  } finally {
    await rm(stagingDirectory, { force: true, recursive: true });
  }
};

const ensureMaterializedDirectoryPath = async (
  targetPath: string,
  fileMode?: number,
) => {
  const stats = await getFollowedPathStats(targetPath);

  if (stats === undefined) {
    await mkdir(targetPath, { recursive: true });

    if (fileMode !== undefined) {
      await chmod(targetPath, buildSearchableDirectoryMode(fileMode));
    }

    return;
  }

  if (!stats.isDirectory()) {
    await stageAndReplaceDirectoryPath(targetPath, fileMode);
    return;
  }

  if (
    fileMode !== undefined &&
    !materializedDirectoryModeMatches(stats.mode, fileMode)
  ) {
    await chmod(targetPath, buildSearchableDirectoryMode(fileMode));
  }
};

export const collectLocalLeafKeys = async (
  targetPath: string,
  repoPathPrefix: string,
  keys: Set<string>,
  keyToLocalPath: Map<string, string> | undefined,
  childEntryPaths: ReadonlySet<string>,
  prefix?: string,
  providedStats?: Awaited<ReturnType<typeof getPathStats>>,
) => {
  const stats = providedStats ?? (await getPathStats(targetPath));

  if (stats === undefined) {
    return;
  }

  if (!stats.isDirectory()) {
    keys.add(repoPathPrefix);
    keyToLocalPath?.set(repoPathPrefix, targetPath);

    return;
  }

  const currentRepoPath =
    prefix === undefined ? repoPathPrefix : posix.join(repoPathPrefix, prefix);
  const directoryKey = buildDirectoryKey(currentRepoPath);
  keys.add(directoryKey);
  keyToLocalPath?.set(directoryKey, targetPath);

  const entries = await listDirectoryEntries(targetPath);

  for (const entry of entries) {
    const absolutePath = join(targetPath, entry.name);
    const relativePath =
      prefix === undefined ? entry.name : `${prefix}/${entry.name}`;
    const childStats = await getPathStats(absolutePath);
    const repoPath = posix.join(repoPathPrefix, relativePath);

    if (childStats === undefined) {
      continue;
    }

    if (childEntryPaths.has(repoPath)) {
      continue;
    }

    if (childStats?.isDirectory()) {
      await collectLocalLeafKeys(
        absolutePath,
        repoPathPrefix,
        keys,
        keyToLocalPath,
        childEntryPaths,
        relativePath,
      );
      continue;
    }

    keys.add(repoPath);
    keyToLocalPath?.set(repoPath, absolutePath);
  }
};

const buildLocalPathDepth = (localPath: string) => {
  return localPath.split(/[/\\]+/u).length;
};

export const collectDeletableLocalKeys = async (
  existingKeys: ReadonlySet<string>,
  desiredKeys: ReadonlySet<string>,
  keyToLocalPath: ReadonlyMap<string, string>,
) => {
  const deletableKeys: string[] = [];
  const scheduledLocalPaths = new Set<string>();

  const isWindows = process.platform === "win32";
  const desiredKeysForComparison = isWindows
    ? new Set([...desiredKeys].map((key) => key.toLowerCase()))
    : desiredKeys;

  const staleKeys = [...existingKeys]
    .filter((key) => {
      return isWindows
        ? !desiredKeysForComparison.has(key.toLowerCase())
        : !desiredKeysForComparison.has(key);
    })
    .sort((left, right) => {
      const leftPath = keyToLocalPath.get(left) ?? "";
      const rightPath = keyToLocalPath.get(right) ?? "";
      return (
        buildLocalPathDepth(rightPath) - buildLocalPathDepth(leftPath) ||
        rightPath.localeCompare(leftPath)
      );
    });

  for (const key of staleKeys) {
    const localPath = keyToLocalPath.get(key);

    if (localPath === undefined) {
      continue;
    }

    const stats = await getPathStats(localPath);

    if (stats === undefined) {
      continue;
    }

    if (!stats.isDirectory()) {
      deletableKeys.push(key);
      scheduledLocalPaths.add(localPath);
      continue;
    }

    const entries = await listDirectoryEntries(localPath);
    const canDeleteDirectory = entries.every((entry) => {
      return scheduledLocalPaths.has(join(localPath, entry.name));
    });

    if (!canDeleteDirectory) {
      continue;
    }

    deletableKeys.push(key);
    scheduledLocalPaths.add(localPath);
  }

  return deletableKeys;
};

export const countDeletedLocalNodes = async (
  entry: ResolvedSyncConfigEntry,
  desiredKeys: ReadonlySet<string>,
  config: EffectiveSyncConfig,
  existingKeys: Set<string> = new Set<string>(),
  keyToLocalPath?: Map<string, string>,
  deletedKeys?: Set<string>,
) => {
  const rule = resolveSyncRule(config, entry.repoPath, config.activeProfile);

  if (rule === undefined || rule.mode === "ignore") {
    return 0;
  }

  const childEntryPaths =
    entry.kind === "directory"
      ? collectChildEntryPaths(config, entry)
      : new Set<string>();

  const rootStats =
    entry.kind === "directory"
      ? await getFollowedPathStats(entry.localPath)
      : await getPathStats(entry.localPath);

  await collectLocalLeafKeys(
    entry.localPath,
    entry.repoPath,
    existingKeys,
    keyToLocalPath,
    childEntryPaths,
    undefined,
    rootStats,
  );

  const deletableKeys = await collectDeletableLocalKeys(
    existingKeys,
    desiredKeys,
    keyToLocalPath ?? new Map<string, string>(),
  );

  for (const key of deletableKeys) {
    deletedKeys?.add(key);
  }

  return deletableKeys.length;
};

export const collectChangedLocalPaths = async (
  entry: ResolvedSyncConfigEntry,
  materialization: EntryMaterialization,
  config?: EffectiveSyncConfig,
) => {
  if (materialization.type === "absent") {
    if (config === undefined) {
      return [];
    }

    const existingKeys = new Set<string>();
    const keyToLocalPath = new Map<string, string>();
    const deletedKeys = new Set<string>();
    await countDeletedLocalNodes(
      entry,
      materialization.desiredKeys,
      config,
      existingKeys,
      keyToLocalPath,
      deletedKeys,
    );

    return [...deletedKeys]
      .map((key) => {
        return keyToLocalPath.get(key);
      })
      .filter((path): path is string => {
        return path !== undefined;
      })
      .sort((left, right) => {
        return left.localeCompare(right);
      });
  }

  if (materialization.type === "file") {
    return (await isMaterializedFileLikeNodeCurrent(
      entry.localPath,
      materialization.node,
      entry.permission,
    ))
      ? []
      : [entry.localPath];
  }

  const changedLocalPaths: string[] = [];
  const rootStats = await getFollowedPathStats(entry.localPath);

  if (rootStats === undefined || !rootStats.isDirectory()) {
    changedLocalPaths.push(entry.localPath);
  } else if (
    !materializedDirectoryModeMatches(rootStats.mode, entry.permission)
  ) {
    changedLocalPaths.push(entry.localPath);
  }

  for (const relativePath of [...materialization.nodes.keys()].sort(
    (left, right) => {
      return left.localeCompare(right);
    },
  )) {
    const node = materialization.nodes.get(relativePath);

    if (node === undefined) {
      continue;
    }

    const targetPath = join(entry.localPath, ...relativePath.split("/"));

    if (
      !(await isMaterializedFileLikeNodeCurrent(
        targetPath,
        node,
        entry.permission,
      ))
    ) {
      changedLocalPaths.push(targetPath);
    }
  }

  if (config !== undefined) {
    const existingKeys = new Set<string>();
    const keyToLocalPath = new Map<string, string>();
    const deletedKeys = new Set<string>();
    await countDeletedLocalNodes(
      entry,
      materialization.desiredKeys,
      config,
      existingKeys,
      keyToLocalPath,
      deletedKeys,
    );

    for (const key of deletedKeys) {
      const localPath = keyToLocalPath.get(key);

      if (localPath !== undefined) {
        changedLocalPaths.push(localPath);
      }
    }
  }

  return [...new Set(changedLocalPaths)].sort((left, right) => {
    return left.localeCompare(right);
  });
};

export const buildPullCounts = (
  materializations: readonly (EntryMaterialization | undefined)[],
) => {
  let decryptedFileCount = 0;
  let directoryCount = 0;
  let plainFileCount = 0;
  let symlinkCount = 0;

  for (const materialization of materializations) {
    if (materialization === undefined) {
      continue;
    }

    if (materialization.type === "file") {
      if (materialization.node.type === "symlink") {
        symlinkCount += 1;
      } else if (materialization.node.secret) {
        decryptedFileCount += 1;
      } else {
        plainFileCount += 1;
      }

      continue;
    }

    if (materialization.type !== "directory") {
      continue;
    }

    directoryCount += 1;

    for (const node of materialization.nodes.values()) {
      if (node.type === "symlink") {
        symlinkCount += 1;
      } else if (node.secret) {
        decryptedFileCount += 1;
      } else {
        plainFileCount += 1;
      }
    }
  }

  return {
    decryptedFileCount,
    directoryCount,
    plainFileCount,
    symlinkCount,
  };
};

const reconcileMaterializedDirectoryPath = async (
  entry: ResolvedSyncConfigEntry,
  desiredKeys: ReadonlySet<string>,
  desiredNodes: ReadonlyMap<string, FileLikeSnapshotNode>,
  config: EffectiveSyncConfig,
  fileMode?: number,
) => {
  const desiredRootKey = buildDirectoryKey(entry.repoPath);
  const desiredRootExists = desiredKeys.has(desiredRootKey);

  if (desiredRootExists) {
    await ensureMaterializedDirectoryPath(entry.localPath, fileMode);
  }

  const desiredDirectoryKeys = desiredRootExists
    ? buildDesiredDirectoryKeys(entry, desiredNodes)
    : new Set<string>();

  await limitConcurrency(
    AppConstants.SYNC.DEFAULT_CONCURRENCY,
    [...desiredDirectoryKeys].sort((left, right) => {
      return left.localeCompare(right);
    }),
    async (directoryKey) => {
      if (directoryKey === desiredRootKey) {
        return;
      }

      const relativePath = directoryKey.slice(entry.repoPath.length + 1, -1);
      await ensureMaterializedDirectoryPath(
        join(entry.localPath, ...relativePath.split("/")),
        fileMode,
      );
    },
  );

  await limitConcurrency(
    AppConstants.SYNC.DEFAULT_CONCURRENCY,
    [...desiredNodes.keys()].sort((left, right) => {
      return left.localeCompare(right);
    }),
    async (relativePath) => {
      const node = desiredNodes.get(relativePath);

      if (node === undefined) {
        return;
      }

      const targetNodePath = join(entry.localPath, ...relativePath.split("/"));

      if (
        await isMaterializedFileLikeNodeCurrent(targetNodePath, node, fileMode)
      ) {
        return;
      }

      await stageAndReplacePath(targetNodePath, node, fileMode);
    },
  );

  const existingKeys = new Set<string>();
  const keyToLocalPath = new Map<string, string>();
  await countDeletedLocalNodes(
    entry,
    desiredKeys,
    config,
    existingKeys,
    keyToLocalPath,
  );

  const deletableKeys = await collectDeletableLocalKeys(
    existingKeys,
    desiredKeys,
    keyToLocalPath,
  );

  for (const key of deletableKeys) {
    const localPath = keyToLocalPath.get(key);

    if (localPath === undefined) {
      continue;
    }

    await removePathAtomically(localPath);
  }
};

export const applyEntryMaterialization = async (
  entry: ResolvedSyncConfigEntry,
  materialization: EntryMaterialization,
  config: EffectiveSyncConfig,
) => {
  const rule = resolveSyncRule(config, entry.repoPath, config.activeProfile);

  if (rule === undefined || rule.mode === "ignore") {
    return;
  }

  if (materialization.type === "absent") {
    if (entry.kind === "directory") {
      await reconcileMaterializedDirectoryPath(
        entry,
        materialization.desiredKeys,
        new Map(),
        config,
        entry.permission,
      );

      return;
    }

    await removePathAtomically(entry.localPath);

    return;
  }

  if (materialization.type === "file") {
    await stageAndReplacePath(
      entry.localPath,
      materialization.node,
      entry.permission,
    );

    return;
  }

  await reconcileMaterializedDirectoryPath(
    entry,
    materialization.desiredKeys,
    materialization.nodes,
    config,
    entry.permission,
  );
};
