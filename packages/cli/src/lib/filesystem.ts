import { randomUUID } from "node:crypto";
import {
  access,
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  readlink,
  rename,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, isAbsolute, join } from "node:path";
import { DotweaveError } from "#app/lib/error.ts";
import { buildExecutableMode, isExecutableMode } from "#app/lib/file-mode.ts";

/**
 * @description
 * Checks whether a filesystem path currently exists.
 */
export const pathExists = async (path: string) => {
  try {
    await access(path);
    return true;
  } catch (error: unknown) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
};

/**
 * @description
 * Reads path metadata while treating missing paths as an absent result.
 */
export const getPathStats = async (path: string) => {
  try {
    return await lstat(path);
  } catch (error: unknown) {
    if (
      error instanceof Error &&
      "code" in error &&
      (error.code === "ENOENT" || error.code === "ENOTDIR")
    ) {
      return undefined;
    }
    throw error;
  }
};

/**
 * @description
 * Reads path metadata while following symlinks and treating missing paths as an absent result.
 */
export const getFollowedPathStats = async (path: string) => {
  try {
    return await stat(path);
  } catch (error: unknown) {
    if (
      error instanceof Error &&
      "code" in error &&
      (error.code === "ENOENT" || error.code === "ENOTDIR")
    ) {
      return undefined;
    }
    throw error;
  }
};

/**
 * @description
 * Lists directory entries in a stable name-sorted order.
 */
export const listDirectoryEntries = async (path: string) => {
  const entries = await readdir(path, { withFileTypes: true });
  return entries.sort((left, right) => {
    return left.name.localeCompare(right.name);
  });
};

/**
 * @description
 * Writes a regular file node with the permissions dotweave should preserve.
 */
export const writeFileNode = async (
  path: string,
  node: Readonly<{
    contents: string | Uint8Array;
    executable: boolean;
  }>,
  fileMode?: number,
) => {
  await mkdir(dirname(path), { recursive: true });
  if ((await getPathStats(path))?.isSymbolicLink()) {
    await rm(path, { force: true });
  }
  await writeFile(path, node.contents);
  await chmod(path, fileMode ?? buildExecutableMode(node.executable));
};

/**
 * @description
 * Creates a symlink while correctly handling Windows symlink types.
 */
export const createSymlink = async (
  target: string,
  path: string,
  type?: "file" | "dir" | "junction",
) => {
  if (process.platform !== "win32") {
    await symlink(target, path);
    return;
  }

  // On Windows, the symlink type (file, dir, junction) must be specified.
  if (type !== undefined) {
    await symlink(target, path, type);
    return;
  }

  const absoluteTarget = isAbsolute(target)
    ? target
    : join(dirname(path), target);
  const stats = await getFollowedPathStats(absoluteTarget);

  if (stats?.isDirectory()) {
    // Prefer a real directory symlink: it stores the target verbatim, so a
    // relative target stays relative and the link remains portable across
    // machines. A junction always stores an absolute target, so it is only a
    // fallback for when the OS denies symlink creation (no Developer Mode or
    // administrator privileges).
    try {
      await symlink(target, path, "dir");
    } catch (error: unknown) {
      if (
        error instanceof Error &&
        "code" in error &&
        (error.code === "EPERM" || error.code === "EINVAL")
      ) {
        await symlink(absoluteTarget, path, "junction");
        return;
      }

      throw error;
    }

    return;
  }

  await symlink(target, path, "file");
};

/**
 * @description
 * Replaces a path with a symlink node and its target.
 */
export const writeSymlinkNode = async (path: string, linkTarget: string) => {
  await mkdir(dirname(path), { recursive: true });
  await rm(path, { force: true, recursive: true });
  await createSymlink(linkTarget, path);
};

/**
 * @description
 * Copies a filesystem node into the sync layout while preserving supported node types.
 */
export const copyFilesystemNode = async (
  sourcePath: string,
  targetPath: string,
  stats?: Awaited<ReturnType<typeof lstat>>,
) => {
  const sourceStats = stats ?? (await lstat(sourcePath));

  if (sourceStats.isDirectory()) {
    await mkdir(targetPath, { recursive: true });

    const entries = await listDirectoryEntries(sourcePath);

    for (const entry of entries) {
      await copyFilesystemNode(
        join(sourcePath, entry.name),
        join(targetPath, entry.name),
      );
    }

    return;
  }

  if (sourceStats.isSymbolicLink()) {
    const linkTarget = await readlink(sourcePath);
    await writeSymlinkNode(targetPath, linkTarget);

    return;
  }

  if (!sourceStats.isFile()) {
    throw new DotweaveError(`Unsupported filesystem entry: ${sourcePath}`);
  }

  await writeFileNode(targetPath, {
    contents: await readFile(sourcePath),
    executable: isExecutableMode(sourceStats.mode),
  });
};

/**
 * @description
 * Swaps a staged path into place with rollback protection for the previous target.
 */
export const replacePathAtomically = async (
  targetPath: string,
  nextPath: string,
) => {
  const backupPath = join(
    dirname(targetPath),
    `.${basename(targetPath)}.dotweave-sync-backup-${randomUUID()}`,
  );
  const existingStats = await getPathStats(targetPath);
  let targetMoved = false;

  try {
    if (existingStats !== undefined) {
      await rename(targetPath, backupPath);
      targetMoved = true;
    }

    await rename(nextPath, targetPath);

    if (targetMoved) {
      await rm(backupPath, { force: true, recursive: true });
    }
  } catch (error: unknown) {
    if (targetMoved && !(await pathExists(targetPath))) {
      await rename(backupPath, targetPath).catch(() => {});
    }

    throw error;
  } finally {
    await rm(backupPath, { force: true, recursive: true }).catch(() => {});
  }
};

/**
 * @description
 * Removes a path through a temporary rename so deletion is completed atomically.
 */
export const removePathAtomically = async (targetPath: string) => {
  const stats = await getPathStats(targetPath);

  if (stats === undefined) {
    return;
  }

  const backupPath = join(
    dirname(targetPath),
    `.${basename(targetPath)}.dotweave-sync-remove-${randomUUID()}`,
  );

  await rename(targetPath, backupPath);
  await rm(backupPath, { force: true, recursive: true });
};

/**
 * @description
 * Writes text content through a staging directory before replacing the target file.
 */
export const writeTextFileAtomically = async (
  targetPath: string,
  contents: string,
) => {
  await mkdir(dirname(targetPath), { recursive: true });
  const stagingDirectory = await mkdtemp(
    join(dirname(targetPath), `.${basename(targetPath)}.dotweave-sync-`),
  );
  const stagedPath = join(stagingDirectory, basename(targetPath));

  try {
    await writeFile(stagedPath, contents, "utf8");
    await replacePathAtomically(targetPath, stagedPath);
  } finally {
    await rm(stagingDirectory, { force: true, recursive: true });
  }
};
