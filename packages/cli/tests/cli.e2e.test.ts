import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { execa } from "execa";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import packageJson from "../package.json" with { type: "json" };
import { rootCommandRoutes } from "../src/cli/root-commands.ts";
import { cliNodeOptions } from "../src/test/helpers/cli-entry.ts";
import {
  createSyncE2EContext,
  type SyncE2EContext,
} from "../src/test/helpers/e2e-context.ts";
import { stripAnsi } from "../src/test/helpers/sync-fixture.ts";

const runCli = async (
  args: readonly string[],
  options?: Readonly<{
    env?: NodeJS.ProcessEnv;
    reject?: boolean;
  }>,
) => {
  return execa(process.execPath, [...cliNodeOptions, ...args], {
    env: options?.env,
    reject: options?.reject,
  });
};

describe("CLI e2e", () => {
  it("shows the version from the real entrypoint", async () => {
    const result = await runCli(["--version"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain(`dotweave/${packageJson.version}`);
    expect(result.stderr).toBe("");
  });

  it("shows root help with the new command surface", async () => {
    const result = await runCli([]);

    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");

    const rootCommandNames = [
      "autocomplete",
      ...Object.keys(rootCommandRoutes),
    ];
    for (const commandName of rootCommandNames) {
      expect(result.stdout).toContain(commandName);
    }

    expect(result.stdout).toContain("Launch a shell in the sync directory");
  });

  it("shows help for cd, track, and profile use commands", async () => {
    const [cdHelp, trackHelp, profileHelp] = await Promise.all([
      runCli(["cd", "--help"]),
      runCli(["track", "--help"]),
      runCli(["profile", "use", "--help"]),
    ]);

    expect(cdHelp.stdout).toContain("USAGE");
    expect(cdHelp.stdout).toContain("Launch a child shell rooted");

    expect(trackHelp.stdout).toContain("USAGE");
    expect(trackHelp.stdout).toContain("--mode");
    expect(trackHelp.stdout).toContain("--profile");
    expect(trackHelp.stdout).toContain("--repo");

    expect(profileHelp.stdout).toContain("Profile name to activate");
  });

  it("rejects removed --verbose flag", async () => {
    const result = await runCli(["pull", "--verbose"], { reject: false });

    expect((result.exitCode ?? 0) & 0xff).toBe(252);
    expect(result.stderr).toContain("No flag registered for --verbose");
  });

  it("returns a non-zero exit code for removed command surfaces", async () => {
    const [addResult, removeResult, modeResult, listResult, dirResult] =
      await Promise.all([
        runCli(["add", "~/.gitconfig"], { reject: false }),
        runCli(["remove", "~/.gitconfig"], { reject: false }),
        runCli(["mode", "secret", "~/.gitconfig"], { reject: false }),
        runCli(["list"], { reject: false }),
        runCli(["dir"], { reject: false }),
      ]);

    expect(addResult.exitCode).not.toBe(0);
    expect(addResult.stderr).toContain("not found");
    expect(removeResult.exitCode).not.toBe(0);
    expect(removeResult.stderr).toContain("not found");
    expect(modeResult.exitCode).not.toBe(0);
    expect(modeResult.stderr).toContain("not found");
    expect(listResult.exitCode).not.toBe(0);
    expect(listResult.stderr).toContain("not found");
    expect(dirResult.exitCode).not.toBe(0);
    expect(dirResult.stderr).toContain("not found");
  });
});

let ctx: SyncE2EContext;

beforeEach(async () => {
  ctx = await createSyncE2EContext();
});

afterEach(async () => {
  await ctx.cleanup();
});

describe("CLI sync cycle e2e", () => {
  it("runs a full init-track-push-pull cycle", async () => {
    const configDir = join(ctx.homeDir, ".config", "myapp");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "key = value\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);

    await writeFile(configFile, "key = modified\n");
    await ctx.runCli(["pull", "-y"]);

    const content = await readFile(configFile, "utf8");
    expect(content).toContain("key = value\n");
  });

  it("reports status for an initialized repository", async () => {
    const configDir = join(ctx.homeDir, ".config", "myapp");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(join(configDir, "config.toml"), "key = value\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);

    const result = await ctx.runCli(["status"]);

    expect(result.exitCode).toBe(0);
    const out = stripAnsi(result.stdout);
    expect(out).toContain("Sync status");
    expect(out).toContain("Push changes");
    expect(out).toContain("Add");
  });

  it("reports missing git during repository import without blaming reachability", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    const keyFile = await ctx.writeIdentityFile(ageKeys.identity);

    const result = await ctx.runCli(
      ["init", "https://example.invalid/dotfiles.git", "--key-file", keyFile],
      {
        env: { PATH: "", Path: "" },
        reject: false,
      },
    );
    const stderr = stripAnsi(result.stderr);

    expect(result.exitCode).toBe(1);
    expect(stderr).toContain("Git is not installed or not on PATH.");
    expect(stderr).toContain(
      "Install Git and ensure the git executable is available on PATH",
    );
    expect(stderr).not.toContain("repository source is reachable");
  });
});
