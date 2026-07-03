import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";
import type { ResolvedSyncConfigEntry } from "#app/config/sync-schema.ts";
import { createTemporaryDirectory } from "#test/helpers/sync-fixture.ts";
import type { FileLikeSnapshotNode } from "./local-snapshot.ts";
import {
  buildDesiredDirectoryKeys,
  buildPullCounts,
  collectDeletableLocalKeys,
} from "./pull-apply.ts";

const temporaryDirectories: string[] = [];

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory("dotweave-pull-apply-");
  temporaryDirectories.push(directory);
  return directory;
};

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

const createDirectoryEntry = (
  repoPath = ".config/app",
): ResolvedSyncConfigEntry => ({
  configuredLocalPath: { default: "~/.config/app" },
  configuredMode: { default: "normal" },
  kind: "directory",
  localPath: "/tmp/home/.config/app",
  mode: "normal",
  modeExplicit: false,
  permissionExplicit: false,
  profiles: [],
  profilesExplicit: false,
  repoPath,
});

const plainFileNode: FileLikeSnapshotNode = {
  contents: new Uint8Array([1]),
  executable: false,
  secret: false,
  type: "file",
};

const secretFileNode: FileLikeSnapshotNode = {
  contents: new Uint8Array([2]),
  executable: false,
  secret: true,
  type: "file",
};

const symlinkNode: FileLikeSnapshotNode = {
  linkTarget: "../target",
  type: "symlink",
};

describe("pull apply helpers", () => {
  it("builds desired directory keys for every nested materialized node", () => {
    const desiredNodes = new Map([
      ["config/settings.json", plainFileNode],
      ["config/nested/theme.json", plainFileNode],
      ["state/cache/index.json", secretFileNode],
    ]);

    expect(
      [
        ...buildDesiredDirectoryKeys(createDirectoryEntry(), desiredNodes),
      ].sort(),
    ).toEqual([
      ".config/app/",
      ".config/app/config/",
      ".config/app/config/nested/",
      ".config/app/state/",
      ".config/app/state/cache/",
    ]);
  });

  it("counts plain, secret, symlink, and directory materializations", () => {
    expect(
      buildPullCounts([
        undefined,
        {
          desiredKeys: new Set<string>(),
          type: "absent",
        },
        {
          desiredKeys: new Set([".gitconfig"]),
          node: plainFileNode,
          type: "file",
        },
        {
          desiredKeys: new Set([".config/current"]),
          node: symlinkNode,
          type: "file",
        },
        {
          desiredKeys: new Set([
            ".config/app/",
            ".config/app/plain.txt",
            ".config/app/secret.txt",
            ".config/app/current",
          ]),
          nodes: new Map<string, FileLikeSnapshotNode>([
            ["plain.txt", plainFileNode],
            ["secret.txt", secretFileNode],
            ["current", symlinkNode],
          ]),
          type: "directory",
        },
      ]),
    ).toEqual({
      decryptedFileCount: 1,
      directoryCount: 1,
      plainFileCount: 2,
      symlinkCount: 2,
    });
  });

  it("marks stale local children before their now-empty parent directory", async () => {
    const workspace = await createWorkspace();
    const parent = join(workspace, "app");
    const emptyChild = join(parent, "empty");
    const staleFile = join(parent, "stale.txt");

    await mkdir(emptyChild, { recursive: true });
    await writeFile(staleFile, "stale\n", "utf8");

    const result = await collectDeletableLocalKeys(
      new Set([".config/app/", ".config/app/empty/", ".config/app/stale.txt"]),
      new Set(),
      new Map([
        [".config/app/", parent],
        [".config/app/empty/", emptyChild],
        [".config/app/stale.txt", staleFile],
      ]),
    );

    expect(result.at(-1)).toBe(".config/app/");
    expect(new Set(result.slice(0, -1))).toEqual(
      new Set([".config/app/empty/", ".config/app/stale.txt"]),
    );
  });

  it("does not mark a stale directory when unmanaged local children remain", async () => {
    const workspace = await createWorkspace();
    const parent = join(workspace, "app");
    const staleFile = join(parent, "stale.txt");
    const unmanagedFile = join(parent, "local-only.txt");

    await mkdir(parent, { recursive: true });
    await writeFile(staleFile, "stale\n", "utf8");
    await writeFile(unmanagedFile, "keep\n", "utf8");

    await expect(
      collectDeletableLocalKeys(
        new Set([".config/app/", ".config/app/stale.txt"]),
        new Set(),
        new Map([
          [".config/app/", parent],
          [".config/app/stale.txt", staleFile],
        ]),
      ),
    ).resolves.toEqual([".config/app/stale.txt"]);
  });
});
