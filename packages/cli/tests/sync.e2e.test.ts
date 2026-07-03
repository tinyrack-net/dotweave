import {
  chmod,
  lstat,
  mkdir,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  createInitialSyncConfig,
  formatSyncConfig,
} from "../src/config/sync-schema.ts";
import { cliNodeOptions } from "../src/test/helpers/cli-entry.ts";
import {
  createSyncE2EContext,
  type SyncE2EContext,
} from "../src/test/helpers/e2e-context.ts";
import {
  parseManifestEntries,
  readManifestJson,
} from "../src/test/helpers/mock-factories.ts";
import { createPtySession } from "../src/test/helpers/pty.ts";
import { stripAnsi } from "../src/test/helpers/sync-fixture.ts";

let ctx: SyncE2EContext;
const supportsPtyE2E = process.platform !== "win32";
const itWithPty = it.skipIf(!supportsPtyE2E);

beforeEach(async () => {
  ctx = await createSyncE2EContext();
});

afterEach(async () => {
  await ctx.cleanup();
});

describe("sync CLI e2e", () => {
  it("generates a default age identity for bare init", async () => {
    const result = await ctx.runCli(["init"], {
      env: { ...ctx.baseEnv },
    });

    expect(result.stdout).toContain("age: generated a new local identity");
    expect(
      await readFile(join(ctx.xdgDir, "dotweave", "keys.txt"), "utf8"),
    ).toContain("AGE-SECRET-KEY-");
    expect(
      JSON.parse(
        await readFile(join(ctx.xdgDir, "dotweave", "settings.jsonc"), "utf8"),
      ),
    ).toMatchObject({
      activeProfile: "default",
      version: 3,
    });
    expect(
      JSON.parse(
        await readFile(join(ctx.xdgDir, "dotweave", "settings.jsonc"), "utf8"),
      ),
    ).not.toHaveProperty("age");
    expect(
      JSON.parse(
        await readFile(
          join(ctx.xdgDir, "dotweave", "repository", "manifest.jsonc"),
          "utf8",
        ),
      ),
    ).toMatchObject({
      age: {
        recipients: [expect.stringMatching(/^age1/u)],
      },
      entries: [],
      version: 8,
    });
    expect(
      await readFile(
        join(ctx.xdgDir, "dotweave", "repository", ".gitattributes"),
        "utf8",
      ),
    ).toBe("* -text\n");
  });

  it("accepts a supplied age key file during init without a precreated identity file", async () => {
    const sourceRepository = join(ctx.workspace, "remote-sync");
    const keyFile = join(ctx.workspace, "import.agekey");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.runGit(["init", "-b", "main", sourceRepository]);
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");

    const result = await ctx.runCli([
      "init",
      sourceRepository,
      "--key-file",
      keyFile,
    ]);

    expect(stripAnsi(result.stdout)).toContain("Sync directory initialized");
    expect(stripAnsi(result.stdout)).toContain("age: using existing identity");
    expect(
      await readFile(join(ctx.xdgDir, "dotweave", "keys.txt"), "utf8"),
    ).toBe(`${ageKeys.identity}\n`);
  });

  itWithPty(
    "fails when importing an existing repository without supplying an age key",
    async () => {
      const sourceRepository = join(ctx.workspace, "remote-sync");

      await ctx.runGit(["init", "-b", "main", sourceRepository]);
      const session = createPtySession({
        args: [...cliNodeOptions, "init", sourceRepository],
        cwd: ctx.workspace,
        env: {
          ...ctx.baseEnv,
        },
        file: process.execPath,
      });

      try {
        await session.waitFor(
          "Enter the age private key for the existing repository",
          10_000,
        );
        session.write("\r");

        const output = await session.waitFor(
          "Provide your existing age private key with '--key-file'",
          10_000,
        );

        expect(output).toContain(
          "Existing repository setup requires an age private key",
        );
      } finally {
        session.close();
      }
    },
  );

  it("does not warn about an existing config when cloning a repository with an existing manifest", async () => {
    const sourceRepository = join(ctx.workspace, "remote-sync");
    const keyFile = join(ctx.workspace, "manifest.agekey");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.runGit(["init", "-b", "main", sourceRepository]);
    await writeFile(
      join(sourceRepository, "manifest.jsonc"),
      formatSyncConfig(
        createInitialSyncConfig({
          recipients: [ageKeys.recipient],
        }),
      ),
      "utf8",
    );
    await ctx.runGit(["add", "manifest.jsonc"], sourceRepository);
    await ctx.runGit(
      ["commit", "-m", "initial manifest", "--author", "test <test@test.com>"],
      sourceRepository,
    );
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");

    const result = await ctx.runCli([
      "init",
      sourceRepository,
      "--key-file",
      keyFile,
    ]);

    expect(stripAnsi(result.stdout)).toContain("Sync directory initialized");
    expect(stripAnsi(result.stdout)).not.toContain(
      "Sync directory already initialized",
    );
  });

  it("rejects an invalid supplied age key file during init", async () => {
    const keyFile = join(ctx.workspace, "invalid.agekey");
    await writeFile(keyFile, "not-a-key\n", "utf8");

    const result = await ctx.runCli(["init", "--key-file", keyFile], {
      reject: false,
    });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain("Invalid age private key");
  });

  it("accepts an age key file when no identity file exists", async () => {
    const sourceRepository = join(ctx.workspace, "remote-sync");
    const keyFile = join(ctx.workspace, "missing-identity.agekey");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.runGit(["init", "-b", "main", sourceRepository]);
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");

    const result = await ctx.runCli([
      "init",
      sourceRepository,
      "--key-file",
      keyFile,
    ]);

    expect(stripAnsi(result.stdout)).toContain("Sync directory initialized");
    expect(
      await readFile(join(ctx.xdgDir, "dotweave", "keys.txt"), "utf8"),
    ).toBe(`${ageKeys.identity}\n`);
  });

  it("does not warn about an existing config when cloning a repository with an existing manifest and passing a key file", async () => {
    const sourceRepository = join(ctx.workspace, "remote-sync");
    const keyFile = join(ctx.workspace, "manifest-explicit.agekey");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.runGit(["init", "-b", "main", sourceRepository]);
    await writeFile(
      join(sourceRepository, "manifest.jsonc"),
      formatSyncConfig(
        createInitialSyncConfig({
          recipients: [ageKeys.recipient],
        }),
      ),
      "utf8",
    );
    await ctx.runGit(["add", "manifest.jsonc"], sourceRepository);
    await ctx.runGit(
      ["commit", "-m", "initial manifest", "--author", "test <test@test.com>"],
      sourceRepository,
    );
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");

    const result = await ctx.runCli([
      "init",
      sourceRepository,
      "--key-file",
      keyFile,
    ]);

    expect(stripAnsi(result.stdout)).toContain("Sync directory initialized");
    expect(stripAnsi(result.stdout)).not.toContain(
      "Sync directory already initialized",
    );
  });

  itWithPty(
    "does not warn about an existing config when cloning a repository with an existing manifest and entering the key interactively",
    async () => {
      const sourceRepository = join(ctx.workspace, "remote-sync");
      const ageKeys = await ctx.createAgeKeyPair();

      await ctx.runGit(["init", "-b", "main", sourceRepository]);
      await writeFile(
        join(sourceRepository, "manifest.jsonc"),
        formatSyncConfig(
          createInitialSyncConfig({
            recipients: [ageKeys.recipient],
          }),
        ),
        "utf8",
      );
      await ctx.runGit(["add", "manifest.jsonc"], sourceRepository);
      await ctx.runGit(
        [
          "commit",
          "-m",
          "initial manifest",
          "--author",
          "test <test@test.com>",
        ],
        sourceRepository,
      );

      const session = createPtySession({
        args: [...cliNodeOptions, "init", sourceRepository],
        cwd: ctx.workspace,
        env: {
          ...ctx.baseEnv,
        },
        file: process.execPath,
      });

      try {
        await session.waitFor(
          "Enter the age private key for the existing repository",
          10_000,
        );
        session.write(`${ageKeys.identity}\r`);

        const output = await session.waitFor(
          "Sync directory initialized",
          10_000,
        );

        expect(output).not.toContain("Sync directory already initialized");
      } finally {
        session.close();
      }
    },
  );

  itWithPty(
    "fails when an empty key is entered interactively for an existing repository",
    async () => {
      const sourceRepository = join(ctx.workspace, "remote-sync");

      await ctx.runGit(["init", "-b", "main", sourceRepository]);

      const session = createPtySession({
        args: [...cliNodeOptions, "init", sourceRepository],
        cwd: ctx.workspace,
        env: {
          ...ctx.baseEnv,
        },
        file: process.execPath,
      });

      try {
        await session.waitFor(
          "Enter the age private key for the existing repository",
          10_000,
        );
        session.write("\r");

        const output = await session.waitFor(
          "Provide your existing age private key with '--key-file'",
          10_000,
        );

        expect(output).toContain(
          "Existing repository setup requires an age private key",
        );
      } finally {
        session.close();
      }
    },
  );

  it("tracks roots, sets modes, and untracks from the CLI", async () => {
    const bundleDirectory = join(ctx.homeDir, ".config", "mytool");
    const publicFile = join(bundleDirectory, "public.json");
    const cacheDirectory = join(bundleDirectory, "cache");
    const syncDirectory = join(ctx.xdgDir, "dotweave", "repository");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(cacheDirectory, { recursive: true });
    await writeFile(publicFile, "{}\n");
    await writeFile(join(cacheDirectory, "state.txt"), "cache\n");

    await ctx.runCli(["init"]);

    const trackResult = await ctx.runCli([
      "track",
      bundleDirectory,
      "--mode",
      "secret",
    ]);
    const exactRuleResult = await ctx.runCli([
      "track",
      publicFile,
      "--mode",
      "normal",
    ]);
    const subtreeRuleResult = await ctx.runCli([
      "track",
      cacheDirectory,
      "--mode",
      "ignore",
    ]);
    const configAfterSetEntries = parseManifestEntries(
      await readFile(join(syncDirectory, "manifest.jsonc"), "utf8"),
    );

    expect(stripAnsi(trackResult.stdout)).toContain(
      "Started tracking .config/mytool",
    );
    expect(stripAnsi(trackResult.stdout)).toContain("mode");
    expect(stripAnsi(trackResult.stdout)).toContain("secret");
    expect(stripAnsi(exactRuleResult.stdout)).toContain(
      "Started tracking .config/mytool/public.json",
    );
    expect(stripAnsi(subtreeRuleResult.stdout)).toMatch(/mode\s+ignore/);
    expect(configAfterSetEntries).toMatchObject([
      {
        kind: "directory",
        localPath: { default: "~/.config/mytool" },
        mode: { default: "secret" },
      },
      {
        kind: "directory",
        localPath: { default: "~/.config/mytool/cache" },
        mode: { default: "ignore" },
      },
      {
        kind: "file",
        localPath: { default: "~/.config/mytool/public.json" },
      },
    ]);

    const untrackResult = await ctx.runCli(["untrack", ".config/mytool"]);

    expect(stripAnsi(untrackResult.stdout)).toContain(
      "Stopped tracking .config/mytool",
    );

    await ctx.runCli(["untrack", ".config/mytool/cache"]);
    await ctx.runCli(["untrack", ".config/mytool/public.json"]);

    const { entries: untrackEntries } = readManifestJson(
      await readFile(join(syncDirectory, "manifest.jsonc"), "utf8"),
    );

    expect(untrackEntries).toEqual([]);
  }, 60_000);

  it("syncs with the default profile namespace using push and pull", async () => {
    const zshDirectory = join(ctx.homeDir, ".config", "zsh");
    const sharedFile = join(zshDirectory, "zshrc");
    const secretsFile = join(zshDirectory, "secrets.zsh");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(sharedFile, "export PATH=$PATH:$HOME/bin\n");
    await writeFile(secretsFile, "export TOKEN=work\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", zshDirectory]);
    await ctx.runCli(["track", secretsFile, "--mode", "secret"]);

    await ctx.runCli(["push"]);

    expect(
      await readFile(
        join(
          ctx.xdgDir,
          "dotweave",
          "repository",
          "profiles",
          "default",
          ".config",
          "zsh",
          "zshrc",
        ),
        "utf8",
      ),
    ).toContain("PATH");
    expect(
      await readFile(
        join(
          ctx.xdgDir,
          "dotweave",
          "repository",
          "profiles",
          "default",
          ".config",
          "zsh",
          "secrets.zsh.dotweave.secret",
        ),
        "utf8",
      ),
    ).toContain("BEGIN AGE ENCRYPTED FILE");

    await writeFile(secretsFile, "local-change\n");
    await ctx.runCli(["pull", "-y"]);

    expect(await readFile(secretsFile, "utf8")).toContain("TOKEN=work");
  }, 60_000);

  it("restores secret directory files on another checkout when secret artifacts match repository ignore rules", async () => {
    const sourceRepository = join(ctx.workspace, "remote-sync.git");
    const keyFile = join(ctx.workspace, "vivident.agekey");
    const syncDirectory = join(ctx.xdgDir, "dotweave", "repository");
    const vividentDirectory = join(ctx.homeDir, ".vivident");
    const secondHomeDirectory = join(ctx.workspace, "home-second");
    const secondXdgDirectory = join(ctx.workspace, "xdg-second");
    const secondLocalAppDataDirectory = join(
      ctx.workspace,
      "local-appdata-second",
    );
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.runGit(["init", "--bare", "-b", "main", sourceRepository]);
    await ctx.writeIdentityFile(ageKeys.identity);
    await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");
    await mkdir(vividentDirectory, { recursive: true });
    await mkdir(secondHomeDirectory, { recursive: true });
    await writeFile(
      join(vividentDirectory, "config.json"),
      '{"theme":"dark"}\n',
    );
    await writeFile(join(vividentDirectory, "state.txt"), "window=main\n");

    await ctx.runCli(["init", sourceRepository]);
    await writeFile(join(syncDirectory, ".gitignore"), "*.dotweave.secret\n");
    await ctx.runCli(["track", vividentDirectory, "--mode", "secret"]);
    await ctx.runCli(["push"]);

    expect(
      await readFile(
        join(
          syncDirectory,
          "profiles",
          "default",
          ".vivident",
          "config.json.dotweave.secret",
        ),
        "utf8",
      ),
    ).toContain("BEGIN AGE ENCRYPTED FILE");
    expect(
      await readFile(
        join(
          syncDirectory,
          "profiles",
          "default",
          ".vivident",
          "state.txt.dotweave.secret",
        ),
        "utf8",
      ),
    ).toContain("BEGIN AGE ENCRYPTED FILE");

    const ignoredStatus = await ctx.runGit(
      ["status", "--ignored", "--short", "--untracked-files=all"],
      syncDirectory,
    );
    expect(ignoredStatus.stdout).not.toContain(
      "!! profiles/default/.vivident/config.json.dotweave.secret",
    );
    expect(ignoredStatus.stdout).not.toContain(
      "!! profiles/default/.vivident/state.txt.dotweave.secret",
    );

    await ctx.runGit(["add", "."], syncDirectory);
    await ctx.runGit(
      ["commit", "-m", "sync vivident directory"],
      syncDirectory,
    );
    await ctx.runGit(["push", "-u", "origin", "main"], syncDirectory);

    const secondEnv = {
      ...ctx.baseEnv,
      APPDATA: secondXdgDirectory,
      HOME: secondHomeDirectory,
      LOCALAPPDATA: secondLocalAppDataDirectory,
      USERPROFILE: secondHomeDirectory,
      XDG_CONFIG_HOME: secondXdgDirectory,
    };

    await ctx.runCli(["init", sourceRepository, "--key-file", keyFile], {
      env: secondEnv,
    });
    await ctx.runCli(["pull", "-y"], { env: secondEnv });

    await expect(
      readFile(join(secondHomeDirectory, ".vivident", "config.json"), "utf8"),
    ).resolves.toBe('{"theme":"dark"}\n');
    await expect(
      readFile(join(secondHomeDirectory, ".vivident", "state.txt"), "utf8"),
    ).resolves.toBe("window=main\n");
  }, 60_000);

  it("status reports a removed default entry artifact before push", async () => {
    const configDir = join(ctx.homeDir, ".config", "prune-status");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "enabled = true\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);

    await writeFile(
      join(ctx.xdgDir, "dotweave", "repository", "manifest.jsonc"),
      formatSyncConfig({
        ...createInitialSyncConfig({
          recipients: [ageKeys.recipient],
        }),
        entries: [],
      }),
      "utf8",
    );

    const status = await ctx.runCli(["status"]);
    const output = stripAnsi(status.stdout);

    expect(output).toContain("Push changes (repository)");
    expect(output).toContain("Delete (1)");
    expect(output).toContain(".config/prune-status/config.toml");
  }, 60_000);

  it("push prunes a removed default entry artifact", async () => {
    const configDir = join(ctx.homeDir, ".config", "prune-push");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "enabled = true\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);

    const artifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "prune-push",
      "config.toml",
    );
    expect(await readFile(artifact, "utf8")).toBe("enabled = true\n");

    await writeFile(
      join(ctx.xdgDir, "dotweave", "repository", "manifest.jsonc"),
      formatSyncConfig({
        ...createInitialSyncConfig({
          recipients: [ageKeys.recipient],
        }),
        entries: [],
      }),
      "utf8",
    );

    const result = await ctx.runCli(["push"]);

    expect(stripAnsi(result.stdout)).toContain("1 stale artifacts removed");
    await expect(lstat(artifact)).rejects.toThrow();
  }, 60_000);

  it("push --profile work prunes a non-default profile artifact after final entry removal", async () => {
    const configDir = join(ctx.homeDir, ".config", "work-prune");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "workspace = true\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["profile", "add", "work"]);
    await ctx.runCli(["track", configDir, "--profile", "work"]);
    await ctx.runCli(["push", "--profile", "work"]);

    const artifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".config",
      "work-prune",
      "config.toml",
    );
    expect(await readFile(artifact, "utf8")).toBe("workspace = true\n");

    await writeFile(
      join(ctx.xdgDir, "dotweave", "repository", "manifest.jsonc"),
      formatSyncConfig({
        ...createInitialSyncConfig({
          recipients: [ageKeys.recipient],
        }),
        profiles: ["work"],
        entries: [],
      }),
      "utf8",
    );

    const result = await ctx.runCli(["push", "--profile", "work"]);

    expect(stripAnsi(result.stdout)).toContain("1 stale artifacts removed");
    await expect(lstat(artifact)).rejects.toThrow();
  }, 60_000);

  it("fails cleanly when pulling a secret artifact with the wrong identity", async () => {
    const configDir = join(ctx.homeDir, ".config", "wrong-identity");
    const secretFile = join(configDir, "token.env");
    const originalKeys = await ctx.createAgeKeyPair();
    const wrongKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(originalKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(secretFile, "TOKEN=remote\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", secretFile, "--mode", "secret"]);
    await ctx.runCli(["push"]);

    await writeFile(secretFile, "local-survivor\n");
    await ctx.writeIdentityFile(wrongKeys.identity);

    const result = await ctx.runCli(["pull", "-y"], { reject: false });
    const stderr = stripAnsi(result.stderr);
    const siblingNames = await readdir(configDir);

    expect(result.exitCode).not.toBe(0);
    expect(stderr).toContain("Failed to decrypt a secret repository artifact");
    expect(stderr).toContain("Identity file:");
    expect(stderr).toContain("matches one of its recipients");
    expect(await readFile(secretFile, "utf8")).toBe("local-survivor\n");
    expect(
      siblingNames.filter((name) => name.includes(".dotweave-sync-")),
    ).toEqual([]);
  }, 60_000);

  it("sets mode on tracked roots via track command", async () => {
    const bundleDirectory = join(ctx.homeDir, ".config", "mytool");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(bundleDirectory, { recursive: true });

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", bundleDirectory]);

    const result = await ctx.runCli([
      "track",
      bundleDirectory,
      "--mode",
      "secret",
    ]);

    expect(result.exitCode).toBe(0);
    expect(stripAnsi(result.stdout)).toContain(
      "Updated tracking for .config/mytool",
    );
    expect(stripAnsi(result.stdout)).toContain("mode");
    expect(stripAnsi(result.stdout)).toContain("secret");
  });

  it("previews push changes without writing artifacts when --dry-run is used", async () => {
    const configDir = join(ctx.homeDir, ".config", "dryapp");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "mode = dry\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);

    const result = await ctx.runCli(["push", "--dry-run"]);

    expect(result.exitCode).toBe(0);
    expect(stripAnsi(result.stdout)).toContain("Push preview");
    expect(stripAnsi(result.stdout)).toContain("dry run");

    // The artifact should NOT have been written to the repository
    const artifact = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "dryapp",
      "config.toml",
    );
    await expect(readFile(artifact, "utf8")).rejects.toThrow();
  });

  it("previews pull changes without overwriting local files when --dry-run is used", async () => {
    const configDir = join(ctx.homeDir, ".config", "pullapp");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "version = 1\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);

    // Modify the local file so it diverges from the repository
    await writeFile(configFile, "version = 2\n");

    const result = await ctx.runCli(["pull", "--dry-run"]);

    expect(result.exitCode).toBe(0);
    expect(stripAnsi(result.stdout)).toContain("Pull preview");
    expect(stripAnsi(result.stdout)).toContain("dry run");

    // Local file should still have the modified content
    expect(await readFile(configFile, "utf8")).toContain("version = 2");
  });

  it("prints that there are no pull changes and exits without prompting", async () => {
    const configDir = join(ctx.homeDir, ".config", "steadyapp");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "version = 1\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);

    const result = await ctx.runCli(["pull"]);

    expect(result.exitCode).toBe(0);
    expect(stripAnsi(result.stdout)).toContain("Already up to date");
  });

  it.skipIf(process.platform === "win32")(
    "ignores repository artifact permission noise when content and executable intent match",
    async () => {
      const configDir = join(ctx.homeDir, ".config", "permission-noise");
      const configFile = join(configDir, "config.toml");
      const ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await mkdir(configDir, { recursive: true });
      await writeFile(configFile, "version = 1\n");

      await ctx.runCli(["init"]);
      await ctx.runCli(["track", configDir]);
      await ctx.runCli(["push"]);

      const artifactFile = join(
        ctx.xdgDir,
        "dotweave",
        "repository",
        "profiles",
        "default",
        ".config",
        "permission-noise",
        "config.toml",
      );

      await chmod(artifactFile, 0o600);

      const status = await ctx.runCli(["status"]);
      const statusOutput = stripAnsi(status.stdout);

      expect(statusOutput).toContain("No push changes");
      expect(statusOutput).toContain("No pull changes");

      const pull = await ctx.runCli(["pull"]);

      expect(stripAnsi(pull.stdout)).toContain("Already up to date");
    },
  );

  it.skipIf(process.platform === "win32")(
    "reports local drift from explicit manifest permission",
    async () => {
      const keyFile = join(ctx.homeDir, ".ssh", "id_rsa");
      const ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await mkdir(join(ctx.homeDir, ".ssh"), { recursive: true });
      await writeFile(keyFile, "key\n");
      await chmod(keyFile, 0o600);

      await ctx.runCli(["init"]);
      await writeFile(
        join(ctx.xdgDir, "dotweave", "repository", "manifest.jsonc"),
        formatSyncConfig({
          ...createInitialSyncConfig({
            recipients: [ageKeys.recipient],
          }),
          entries: [
            {
              kind: "file",
              localPath: {
                default: "~/.ssh/id_rsa",
              },
              mode: {
                default: "normal",
              },
              permission: {
                default: "0600",
              },
            },
          ],
        }),
        "utf8",
      );
      await ctx.runCli(["push"]);
      await chmod(keyFile, 0o644);

      const status = await ctx.runCli(["status"]);
      const pullPreview = await ctx.runCli(["pull", "--dry-run"]);

      expect(stripAnsi(status.stdout)).toContain("No push changes");
      expect(stripAnsi(status.stdout)).toContain("Changed (1)");
      expect(stripAnsi(pullPreview.stdout)).toContain("Planned pull changes");
      expect(stripAnsi(pullPreview.stdout)).toContain(keyFile);
    },
  );

  it.skipIf(process.platform !== "win32")(
    "treats opposite Windows text line endings as unchanged during pull",
    async () => {
      const sourceRepository = join(ctx.workspace, "remote-sync");
      const keyFile = join(ctx.workspace, "line-endings-clean.agekey");
      const configDir = join(ctx.homeDir, ".config", "line-endings-clean");
      const configFile = join(configDir, "config.toml");
      const reverseFile = join(configDir, "reverse.toml");
      const ageKeys = await ctx.createAgeKeyPair();

      await mkdir(
        join(
          sourceRepository,
          "profiles",
          "default",
          ".config",
          "line-endings-clean",
        ),
        {
          recursive: true,
        },
      );
      await mkdir(configDir, { recursive: true });
      await writeFile(
        join(sourceRepository, "manifest.jsonc"),
        formatSyncConfig({
          ...createInitialSyncConfig({
            recipients: [ageKeys.recipient],
          }),
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/line-endings-clean",
              },
              mode: {
                default: "normal",
              },
            },
          ],
        }),
        "utf8",
      );
      await writeFile(
        join(
          sourceRepository,
          "profiles",
          "default",
          ".config",
          "line-endings-clean",
          "config.toml",
        ),
        "version = 1\r\nname = test\r\n",
        "utf8",
      );
      await writeFile(
        join(
          sourceRepository,
          "profiles",
          "default",
          ".config",
          "line-endings-clean",
          "reverse.toml",
        ),
        "version = 1\nname = test\n",
        "utf8",
      );
      await writeFile(configFile, "version = 1\nname = test\n", "utf8");
      await writeFile(reverseFile, "version = 1\r\nname = test\r\n", "utf8");
      await ctx.runGit(["init", "-b", "main"], sourceRepository);
      await ctx.runGit(["add", "."], sourceRepository);
      await ctx.runGit(
        ["commit", "-m", "seed normalized line endings"],
        sourceRepository,
      );
      await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");

      await ctx.runCli(["init", sourceRepository, "--key-file", keyFile]);
      const result = await ctx.runCli(["pull"]);

      expect(result.exitCode).toBe(0);
      expect(stripAnsi(result.stdout)).toContain("Already up to date");
      expect(stripAnsi(result.stdout)).not.toContain("Planned pull changes");
    },
  );

  it.skipIf(process.platform !== "win32")(
    "normalizes Windows text line endings without hiding BOM changes during pull",
    async () => {
      const sourceRepository = join(ctx.workspace, "remote-sync");
      const keyFile = join(ctx.workspace, "line-endings-bom.agekey");
      const configDir = join(ctx.homeDir, ".config", "line-endings-bom");
      const configFile = join(configDir, "config.toml");
      const bomFile = join(configDir, "bom.toml");
      const ageKeys = await ctx.createAgeKeyPair();

      await mkdir(
        join(
          sourceRepository,
          "profiles",
          "default",
          ".config",
          "line-endings-bom",
        ),
        {
          recursive: true,
        },
      );
      await mkdir(configDir, { recursive: true });
      await writeFile(
        join(sourceRepository, "manifest.jsonc"),
        formatSyncConfig({
          ...createInitialSyncConfig({
            recipients: [ageKeys.recipient],
          }),
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/line-endings-bom",
              },
              mode: {
                default: "normal",
              },
            },
          ],
        }),
        "utf8",
      );
      await writeFile(
        join(
          sourceRepository,
          "profiles",
          "default",
          ".config",
          "line-endings-bom",
          "config.toml",
        ),
        "version = 1\r\nname = test\r\n",
        "utf8",
      );
      await writeFile(
        join(
          sourceRepository,
          "profiles",
          "default",
          ".config",
          "line-endings-bom",
          "bom.toml",
        ),
        "\uFEFFversion = 1\r\n",
        "utf8",
      );
      await writeFile(configFile, "version = 1\nname = test\n", "utf8");
      await writeFile(bomFile, "version = 1\n", "utf8");
      await ctx.runGit(["init", "-b", "main"], sourceRepository);
      await ctx.runGit(["add", "."], sourceRepository);
      await ctx.runGit(
        ["commit", "-m", "seed normalized line endings"],
        sourceRepository,
      );
      await writeFile(keyFile, `${ageKeys.identity}\n`, "utf8");

      await ctx.runCli(["init", sourceRepository, "--key-file", keyFile]);
      const result = await ctx.runCli(["pull"], { reject: false });

      expect(result.exitCode).not.toBe(0);
      expect(stripAnsi(result.stdout)).toContain("Planned pull changes");
      expect(stripAnsi(result.stdout)).toContain("bom.toml");
      expect(stripAnsi(result.stdout)).not.toContain("config.toml");
    },
  );

  it("fails in non-interactive mode without -y when pull changes exist", async () => {
    const configDir = join(ctx.homeDir, ".config", "noninteractive-pull");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "version = 1\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);
    await writeFile(configFile, "version = 2\n");

    const result = await ctx.runCli(["pull"], { reject: false });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).toContain(
      "Pull confirmation requires an interactive terminal.",
    );
    expect(stripAnsi(result.stderr)).toContain("dotweave pull -y");
    expect(await readFile(configFile, "utf8")).toContain("version = 2");
  });

  itWithPty("cancels pull interactively unless y is entered", async () => {
    const configDir = join(ctx.homeDir, ".config", "interactive-pull");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "version = 1\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);
    await writeFile(configFile, "version = 2\n");

    const session = createPtySession({
      args: [...cliNodeOptions, "pull"],
      cwd: ctx.workspace,
      env: {
        ...ctx.baseEnv,
      },
      file: process.execPath,
    });

    try {
      const output = await session.waitFor(
        "Apply these changes? [y/N]",
        10_000,
      );

      expect(output).toContain(configFile);
      session.write("n\r");

      const cancelledOutput = await session.waitFor(
        "Skipped pull changes",
        10_000,
      );

      expect(cancelledOutput).toContain(configFile);
      expect(await readFile(configFile, "utf8")).toContain("version = 2");
    } finally {
      session.close();
    }
  });

  itWithPty(
    "cancels pull interactively when empty input is entered",
    async () => {
      const configDir = join(ctx.homeDir, ".config", "interactive-empty");
      const configFile = join(configDir, "config.toml");
      const ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await mkdir(configDir, { recursive: true });
      await writeFile(configFile, "version = 1\n");

      await ctx.runCli(["init"]);
      await ctx.runCli(["track", configDir]);
      await ctx.runCli(["push"]);
      await writeFile(configFile, "version = 2\n");

      const session = createPtySession({
        args: [...cliNodeOptions, "pull"],
        cwd: ctx.workspace,
        env: {
          ...ctx.baseEnv,
        },
        file: process.execPath,
      });

      try {
        const output = await session.waitFor(
          "Apply these changes? [y/N]",
          10_000,
        );

        expect(output).toContain(configFile);
        session.write("\r");

        const cancelledOutput = await session.waitFor(
          "Skipped pull changes",
          10_000,
        );

        expect(cancelledOutput).toContain(configFile);
        expect(await readFile(configFile, "utf8")).toContain("version = 2");
      } finally {
        session.close();
      }
    },
  );

  itWithPty("applies pull interactively when y is entered", async () => {
    const configDir = join(ctx.homeDir, ".config", "interactive-accept");
    const configFile = join(configDir, "config.toml");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, "version = 1\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);
    await writeFile(configFile, "version = 2\n");

    const session = createPtySession({
      args: [...cliNodeOptions, "pull"],
      cwd: ctx.workspace,
      env: {
        ...ctx.baseEnv,
      },
      file: process.execPath,
    });

    try {
      const output = await session.waitFor(
        "Apply these changes? [y/N]",
        10_000,
      );

      expect(output).toContain(configFile);
      session.write("y\r");

      const appliedOutput = await session.waitFor("Pull complete", 10_000);

      expect(appliedOutput).toContain(configFile);
      expect(await readFile(configFile, "utf8")).toContain("version = 1");
    } finally {
      session.close();
    }
  });

  itWithPty(
    "applies pull interactively when uppercase Y is entered",
    async () => {
      const configDir = join(ctx.homeDir, ".config", "interactive-uppercase");
      const configFile = join(configDir, "config.toml");
      const ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await mkdir(configDir, { recursive: true });
      await writeFile(configFile, "version = 1\n");

      await ctx.runCli(["init"]);
      await ctx.runCli(["track", configDir]);
      await ctx.runCli(["push"]);
      await writeFile(configFile, "version = 2\n");

      const session = createPtySession({
        args: [...cliNodeOptions, "pull"],
        cwd: ctx.workspace,
        env: {
          ...ctx.baseEnv,
        },
        file: process.execPath,
      });

      try {
        const output = await session.waitFor(
          "Apply these changes? [y/N]",
          10_000,
        );

        expect(output).toContain(configFile);
        session.write("Y\r");

        const appliedOutput = await session.waitFor("Pull complete", 10_000);

        expect(appliedOutput).toContain(configFile);
        expect(await readFile(configFile, "utf8")).toContain("version = 1");
      } finally {
        session.close();
      }
    },
  );

  it("returns a non-zero exit code when pushing without init", async () => {
    const result = await ctx.runCli(["push"], { reject: false });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).not.toBe("");
  });

  it("returns a non-zero exit code when pulling without init", async () => {
    const result = await ctx.runCli(["pull"], { reject: false });

    expect(result.exitCode).not.toBe(0);
    expect(stripAnsi(result.stderr)).not.toBe("");
  });

  it("deletes local files that were removed from repository during pull", async () => {
    const appDirectory = join(ctx.homeDir, ".config", "testapp");
    const configFile = join(appDirectory, "config.yaml");
    const dataFile = join(appDirectory, "data.json");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(configFile, "setting: value\n");
    await writeFile(dataFile, '{"data": true}\n');

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", appDirectory]);
    await ctx.runCli(["push"]);

    const repoConfigFile = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "testapp",
      "config.yaml",
    );
    const repoDataFile = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "testapp",
      "data.json",
    );

    expect(await readFile(repoConfigFile, "utf8")).toContain("setting: value");
    expect(await readFile(repoDataFile, "utf8")).toContain('"data": true');

    await rm(repoDataFile);

    const result = await ctx.runCli(["pull", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(stripAnsi(result.stdout)).toContain("remove");
    expect(await readFile(configFile, "utf8")).toContain("setting: value");
    await expect(readFile(dataFile, "utf8")).rejects.toThrow();
  });

  it("deletes multiple local files when they are removed from repository", async () => {
    const notesDirectory = join(ctx.homeDir, ".config", "notes");
    const note1 = join(notesDirectory, "todo.txt");
    const note2 = join(notesDirectory, "ideas.txt");
    const note3 = join(notesDirectory, "reminders.txt");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(notesDirectory, { recursive: true });
    await writeFile(note1, "Buy milk\n");
    await writeFile(note2, "New app idea\n");
    await writeFile(note3, "Call mom\n");

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", notesDirectory]);
    await ctx.runCli(["push"]);

    const repoNote2 = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "notes",
      "ideas.txt",
    );
    const repoNote3 = join(
      ctx.xdgDir,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "notes",
      "reminders.txt",
    );

    await rm(repoNote2);
    await rm(repoNote3);

    const result = await ctx.runCli(["pull", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(note1, "utf8")).toContain("Buy milk");
    await expect(readFile(note2, "utf8")).rejects.toThrow();
    await expect(readFile(note3, "utf8")).rejects.toThrow();
  });

  it("recovers from an interrupted sync that left behind backup files", async () => {
    const configDir = join(ctx.homeDir, ".config", "recoveryapp");
    const configFile = join(configDir, "config.json");
    const ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await mkdir(configDir, { recursive: true });
    await writeFile(configFile, '{"version": 1}\n');

    await ctx.runCli(["init"]);
    await ctx.runCli(["track", configDir]);
    await ctx.runCli(["push"]);

    // Simulate an interrupted sync by manually creating a backup file
    const backupFile = join(
      configDir,
      ".config.json.dotweave-sync-backup-1234",
    );
    await writeFile(backupFile, '{"version": "backup"}\n');

    // Run pull -y, it should still work and ideally clean up stray backup files
    // (replacePathAtomically cleans up backup files in its finally block,
    // but here we are simulating one that stayed because the process was killed)
    const result = await ctx.runCli(["pull", "-y"]);

    expect(result.exitCode).toBe(0);
    expect(await readFile(configFile, "utf8")).toContain('"version": 1');
    // Note: The CLI doesn't currently proactively scan and delete *old* backup files from *previous* runs,
    // but the sync should still succeed.
  });
});
