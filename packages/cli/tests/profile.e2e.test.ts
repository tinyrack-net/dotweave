import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  createSyncE2EContext,
  type SyncE2EContext,
} from "../src/test/helpers/e2e-context.ts";
import {
  readManifestJson,
  readSettingsJson,
} from "../src/test/helpers/mock-factories.ts";
import { stripAnsi } from "../src/test/helpers/sync-fixture.ts";

let ctx: SyncE2EContext;

type ProfilePullFixture = Readonly<{
  homeFile: string;
  sharedFile: string;
  workFile: string;
}>;

const setupProfilePullFixture = async (): Promise<ProfilePullFixture> => {
  const sharedDir = join(ctx.homeDir, ".config", "shared");
  const workFile = join(ctx.homeDir, ".gitconfig-work");
  const homeFile = join(ctx.homeDir, ".gitconfig-home");
  const sharedFile = join(sharedDir, "tool.conf");
  const ageKeys = await ctx.createAgeKeyPair();

  await ctx.writeIdentityFile(ageKeys.identity);
  await mkdir(sharedDir, { recursive: true });
  await writeFile(workFile, "work = initial\n");
  await writeFile(homeFile, "home = initial\n");
  await writeFile(sharedFile, "shared = initial\n");

  await ctx.runCli(["init"]);
  await ctx.runCli(["profile", "add", "work"]);
  await ctx.runCli(["profile", "add", "home"]);
  await ctx.runCli(["track", workFile, "--profile", "work"]);
  await ctx.runCli(["track", homeFile, "--profile", "home"]);
  await ctx.runCli(["track", sharedFile]);
  await ctx.runCli(["push"]);
  await ctx.runCli(["push", "--profile", "work"]);
  await ctx.runCli(["push", "--profile", "home"]);

  await writeFile(
    join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".gitconfig-work",
    ),
    "work = repository\n",
  );
  await writeFile(
    join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "home",
      ".gitconfig-home",
    ),
    "home = repository\n",
  );
  await writeFile(
    join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "shared",
      "tool.conf",
    ),
    "shared = repository\n",
  );
  await writeFile(workFile, "work = local\n");
  await writeFile(homeFile, "home = local\n");
  await writeFile(sharedFile, "shared = local\n");

  return { homeFile, sharedFile, workFile };
};

beforeEach(async () => {
  ctx = await createSyncE2EContext();
});

afterEach(async () => {
  await ctx.cleanup();
});

