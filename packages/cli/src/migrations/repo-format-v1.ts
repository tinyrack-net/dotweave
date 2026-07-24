import { lstat, readlink, rm } from "node:fs/promises";
import { join } from "node:path";

import { AppConstants } from "#app/config/constants.ts";
import type { RepoFormatMigrationFn } from "#app/config/repo-format-migration.ts";
import {
  getPathStats,
  listDirectoryEntries,
  writeFileNode,
} from "#app/lib/filesystem.ts";
import { toPosixLinkTarget } from "#app/lib/path.ts";

const physicalProfilesRoot = "profiles";

/**
 * @description
 * Recursively converts every physical symlink artifact under a directory into a
 * `<name>.dotweave.symlink` regular metadata file (format 0 → 1). Real
 * directories are recursed into; regular files are left untouched. Idempotent:
 * once no physical symlinks remain, re-running is a no-op.
 */
const convertPhysicalSymlinks = async (directory: string): Promise<void> => {
  const entries = await listDirectoryEntries(directory);

  for (const entry of entries) {
    const entryPath = join(directory, entry.name);
    const stats = await lstat(entryPath);

    if (stats.isSymbolicLink()) {
      const linkTarget = toPosixLinkTarget(await readlink(entryPath));
      const metadataPath = `${entryPath}${AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX}`;

      await writeFileNode(metadataPath, {
        contents: linkTarget,
        executable: false,
      });
      // Remove only the link node; `rm` unlinks a symlink/junction without
      // recursing into its target.
      await rm(entryPath, { force: true, recursive: true });
      continue;
    }

    if (stats.isDirectory()) {
      await convertPhysicalSymlinks(entryPath);
    }
  }
};

export const migrateRepositoryFormatV0ToV1: RepoFormatMigrationFn = async (
  repositoryDirectory,
) => {
  const profilesDirectory = join(repositoryDirectory, physicalProfilesRoot);

  if ((await getPathStats(profilesDirectory))?.isDirectory() !== true) {
    return;
  }

  await convertPhysicalSymlinks(profilesDirectory);
};
