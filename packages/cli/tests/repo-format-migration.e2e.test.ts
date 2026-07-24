import { lstat, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { AppConstants } from "../src/config/constants.ts";
import { createSymlink } from "../src/lib/filesystem.ts";
import {
  createSyncE2EContext,
  type SyncE2EContext,
} from "../src/test/helpers/e2e-context.ts";
import { stripAnsi } from "../src/test/helpers/sync-fixture.ts";

let ctx: SyncE2EContext;

const manifestPathOf = (ctx: SyncE2EContext) =>
  join(ctx.xdgDir, "dotweave", "repository", "manifest.jsonc");

const readManifest = async (ctx: SyncE2EContext) =>
  JSON.parse(await readFile(manifestPathOf(ctx), "utf8"));

const writeManifest = async (ctx: SyncE2EContext, manifest: unknown) =>
  writeFile(
    manifestPathOf(ctx),
    `${JSON.stringify(manifest, null, 2)}\n`,
    "utf8",
  );

beforeEach(async () => {
  ctx = await createSyncE2EContext();
});

afterEach(async () => {
  await ctx.cleanup();
});

describe("repository format migration", () => {
  it("migrates a legacy format-0 repository (physical symlink) on push and records the marker", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);

    const realFile = join(ctx.homeDir, ".agents", "note.md");
    const link = join(ctx.homeDir, ".claude", "note.md");
    await mkdir(join(ctx.homeDir, ".agents"), { recursive: true });
    await writeFile(realFile, "# note\n");
    await mkdir(join(ctx.homeDir, ".claude"), { recursive: true });
    await createSymlink(join("..", ".agents", "note.md"), link);

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", link]);
    await ctx.runCli(["push"]);

    const suffix = AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX;
    const plainArtifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".claude",
      "note.md",
    );

    // Downgrade to the legacy format 0: drop the marker and replace the
    // metadata file with a physical symlink at the plain path.
    const manifest = await readManifest(ctx);
    manifest.repositoryFormat = undefined;
    delete manifest.repositoryFormat;
    await writeManifest(ctx, manifest);
    await rm(`${plainArtifact}${suffix}`, { force: true });
    await createSymlink(join("..", ".agents", "note.md"), plainArtifact);

    // Push migrates: converts the physical symlink and records format 1.
    await ctx.runCli(["push"]);

    expect((await readManifest(ctx)).repositoryFormat).toBe(
      AppConstants.SYNC.REPOSITORY_FORMAT,
    );
    await expect(lstat(plainArtifact)).rejects.toThrow();
    expect(await readFile(`${plainArtifact}${suffix}`, "utf8")).toBe(
      "../.agents/note.md",
    );

    // Idempotent: a second push keeps the marker and the metadata file.
    await ctx.runCli(["push"]);
    expect((await readManifest(ctx)).repositoryFormat).toBe(
      AppConstants.SYNC.REPOSITORY_FORMAT,
    );
    expect(await readFile(`${plainArtifact}${suffix}`, "utf8")).toBe(
      "../.agents/note.md",
    );
  }, 120_000);

  it("refuses a repository whose format is newer than the CLI supports", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);

    const manifest = await readManifest(ctx);
    manifest.repositoryFormat = 999;
    await writeManifest(ctx, manifest);

    const result = await ctx.runCli(["status"], { reject: false });
    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain("newer than this CLI supports");
  }, 120_000);
});
