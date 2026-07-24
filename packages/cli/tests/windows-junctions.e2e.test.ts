import { mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { AppConstants } from "../src/config/constants.ts";
import {
  createSyncE2EContext,
  type SyncE2EContext,
} from "../src/test/helpers/e2e-context.ts";
import { stripAnsi } from "../src/test/helpers/sync-fixture.ts";

let ctx: SyncE2EContext;

beforeEach(async () => {
  ctx = await createSyncE2EContext();
});

afterEach(async () => {
  await ctx.cleanup();
});

describe("Windows junction and symlink target normalization", () => {
  const itWindows = it.skipIf(process.platform !== "win32");

  itWindows(
    "should not show pull changes when a tracked directory is a junction on Windows",
    async () => {
      const realDir = join(ctx.homeDir, "real_dir");
      const syncTarget = join(ctx.homeDir, "junction_target");
      const targetFile = join(realDir, "file.txt");

      await mkdir(realDir, { recursive: true });
      await writeFile(targetFile, "content");

      // 1. Initialize and track the path as a directory
      await ctx.runCli(["init"]);
      // Create as real directory first to track it
      await mkdir(syncTarget, { recursive: true });
      await writeFile(join(syncTarget, "placeholder.txt"), "data");
      await ctx.runCli(["track", syncTarget]);
      await ctx.runCli(["push"]);

      // 2. Replace with a junction
      await rm(syncTarget, { force: true, recursive: true });
      await symlink(realDir, syncTarget, "junction");

      // 3. Pull - should follow the junction and update internal files, but NOT replace the junction itself
      const firstPull = await ctx.runCli(["pull", "-y"]);
      expect(stripAnsi(firstPull.stdout)).toContain("Update from repository");

      // Verify it's still a junction (symlink on Node)
      const stats = await import("node:fs/promises").then((m) =>
        m.lstat(syncTarget),
      );
      expect(stats.isSymbolicLink()).toBe(true);

      // 4. Second pull - should be already up to date
      const secondPull = await ctx.runCli(["pull", "-y"]);
      expect(stripAnsi(secondPull.stdout)).toContain("Already up to date");
    },
  );

  itWindows(
    "should normalize relative and absolute symlink targets on Windows",
    async () => {
      const targetDir = join(ctx.homeDir, "link_target_dir");
      const linkPath = join(ctx.homeDir, "link_entry");

      await mkdir(targetDir, { recursive: true });
      await writeFile(join(targetDir, "file.txt"), "content");

      await ctx.runCli(["init"]);

      // 1. Create a local junction (absolute) and push it
      await symlink(targetDir, linkPath, "junction");
      await ctx.runCli(["track", linkPath]);
      await ctx.runCli(["push"]);

      // 2. Manually modify the repo artifact to store a RELATIVE target
      // (simulating a push from Linux/Mac). Symlinks are stored as regular
      // metadata files whose contents are the POSIX-normalized target.
      const repoLinkArtifact = join(
        ctx.xdgDir,
        "dotweave",
        "repository",
        "profiles",
        "default",
        `link_entry${AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX}`,
      );
      const relativeTarget = relative(dirname(linkPath), targetDir);

      await writeFile(
        repoLinkArtifact,
        relativeTarget.replace(/\\/g, "/"),
        "utf8",
      );

      // 3. Pull - should match the absolute local junction with the relative repo target
      // and report "Already up to date" because they point to the same location.
      const pullResult = await ctx.runCli(["pull", "-y"]);
      expect(stripAnsi(pullResult.stdout)).toContain("Already up to date");
    },
  );
});
