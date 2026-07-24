import {
  lstat,
  mkdir,
  readFile,
  readlink,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { AppConstants } from "../src/config/constants.ts";
import { createSymlink } from "../src/lib/filesystem.ts";
import {
  createSyncE2EContext,
  type SyncE2EContext,
} from "../src/test/helpers/e2e-context.ts";

let ctx: SyncE2EContext;

beforeEach(async () => {
  ctx = await createSyncE2EContext();
});

afterEach(async () => {
  await ctx.cleanup();
});

type GitTreeEntry = { mode: string; path: string };

// Parses `git ls-files -s` into { mode, path } entries.
const gitTree = async (repoDir: string): Promise<GitTreeEntry[]> => {
  const ls = await ctx.runGit(["ls-files", "-s"], repoDir);
  return ls.stdout
    .trim()
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => {
      const [meta, path] = line.split("\t");
      const mode = (meta ?? "").split(" ")[0] ?? "";
      return { mode, path: path ?? "" };
    });
};

const machineBEnv = (label: string) => {
  const homeB = join(ctx.workspace, `home-${label}`);
  const xdgB = join(ctx.workspace, `xdg-${label}`);
  return {
    homeB,
    xdgB,
    env: {
      ...ctx.baseEnv,
      APPDATA: xdgB,
      HOME: homeB,
      LOCALAPPDATA: join(ctx.workspace, `lad-${label}`),
      USERPROFILE: homeB,
      XDG_CONFIG_HOME: xdgB,
    },
  };
};

/**
 * Proves symlinks now round-trip across machines and operating systems by
 * being stored as regular `.dotweave.symlink` metadata files (git-safe blobs)
 * rather than physical filesystem symlinks/junctions. On pull each machine
 * re-materializes a native OS link in its own HOME.
 */
