import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  createMachineEnv,
  createSyncE2EContext,
  readRepositoryArtifact,
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

describe("lifecycle contract e2e", () => {
  it("locks normal, secret, ignore, dry-run, pull, and idempotency behavior", async () => {
    const configDir = join(ctx.homeDir, ".config", "lifecycle");
    const cacheDir = join(configDir, "cache");
    const publicFile = join(configDir, "public.toml");
    const secretFile = join(configDir, "secrets.env");
    const ignoredFile = join(cacheDir, "state.txt");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(cacheDir, { recursive: true });
    await writeFile(publicFile, "theme = light\n", "utf8");
    await writeFile(secretFile, "TOKEN=initial\n", "utf8");
    await writeFile(ignoredFile, "cache = initial\n", "utf8");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["track", secretFile, "--mode", "secret"]);
    await ctx.runCli(["track", ignoredFile, "--mode", "ignore"]);

    const statusBeforePush = await ctx.runCli(["status"]);
    expect(stripAnsi(statusBeforePush.stdout)).toContain("Push changes");
    expect(stripAnsi(statusBeforePush.stdout)).toContain("Add");

    const dryPush = await ctx.runCli(["push", "--dry-run"]);
    expect(stripAnsi(dryPush.stdout)).toContain("Push preview");
    await expect(
      readRepositoryArtifact(
        ctx.xdgDir,
        "default",
        ".config/lifecycle/public.toml",
      ),
    ).rejects.toThrow();

    await ctx.runCli(["push"]);

    await expect(
      readRepositoryArtifact(
        ctx.xdgDir,
        "default",
        ".config/lifecycle/public.toml",
      ),
    ).resolves.toBe("theme = light\n");
    await expect(
      readRepositoryArtifact(
        ctx.xdgDir,
        "default",
        ".config/lifecycle/secrets.env.dotweave.secret",
      ),
    ).resolves.toContain("BEGIN AGE ENCRYPTED FILE");
    await expect(
      readRepositoryArtifact(
        ctx.xdgDir,
        "default",
        ".config/lifecycle/cache/state.txt",
      ),
    ).rejects.toThrow();

    const noOpPush = await ctx.runCli(["push"]);
    expect(stripAnsi(noOpPush.stdout)).toContain("Push complete");
    expect(stripAnsi(noOpPush.stdout)).toContain("plain: 1");
    expect(stripAnsi(noOpPush.stdout)).toContain("encrypted: 1");

    await writeFile(publicFile, "theme = dark\n", "utf8");
    await writeFile(secretFile, "TOKEN=local\n", "utf8");
    await writeFile(ignoredFile, "cache = local\n", "utf8");

    const dryPull = await ctx.runCli(["pull", "--dry-run"]);
    expect(stripAnsi(dryPull.stdout)).toContain("Pull preview");
    expect(await readFile(publicFile, "utf8")).toBe("theme = dark\n");
    expect(await readFile(secretFile, "utf8")).toBe("TOKEN=local\n");

    await ctx.runCli(["pull", "-y"]);

    expect(await readFile(publicFile, "utf8")).toBe("theme = light\n");
    expect(await readFile(secretFile, "utf8")).toBe("TOKEN=initial\n");
    expect(await readFile(ignoredFile, "utf8")).toBe("cache = local\n");

    const statusAfterPull = await ctx.runCli(["status"]);
    const statusOutput = stripAnsi(statusAfterPull.stdout);
    expect(statusOutput).toContain("No push changes");
    expect(statusOutput).toContain("No pull changes");
  }, 60_000);

  it("restores a normal and secret profile from a bare repository on a second machine", async () => {
    const remoteRepository = join(ctx.workspace, "remote.git");
    const keyFile = join(ctx.workspace, "identity.agekey");
    const configDir = join(ctx.homeDir, ".config", "portable");
    const publicFile = join(configDir, "settings.toml");
    const secretFile = join(configDir, "token.env");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.runGit(["init", "--bare", "-b", "main", remoteRepository]);
    await ctx.writeIdentityFile(ageKeys.identity);
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");
    await mkdir(configDir, { recursive: true });
    await writeFile(publicFile, "editor = vim\n", "utf8");
    await writeFile(secretFile, "TOKEN=portable\n", "utf8");

    await ctx.runCli(["init", remoteRepository]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["track", secretFile, "--mode", "secret"]);
    await ctx.runCli(["push"]);

    const syncDirectory = join(ctx.xdgDir, "dotweave", "repository");
    await ctx.runGit(["add", "."], syncDirectory);
    await ctx.runGit(["commit", "-m", "seed portable config"], syncDirectory);
    await ctx.runGit(["push", "-u", "origin", "main"], syncDirectory);

    const second = createMachineEnv(ctx.workspace, "second", ctx.baseEnv);

    await mkdir(second.homeDir, { recursive: true });
    await ctx.runCli(["init", remoteRepository, "--key-file", keyFile], {
      env: second.env,
    });
    await ctx.runCli(["pull", "-y"], { env: second.env });

    await expect(
      readFile(
        join(second.homeDir, ".config", "portable", "settings.toml"),
        "utf8",
      ),
    ).resolves.toBe("editor = vim\n");
    await expect(
      readFile(
        join(second.homeDir, ".config", "portable", "token.env"),
        "utf8",
      ),
    ).resolves.toBe("TOKEN=portable\n");
  }, 60_000);
});
