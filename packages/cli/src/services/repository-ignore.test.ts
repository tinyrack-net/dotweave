import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { createTemporaryDirectory } from "../test/helpers/sync-fixture.ts";
import {
  ensureManagedSecretArtifactIgnoreRules,
  managedSecretArtifactIgnoreBlock,
} from "./repository-ignore.ts";

const temporaryDirectories: string[] = [];

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory("dotweave-ignore-test-");

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

describe("repository ignore rules", () => {
  it("creates the managed secret artifact block", async () => {
    const workspace = await createWorkspace();

    await ensureManagedSecretArtifactIgnoreRules(workspace);

    expect(await readFile(join(workspace, ".gitignore"), "utf8")).toBe(
      managedSecretArtifactIgnoreBlock,
    );
  });

  it("appends the managed block after existing user rules", async () => {
    const workspace = await createWorkspace();
    const ignorePath = join(workspace, ".gitignore");

    await mkdir(workspace, { recursive: true });
    await writeFile(ignorePath, "*.dotweave.secret\nbuild/\n", "utf8");

    await ensureManagedSecretArtifactIgnoreRules(workspace);

    expect(await readFile(ignorePath, "utf8")).toBe(
      `*.dotweave.secret\nbuild/\n${managedSecretArtifactIgnoreBlock}`,
    );
  });

  it("replaces an existing managed block without duplicating it", async () => {
    const workspace = await createWorkspace();
    const ignorePath = join(workspace, ".gitignore");

    await mkdir(workspace, { recursive: true });
    await writeFile(
      ignorePath,
      `node_modules/\n# BEGIN dotweave managed secret artifact rules\nold\n# END dotweave managed secret artifact rules\n*.log\n`,
      "utf8",
    );

    await ensureManagedSecretArtifactIgnoreRules(workspace);
    await ensureManagedSecretArtifactIgnoreRules(workspace);

    expect(await readFile(ignorePath, "utf8")).toBe(
      `node_modules/\n*.log\n${managedSecretArtifactIgnoreBlock}`,
    );
  });
});