describe("profile CLI e2e", () => {
  it("lists the active profile and available profiles after init", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);

    const result = await ctx.runCli(["profile", "list"]);

    expect(result.exitCode).toBe(0);
    const out = stripAnsi(result.stdout);
    expect(out).toContain("Profiles");
    expect(out).toContain("default");
  });

  it("sets and reads back the active profile via profile use", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);

    const setResult = await ctx.runCli(["profile", "use", "work"]);

    expect(setResult.exitCode).toBe(0);
    expect(stripAnsi(setResult.stdout)).toContain("Active profile set to work");

    const settings = readSettingsJson(
      await readFile(join(ctx.xdgDir, "dotweave", "settings.jsonc"), "utf8"),
    );

    expect(settings.activeProfile).toBe("work");
  });

  it("clears the active profile when profile use is called without a name", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);
    await ctx.runCli(["profile", "use", "work"]);

    const clearResult = await ctx.runCli(["profile", "use"]);

    expect(clearResult.exitCode).toBe(0);
    expect(stripAnsi(clearResult.stdout)).toContain("Active profile cleared");

    const settings = readSettingsJson(
      await readFile(join(ctx.xdgDir, "dotweave", "settings.jsonc"), "utf8"),
    );

    expect(settings.activeProfile).toBeUndefined();
  });

  it("lists profile assignments after tracking entries with --profile", async () => {
    const configDir = join(ctx.homeDir, ".config", "workapp");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "token = secret\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);
    await ctx.runCli(["track", configDir, "--profile", "work"]);

    const result = await ctx.runCli(["profile", "list"]);

    expect(result.exitCode).toBe(0);
  });

  it("pushes and pulls only profile-scoped entries with --profile flag", async () => {
    const workDir = join(ctx.homeDir, ".config", "work");
    const homeDir2 = join(ctx.homeDir, ".config", "personal");
    const workFile = join(workDir, "work.conf");
    const personalFile = join(homeDir2, "personal.conf");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(workDir, { recursive: true });
    await mkdir(homeDir2, { recursive: true });
    await writeFile(workFile, "office = true\n");
    await writeFile(personalFile, "home = true\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);
    await ctx.runCli(["profile", "add", "home"]);
    await ctx.runCli(["track", workDir, "--profile", "work"]);
    await ctx.runCli(["track", homeDir2, "--profile", "home"]);

    // Push only the work profile
    const pushResult = await ctx.runCli(["push", "--profile", "work"]);

    expect(pushResult.exitCode).toBe(0);
    expect(stripAnsi(pushResult.stdout)).toContain("Push complete");

    // Work artifact should exist in the repository
    const workArtifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".config",
      "work",
      "work.conf",
    );
    expect(await readFile(workArtifact, "utf8")).toContain("office = true");

    // Personal artifact should NOT have been pushed
    const personalArtifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "home",
      ".config",
      "personal",
      "personal.conf",
    );
    await expect(readFile(personalArtifact, "utf8")).rejects.toThrow();
  }, 60_000);

  it("pull --profile work applies work and default artifacts only", async () => {
    const { homeFile, sharedFile, workFile } = await setupProfilePullFixture();

    const result = await ctx.runCli(["pull", "--profile", "work", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(workFile, "utf8")).toBe("work = repository\n");
    expect(await readFile(sharedFile, "utf8")).toBe("shared = repository\n");
    expect(await readFile(homeFile, "utf8")).toBe("home = local\n");
  }, 60_000);

  it("pull -y uses the active work profile", async () => {
    const { homeFile, sharedFile, workFile } = await setupProfilePullFixture();

    await ctx.runCli(["profile", "use", "work"]);
    const result = await ctx.runCli(["pull", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(workFile, "utf8")).toBe("work = repository\n");
    expect(await readFile(sharedFile, "utf8")).toBe("shared = repository\n");
    expect(await readFile(homeFile, "utf8")).toBe("home = local\n");
  }, 60_000);

  it("pull -y with active home profile does not apply work artifacts", async () => {
    const { homeFile, sharedFile, workFile } = await setupProfilePullFixture();

    await ctx.runCli(["profile", "use", "home"]);
    const result = await ctx.runCli(["pull", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(homeFile, "utf8")).toBe("home = repository\n");
    expect(await readFile(sharedFile, "utf8")).toBe("shared = repository\n");
    expect(await readFile(workFile, "utf8")).toBe("work = local\n");
  }, 60_000);

  it("pull --profile overrides the active profile", async () => {
    const { homeFile, sharedFile, workFile } = await setupProfilePullFixture();

    await ctx.runCli(["profile", "use", "home"]);
    const result = await ctx.runCli(["pull", "--profile", "work", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(workFile, "utf8")).toBe("work = repository\n");
    expect(await readFile(sharedFile, "utf8")).toBe("shared = repository\n");
    expect(await readFile(homeFile, "utf8")).toBe("home = local\n");
  }, 60_000);

  it("pull -y without an active named profile applies default artifacts only", async () => {
    const { homeFile, sharedFile, workFile } = await setupProfilePullFixture();

    await ctx.runCli(["profile", "use"]);
    const result = await ctx.runCli(["pull", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(sharedFile, "utf8")).toBe("shared = repository\n");
    expect(await readFile(workFile, "utf8")).toBe("work = local\n");
    expect(await readFile(homeFile, "utf8")).toBe("home = local\n");
  }, 60_000);

  it("rejects invalid profile names with special characters", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);

    const spaceResult = await ctx.runCli(["profile", "use", "invalid name"], {
      reject: false,
    });
    expect(spaceResult.exitCode).not.toBe(0);
    expect(spaceResult.stderr).toContain("unsupported characters");

    const slashResult = await ctx.runCli(
      ["profile", "use", "name/with/slashes"],
      {
        reject: false,
      },
    );
    expect(slashResult.exitCode).not.toBe(0);
    expect(slashResult.stderr).toContain("unsupported characters");
  });

  it("rejects profile use for a non-existent profile", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);

    const result = await ctx.runCli(["profile", "use", "ghost"], {
      reject: false,
    });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain("Unknown profile 'ghost'");
  });

  it("lists default when no entries have explicit profiles", async () => {
    const configDir = join(ctx.homeDir, ".config", "myapp");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(join(configDir, "config.toml"), "key = value\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);

    const result = await ctx.runCli(["profile", "list"]);

    expect(result.exitCode).toBe(0);
    const out = stripAnsi(result.stdout);
    expect(out).toContain("Profiles");
    expect(out).toContain("default");
  });

  it("adds and removes unused profiles in the manifest registry", async () => {
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);

    const manifestPath = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    let manifest = readManifestJson(await readFile(manifestPath, "utf8"));
    expect(manifest.profiles).toEqual(["work"]);

    const removeResult = await ctx.runCli(["profile", "remove", "work"]);

    expect(removeResult.exitCode).toBe(0);
    manifest = readManifestJson(await readFile(manifestPath, "utf8"));
    expect(manifest.profiles).toEqual([]);
  });

  it("rejects removing profiles that are still referenced by entries", async () => {
    const configDir = join(ctx.homeDir, ".config", "workapp");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(join(configDir, "config.toml"), "token = secret\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);
    await ctx.runCli(["track", configDir, "--profile", "work"]);

    const result = await ctx.runCli(["profile", "remove", "work"], {
      reject: false,
    });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain(
      "Cannot remove profile 'work' because it is still referenced by 1 sync entry.",
    );

    const manifestPath = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    const manifest = readManifestJson(await readFile(manifestPath, "utf8"));
    expect(manifest.profiles).toEqual(["work"]);
    expect(manifest.entries[0]?.profiles).toEqual(["work"]);
  });

  it("rejects removing the active profile", async () => {
    const ageKeys = await ctx.createAgeKeyPair();
    await ctx.writeIdentityFile(ageKeys.identity);
    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);
    await ctx.runCli(["profile", "use", "work"]);

    const result = await ctx.runCli(["profile", "remove", "work"], {
      reject: false,
    });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain(
      "Cannot remove active profile 'work'",
    );
  });
});