describe("symlink sync across machines (portable metadata-file format)", () => {
  it("syncs a symlink-to-FILE as a regular metadata file, restored as a native link on a second machine", async () => {
    const remote = join(ctx.workspace, "remote-file.git");
    const keyFile = join(ctx.workspace, "file.agekey");
    const ageKeys = await ctx.createAgeKeyPair();

    // Machine A: ~/.claude/note.md -> ../.agents/note.md
    const realFile = join(ctx.homeDir, ".agents", "note.md");
    const link = join(ctx.homeDir, ".claude", "note.md");

    await ctx.runGit(["init", "--bare", "-b", "main", remote]);
    await ctx.writeIdentityFile(ageKeys.identity);
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");
    await mkdir(join(ctx.homeDir, ".agents"), { recursive: true });
    await writeFile(realFile, "# real note (machine A)\n");
    await mkdir(join(ctx.homeDir, ".claude"), { recursive: true });
    await createSymlink(join("..", ".agents", "note.md"), link);

    await ctx.runCli(["init", remote]);
    await ctx.runCli(["track", link]);
    await ctx.runCli(["push"]);

    const repoDir = join(ctx.xdgDir, "dotweave", "repository");
    await ctx.runGit(["add", "."], repoDir);
    await ctx.runGit(["commit", "-m", "sync file symlink"], repoDir);
    await ctx.runGit(["push", "-u", "origin", "main"], repoDir);

    // Repo stores a REGULAR FILE with the .dotweave.symlink suffix (mode 100644),
    // not a git symlink blob (120000) or a physical link.
    const tree = await gitTree(repoDir);
    const artifact = tree.find((e) =>
      e.path.endsWith(".claude/note.md.dotweave.symlink"),
    );
    expect(artifact?.mode).toBe("100644");
    expect(tree.some((e) => e.mode === "120000")).toBe(false);

    const artifactFile = join(
      repoDir,
      "profiles",
      "default",
      ".claude",
      "note.md.dotweave.symlink",
    );
    expect(await readFile(artifactFile, "utf8")).toBe("../.agents/note.md");

    // Machine B: different HOME, no core.symlinks needed.
    const { homeB, env: envB } = machineBEnv("B1");
    await mkdir(join(homeB, ".agents"), { recursive: true });
    await writeFile(
      join(homeB, ".agents", "note.md"),
      "# real note (machine B)\n",
    );

    await ctx.runCli(["init", remote, "--key-file", keyFile], { env: envB });
    const pull = await ctx.runCli(["pull", "-y"], { env: envB });
    expect(pull.exitCode).toBe(0);

    const linkB = join(homeB, ".claude", "note.md");
    expect((await lstat(linkB)).isSymbolicLink()).toBe(true);
    expect((await readlink(linkB)).replace(/\\/g, "/")).toContain(
      ".agents/note.md",
    );
    expect(await readFile(linkB, "utf8")).toContain("machine B");
  }, 120_000);

  it("syncs a symlink-to-DIRECTORY (~/.claude/skills -> ../.agents/skills) as a native link on a second machine", async () => {
    const remote = join(ctx.workspace, "remote-dir.git");
    const keyFile = join(ctx.workspace, "dir.agekey");
    const ageKeys = await ctx.createAgeKeyPair();

    // Machine A
    const agentsSkills = join(ctx.homeDir, ".agents", "skills");
    const claudeSkills = join(ctx.homeDir, ".claude", "skills");

    await ctx.runGit(["init", "--bare", "-b", "main", remote]);
    await ctx.writeIdentityFile(ageKeys.identity);
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");
    await mkdir(agentsSkills, { recursive: true });
    await writeFile(join(agentsSkills, "s.md"), "skill (machine A)\n");
    await mkdir(join(ctx.homeDir, ".claude"), { recursive: true });
    await createSymlink(join("..", ".agents", "skills"), claudeSkills);

    await ctx.runCli(["init", remote]);
    await ctx.runCli(["track", claudeSkills]);
    await ctx.runCli(["push"]);

    const repoDir = join(ctx.xdgDir, "dotweave", "repository");
    await ctx.runGit(["add", "."], repoDir);
    await ctx.runGit(["commit", "-m", "sync dir symlink"], repoDir);
    await ctx.runGit(["push", "-u", "origin", "main"], repoDir);

    // The directory symlink is stored as a single regular metadata file --
    // NOT a directory of copied contents (the old Windows junction failure).
    const tree = await gitTree(repoDir);
    expect(
      tree.some((e) => e.path.endsWith(".claude/skills.dotweave.symlink")),
    ).toBe(true);
    expect(tree.some((e) => e.path.includes(".claude/skills/"))).toBe(false);

    // Machine B: different HOME.
    const { homeB, env: envB } = machineBEnv("B2");
    await mkdir(join(homeB, ".agents", "skills"), { recursive: true });
    await writeFile(
      join(homeB, ".agents", "skills", "s.md"),
      "skill (machine B)\n",
    );

    await ctx.runCli(["init", remote, "--key-file", keyFile], { env: envB });
    const pull = await ctx.runCli(["pull", "-y"], { env: envB });
    expect(pull.exitCode).toBe(0);

    // HOME gets a working native link (junction on Windows, symlink on Unix)
    // resolving to machine B's own target directory.
    const linkB = join(homeB, ".claude", "skills");
    expect((await lstat(linkB)).isSymbolicLink()).toBe(true);
    expect(await readFile(join(linkB, "s.md"), "utf8")).toContain("machine B");

    // Second pull is a no-op.
    const secondPull = await ctx.runCli(["pull"], { env: envB });
    expect(secondPull.stdout.includes("Already up to date")).toBe(true);
  }, 120_000);

  it("reads a legacy physical-symlink artifact and migrates it to the metadata-file format on push", async () => {
    const realFile = join(ctx.homeDir, ".agents", "note.md");
    const link = join(ctx.homeDir, ".claude", "note.md");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(join(ctx.homeDir, ".agents"), { recursive: true });
    await writeFile(realFile, "# note\n");
    await mkdir(join(ctx.homeDir, ".claude"), { recursive: true });
    await createSymlink(join("..", ".agents", "note.md"), link);

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", link]);
    await ctx.runCli(["push"]);

    const plainArtifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".claude",
      "note.md",
    );
    const metaArtifact = `${plainArtifact}${AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX}`;

    // Simulate an OLD repository: replace the metadata file with a physical
    // symlink at the plain path (the pre-.dotweave.symlink format).
    await rm(metaArtifact, { force: true });
    await createSymlink(join("..", ".agents", "note.md"), plainArtifact);

    // The legacy physical symlink is still readable: pull sees no drift.
    const pull = await ctx.runCli(["pull"]);
    expect(pull.stdout.includes("Already up to date")).toBe(true);

    // Pushing migrates it to the portable metadata-file format and removes the
    // legacy physical symlink.
    await ctx.runCli(["push"]);
    const metaStats = await lstat(metaArtifact);
    expect(metaStats.isFile()).toBe(true);
    expect(await readFile(metaArtifact, "utf8")).toBe("../.agents/note.md");
    await expect(lstat(plainArtifact)).rejects.toThrow();
  }, 120_000);
});
