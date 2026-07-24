import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { AppConstants } from "#app/config/constants.ts";
import type { ResolvedSyncConfig } from "#app/config/sync-schema.ts";
import { createSymlink } from "#app/lib/filesystem.ts";
import { migrateRepositoryFormatV0ToV1 } from "./repo-format-v1.ts";

let repoDir: string;

const emptyConfig: ResolvedSyncConfig = {
  entries: [],
  profiles: [],
  version: 8,
};

const suffix = AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX;

beforeEach(async () => {
  repoDir = await mkdtemp(join(tmpdir(), "dotweave-repo-format-"));
});

afterEach(async () => {
  await rm(repoDir, { force: true, recursive: true });
});

describe("migrateRepositoryFormatV0ToV1", () => {
  it("does nothing when there is no profiles directory", async () => {
    await expect(
      migrateRepositoryFormatV0ToV1(repoDir, emptyConfig),
    ).resolves.toBeUndefined();
  });

  it("converts physical symlink artifacts (nested) to metadata files and is idempotent", async () => {
    const profileDir = join(repoDir, "profiles", "default", ".config");
    await mkdir(profileDir, { recursive: true });

    // A regular file that must be left untouched.
    await writeFile(join(profileDir, "keep.txt"), "keep\n", "utf8");

    // A physical file symlink artifact.
    await createSymlink("../.agents/note.md", join(profileDir, "note.md"));

    // A physical directory symlink artifact one level deeper.
    const nested = join(profileDir, "nested");
    await mkdir(nested, { recursive: true });
    await createSymlink("../../.agents/skills", join(nested, "skills"));

    await migrateRepositoryFormatV0ToV1(repoDir, emptyConfig);

    // Physical links are gone; metadata files carry the POSIX target.
    await expect(lstat(join(profileDir, "note.md"))).rejects.toThrow();
    expect(await readFile(join(profileDir, `note.md${suffix}`), "utf8")).toBe(
      "../.agents/note.md",
    );

    await expect(lstat(join(nested, "skills"))).rejects.toThrow();
    expect(await readFile(join(nested, `skills${suffix}`), "utf8")).toBe(
      "../../.agents/skills",
    );

    // Regular file preserved.
    expect(await readFile(join(profileDir, "keep.txt"), "utf8")).toBe("keep\n");

    // Metadata files are regular files, not symlinks.
    expect(
      (await lstat(join(profileDir, `note.md${suffix}`))).isSymbolicLink(),
    ).toBe(false);

    // Idempotent: a second run makes no further changes and does not throw.
    await migrateRepositoryFormatV0ToV1(repoDir, emptyConfig);
    expect(await readFile(join(profileDir, `note.md${suffix}`), "utf8")).toBe(
      "../.agents/note.md",
    );
  });
});
