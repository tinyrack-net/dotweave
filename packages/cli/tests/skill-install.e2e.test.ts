import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

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

describe("skill install CLI e2e", () => {
  it("installs, dry-runs, rejects existing installs, and overwrites with --force", async () => {
    const skillsRoot = join(ctx.workspace, "skills");
    const targetPath = join(skillsRoot, "dotweave", "SKILL.md");

    await mkdir(skillsRoot, { recursive: true });

    const dryRun = await ctx.runCli([
      "skill",
      "install",
      skillsRoot,
      "--dry-run",
    ]);
    expect(stripAnsi(dryRun.stdout)).toContain("Would install dotweave skill");
    await expect(readFile(targetPath, "utf8")).rejects.toThrow();

    const install = await ctx.runCli(["skill", "install", skillsRoot]);
    expect(stripAnsi(install.stdout)).toContain("Installed dotweave skill");
    await expect(readFile(targetPath, "utf8")).resolves.toContain(
      "name: dotweave",
    );

    const existing = await ctx.runCli(["skill", "install", skillsRoot], {
      reject: false,
    });
    expect(existing.exitCode).not.toBe(0);
    expect(stripAnsi(existing.stderr)).toContain(
      "Dotweave skill already exists",
    );

    await writeFile(targetPath, "local override\n", "utf8");
    const dryOverwrite = await ctx.runCli([
      "skill",
      "install",
      skillsRoot,
      "--dry-run",
      "--force",
    ]);
    expect(stripAnsi(dryOverwrite.stdout)).toContain(
      "Would overwrite dotweave skill",
    );
    await expect(readFile(targetPath, "utf8")).resolves.toBe(
      "local override\n",
    );

    const overwrite = await ctx.runCli([
      "skill",
      "install",
      skillsRoot,
      "--force",
    ]);
    expect(stripAnsi(overwrite.stdout)).toContain("Overwrote dotweave skill");
    await expect(readFile(targetPath, "utf8")).resolves.toContain(
      "name: dotweave",
    );
  });

  it("rejects a missing skills root without creating it", async () => {
    const skillsRoot = join(ctx.workspace, "missing-skills");
    const result = await ctx.runCli(["skill", "install", skillsRoot], {
      reject: false,
    });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain(
      "Skills root must be a directory",
    );
    await expect(
      readFile(join(skillsRoot, "dotweave", "SKILL.md"), "utf8"),
    ).rejects.toThrow();
  });
});
