import {
  chmod,
  lstat,
  mkdir,
  readFile,
  readlink,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { AppConstants } from "#app/config/constants.ts";
import { createSymlink } from "#app/lib/filesystem.ts";
import { toPosixLinkTarget } from "#app/lib/path.ts";

import {
  parseManifestEntries,
  readManifestJson,
} from "#test/helpers/mock-factories.ts";

const mockEnv = vi.hoisted(() => ({
  APPDATA: "",
  HOME: "",
  LOCALAPPDATA: "",
  USERPROFILE: "",
  XDG_CONFIG_HOME: "",
  WSL_DISTRO_NAME: undefined as string | undefined,
}));

vi.mock("#app/lib/env.ts", () => ({
  ENV: mockEnv,
}));

import * as platformConfig from "#app/config/platform.ts";
import {
  createAgeKeyPair,
  createTemporaryDirectory,
  runGit,
  writeIdentityFile,
} from "../test/helpers/sync-fixture.ts";
import { initializeSyncDirectory } from "./init.ts";
import {
  addProfile,
  assignProfiles,
  clearActiveProfile,
  listProfiles,
  setActiveProfile,
} from "./profile.ts";
import { preparePull, pullChanges } from "./pull.ts";
import { pushChanges } from "./push.ts";
import { getStatus } from "./status.ts";
import { setTargetMode } from "./sync-mode.ts";
import { trackTarget } from "./track.ts";

const temporaryDirectories: string[] = [];

// Symlinks are stored as regular metadata files suffixed with
// `.dotweave.symlink`, whose contents are the POSIX-normalized link target.
const symlinkArtifactPath = (plainArtifactPath: string) =>
  `${plainArtifactPath}${AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX}`;

const expectSymlinkArtifact = async (
  plainArtifactPath: string,
  target: string,
) => {
  const metaPath = symlinkArtifactPath(plainArtifactPath);
  const stats = await lstat(metaPath);

  expect(stats.isFile()).toBe(true);
  expect(stats.isSymbolicLink()).toBe(false);
  expect(await readFile(metaPath, "utf8")).toBe(toPosixLinkTarget(target));
};

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory("dotweave-sync-test-");

  temporaryDirectories.push(directory);

  return directory;
};

const setEnvironment = (homeDirectory: string, xdgConfigHome: string) => {
  mockEnv.APPDATA = xdgConfigHome;
  mockEnv.HOME = homeDirectory;
  mockEnv.LOCALAPPDATA = join(homeDirectory, "AppData", "Local");
  mockEnv.USERPROFILE = homeDirectory;
  mockEnv.XDG_CONFIG_HOME = xdgConfigHome;
};

afterEach(async () => {
  vi.restoreAllMocks();
  mockEnv.APPDATA = "";
  mockEnv.HOME = "";
  mockEnv.LOCALAPPDATA = "";
  mockEnv.USERPROFILE = "";
  mockEnv.XDG_CONFIG_HOME = "";
  mockEnv.WSL_DISTRO_NAME = undefined;

  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

describe("sync service", () => {
  it("tracks entries in v7 config format", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sharedDirectory = join(homeDirectory, ".config", "zsh");
    const workFile = join(homeDirectory, ".gitconfig-work");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(sharedDirectory, { recursive: true });
    await writeFile(
      join(sharedDirectory, "secrets.zsh"),
      "export TOKEN=work\n",
    );
    await writeFile(workFile, "[include]\npath=~/.gitconfig.work\n");

    setEnvironment(homeDirectory, xdgConfigHome);
    const cwd = homeDirectory;

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        target: sharedDirectory,
      },
      cwd,
    );
    await trackTarget(
      {
        mode: "secret",
        target: workFile,
      },
      cwd,
    );

    const manifestText = await readFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      "utf8",
    );
    const config = readManifestJson(manifestText);

    expect(config.version).toBe(8);
    expect(JSON.parse(manifestText)).toHaveProperty("age");
    expect(config.entries).toEqual([
      {
        kind: "directory",
        localPath: { default: "~/.config/zsh" },
        mode: { default: "normal" },
      },
      {
        kind: "file",
        localPath: { default: "~/.gitconfig-work" },
        mode: { default: "secret" },
      },
    ]);
  });

  it("tracks explicit repoPath values and syncs through them", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        repoPath: { default: "profiles/shared/git/main.conf" },
        target: gitconfig,
      },
      homeDirectory,
    );

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    const config = readManifestJson(await readFile(manifestPath, "utf8"));

    expect(config.entries).toEqual([
      {
        kind: "file",
        localPath: { default: "~/.gitconfig" },
        repoPath: { default: "profiles/shared/git/main.conf" },
        mode: { default: "normal" },
      },
    ]);

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "profiles",
      "shared",
      "git",
      "main.conf",
    );

    expect(await readFile(artifactPath, "utf8")).toContain("name=test");

    await writeFile(gitconfig, "[user]\nname=changed\n");
    await pullChanges({ dryRun: false });

    expect(await readFile(gitconfig, "utf8")).toBe("[user]\nname=test\n");
  });

  it("writes pushed artifacts under physical profiles layout", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=option-b\n");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        target: gitconfig,
      },
      homeDirectory,
    );

    await pushChanges({ dryRun: false });

    const repositoryDirectory = join(xdgConfigHome, "dotweave", "repository");
    const physicalArtifactPath = join(
      repositoryDirectory,
      "profiles",
      "default",
      ".gitconfig",
    );
    const oldLayoutArtifactPath = join(
      repositoryDirectory,
      "default",
      ".gitconfig",
    );

    expect(await readFile(physicalArtifactPath, "utf8")).toBe(
      "[user]\nname=option-b\n",
    );
    await expect(lstat(oldLayoutArtifactPath)).rejects.toThrow();
  });

  it("keeps generated secret directory artifacts visible to git when ignore rules match secret artifacts", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const vividentDirectory = join(homeDirectory, ".vivident");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(vividentDirectory, { recursive: true });
    await writeFile(
      join(vividentDirectory, "config.json"),
      '{"theme":"dark"}\n',
    );
    await writeFile(join(vividentDirectory, "state.txt"), "window=main\n");

    setEnvironment(homeDirectory, xdgConfigHome);

    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await writeFile(join(syncDirectory, ".gitignore"), "*.dotweave.secret\n");

    await trackTarget(
      {
        mode: "secret",
        target: vividentDirectory,
      },
      homeDirectory,
    );
    await pushChanges({ dryRun: false });

    const configArtifactPath = join(
      syncDirectory,
      "profiles",
      "default",
      ".vivident",
      "config.json.dotweave.secret",
    );
    const stateArtifactPath = join(
      syncDirectory,
      "profiles",
      "default",
      ".vivident",
      "state.txt.dotweave.secret",
    );

    expect(await readFile(configArtifactPath, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );
    expect(await readFile(stateArtifactPath, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );

    const ignoredStatus = await runGit(
      ["status", "--ignored", "--short", "--untracked-files=all"],
      syncDirectory,
    );
    expect(ignoredStatus.stdout).not.toContain(
      "!! profiles/default/.vivident/config.json.dotweave.secret",
    );
    expect(ignoredStatus.stdout).not.toContain(
      "!! profiles/default/.vivident/state.txt.dotweave.secret",
    );

    const status = await runGit(
      ["status", "--short", "--untracked-files=all"],
      syncDirectory,
    );
    expect(status.stdout).toContain(
      "?? profiles/default/.vivident/config.json.dotweave.secret",
    );
    expect(status.stdout).toContain(
      "?? profiles/default/.vivident/state.txt.dotweave.secret",
    );
  });

  it("keeps repository artifact bytes stable under core.autocrlf before repeated pull", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    setEnvironment(homeDirectory, xdgConfigHome);

    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        target: gitconfig,
      },
      homeDirectory,
    );
    await pushChanges({ dryRun: false });

    const artifactPath = join(
      syncDirectory,
      "profiles",
      "default",
      ".gitconfig",
    );

    await runGit(["add", "."], syncDirectory);
    await runGit(["commit", "-m", "store artifacts"], syncDirectory);
    await runGit(["config", "core.autocrlf", "true"], syncDirectory);

    await rm(artifactPath);
    await runGit(
      ["checkout", "--", "profiles/default/.gitconfig"],
      syncDirectory,
    );

    expect(await readFile(join(syncDirectory, ".gitattributes"), "utf8")).toBe(
      "* -text\n",
    );
    expect(await readFile(artifactPath, "utf8")).toBe("[user]\nname=test\n");

    await writeFile(gitconfig, "[user]\nname=changed\n");

    await pullChanges({ dryRun: false });
    const secondPull = await preparePull({ dryRun: true });

    expect(await readFile(gitconfig, "utf8")).toBe("[user]\nname=test\n");
    expect(secondPull.plan.updatedLocalPaths).toEqual([]);
  });

  it("updates repoPath when re-tracking an existing entry", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget(
      {
        mode: "normal",
        target: gitconfig,
      },
      homeDirectory,
    );

    const result = await trackTarget(
      {
        mode: "normal",
        repoPath: { default: "profiles/shared/git/main.conf" },
        target: gitconfig,
      },
      homeDirectory,
    );

    expect(result.alreadyTracked).toBe(true);
    expect(result.changed).toBe(true);
    expect(result.repoPath).toBe("profiles/shared/git/main.conf");

    await pushChanges({ dryRun: false });

    const updatedArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "profiles",
      "shared",
      "git",
      "main.conf",
    );
    const originalArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".gitconfig",
    );

    expect(await readFile(updatedArtifactPath, "utf8")).toContain("name=test");
    await expect(readFile(originalArtifactPath, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("preserves WSL mode overrides when tracking an existing root", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const bundleDirectory = join(homeDirectory, ".config", "mytool");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    mockEnv.WSL_DISTRO_NAME = "Ubuntu";
    const cwd = homeDirectory;

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(bundleDirectory, { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/mytool" },
              mode: { default: "secret", wsl: "secret" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await trackTarget(
      {
        mode: "secret",
        target: bundleDirectory,
      },
      cwd,
    );

    const entries = parseManifestEntries(
      await readFile(
        join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
        "utf8",
      ),
    );

    expect(result.alreadyTracked).toBe(true);
    expect(result.changed).toBe(false);
    expect(entries[0]?.mode).toEqual({ default: "secret", wsl: "secret" });
  });

  it("manages the active profile through the global config", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sharedDirectory = join(homeDirectory, ".config", "zsh");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(sharedDirectory, { recursive: true });
    await writeFile(
      join(sharedDirectory, "secrets.zsh"),
      "export TOKEN=work\n",
    );

    setEnvironment(homeDirectory, xdgConfigHome);
    const cwd = homeDirectory;

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget(
      {
        mode: "normal",
        target: sharedDirectory,
      },
      cwd,
    );
    await setTargetMode(
      {
        mode: "secret",
        target: join(sharedDirectory, "secrets.zsh"),
      },
      cwd,
    );
    await addProfile("work");

    expect(await setActiveProfile("work")).toMatchObject({
      action: "use",
      activeProfile: "work",
      profile: "work",
    });
    expect(await clearActiveProfile()).toMatchObject({
      action: "clear",
    });
  });

  it("stores child overrides under explicit parent repo paths", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "app");
    const publicFile = join(appDirectory, "public.txt");
    const secretFile = join(appDirectory, "secret.txt");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(publicFile, "public\n");
    await writeFile(secretFile, "secret\n");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget(
      {
        mode: "normal",
        repoPath: { default: "profiles/shared/app" },
        target: appDirectory,
      },
      homeDirectory,
    );
    await setTargetMode(
      {
        mode: "secret",
        target: secretFile,
      },
      homeDirectory,
    );

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    const configEntries = parseManifestEntries(
      await readFile(manifestPath, "utf8"),
    );

    expect(configEntries).toEqual([
      {
        kind: "directory",
        localPath: { default: "~/.config/app" },
        repoPath: { default: "profiles/shared/app" },
        mode: { default: "normal" },
      },
      {
        kind: "file",
        localPath: { default: "~/.config/app/secret.txt" },
        repoPath: { default: "profiles/shared/app/secret.txt" },
        mode: { default: "secret" },
      },
    ]);

    await pushChanges({ dryRun: false });

    const publicArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "profiles",
      "shared",
      "app",
      "public.txt",
    );
    const secretArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "profiles",
      "shared",
      "app",
      "secret.txt.dotweave.secret",
    );

    expect(await readFile(publicArtifactPath, "utf8")).toBe("public\n");
    expect(await readFile(secretArtifactPath, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );
  });

  it("collapses redundant WSL mode overrides when updating an existing entry mode", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    mockEnv.WSL_DISTRO_NAME = "Ubuntu";
    const cwd = homeDirectory;

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "secret", wsl: "secret" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await setTargetMode(
      {
        mode: "secret",
        target: gitconfig,
      },
      cwd,
    );

    const entries = parseManifestEntries(
      await readFile(
        join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
        "utf8",
      ),
    );

    expect(result.action).toBe("updated");
    expect(entries[0]?.mode).toEqual({ default: "secret" });
  });

  it("pushes and pulls with the active profile", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const sharedFile = join(zshDirectory, "zshrc");
    const secretsFile = join(zshDirectory, "secrets.zsh");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(sharedFile, "export PATH=$PATH:$HOME/bin\n");
    await writeFile(secretsFile, "export TOKEN=work\n");

    setEnvironment(homeDirectory, xdgConfigHome);
    const cwd = homeDirectory;

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget(
      {
        mode: "normal",
        target: zshDirectory,
      },
      cwd,
    );
    await setTargetMode(
      {
        mode: "secret",
        target: secretsFile,
      },
      cwd,
    );

    await pushChanges({
      dryRun: false,
    });

    const sharedArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
      "zshrc",
    );
    const secretArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
      "secrets.zsh.dotweave.secret",
    );

    expect(await readFile(sharedArtifact, "utf8")).toContain("PATH");
    expect(await readFile(secretArtifact, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );

    await writeFile(secretsFile, "local-change\n");
    await pullChanges({
      dryRun: false,
    });

    expect(await readFile(secretsFile, "utf8")).toContain("TOKEN=work");

    await setTargetMode(
      {
        mode: "normal",
        target: secretsFile,
      },
      cwd,
    );

    const entriesAfterModeChange = parseManifestEntries(
      await readFile(
        join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
        "utf8",
      ),
    );
    const secretEntry = entriesAfterModeChange.find(
      (entry) => entry.localPath?.default === "~/.config/zsh/secrets.zsh",
    );

    expect(secretEntry?.mode).toEqual({ default: "normal" });
  });

  it("skips Windows-ignored secret artifacts during pull", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const secretsFile = join(zshDirectory, "secrets.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(secretsFile, "export TOKEN=linux\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal", win: "ignore" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/secrets.zsh" },
              mode: { default: "secret", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await pushChanges({
      dryRun: false,
    });

    const secretArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
      "secrets.zsh.dotweave.secret",
    );
    expect(await readFile(secretArtifact, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );

    await writeFile(secretsFile, "local-change\n");

    platformSpy.mockReturnValue("win");
    await expect(
      pullChanges({
        dryRun: false,
      }),
    ).resolves.toMatchObject({
      decryptedFileCount: 0,
    });

    expect(await readFile(secretsFile, "utf8")).toBe("local-change\n");
  });

  it("prunes orphaned default-profile artifacts after manifest entries are removed", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfigFile = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfigFile, "[user]\n  name = Dotweave\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".gitconfig",
    );
    expect(await readFile(artifactPath, "utf8")).toBe(
      "[user]\n  name = Dotweave\n",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("deletes artifacts for entries changed to explicit ignore during push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfigFile = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfigFile, "[user]\n  name = Dotweave\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".gitconfig",
    );
    expect(await readFile(artifactPath, "utf8")).toBe(
      "[user]\n  name = Dotweave\n",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const result = await pushChanges({ dryRun: false });

    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.changes.deleted).toEqual(["default/.gitconfig"]);
    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("deletes secret artifacts for entries changed to explicit ignore during push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const tokenDirectory = join(homeDirectory, ".config", "app");
    const tokenFile = join(tokenDirectory, "token");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(tokenDirectory, { recursive: true });
    await writeFile(tokenFile, "super-secret\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.config/app/token" },
              mode: { default: "secret" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "token.dotweave.secret",
    );
    expect(await readFile(artifactPath, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.config/app/token" },
              mode: { default: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("deletes directory subtree artifacts for entries changed to explicit ignore during push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "app");
    const nestedDirectory = join(appDirectory, "nested");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(nestedDirectory, { recursive: true });
    await writeFile(join(appDirectory, "settings.json"), '{"theme":"dark"}\n');
    await writeFile(join(nestedDirectory, "theme.json"), '{"accent":"blue"}\n');

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/app" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const settingsArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "settings.json",
    );
    const nestedArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "nested",
      "theme.json",
    );
    expect(await readFile(settingsArtifact, "utf8")).toBe('{"theme":"dark"}\n');
    expect(await readFile(nestedArtifact, "utf8")).toBe('{"accent":"blue"}\n');

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/app" },
              mode: { default: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(2);
    await expect(lstat(settingsArtifact)).rejects.toThrow();
    await expect(lstat(nestedArtifact)).rejects.toThrow();
  });

  it("does not delete Windows-ignored artifacts during push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const zshrcFile = join(zshDirectory, ".zshrc");
    const secretsFile = join(zshDirectory, "secrets.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(zshrcFile, "source ~/.config/zsh/secrets.zsh\n");
    await writeFile(secretsFile, "export TOKEN=linux\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal", win: "ignore" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/secrets.zsh" },
              mode: { default: "secret", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await pushChanges({
      dryRun: false,
    });

    const secretArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
      "secrets.zsh.dotweave.secret",
    );
    const plainArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
      ".zshrc",
    );
    expect(await readFile(plainArtifact, "utf8")).toBe(
      "source ~/.config/zsh/secrets.zsh\n",
    );
    expect(await readFile(secretArtifact, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );

    platformSpy.mockReturnValue("win");
    const result = await pushChanges({
      dryRun: false,
    });

    expect(result.deletedArtifactCount).toBe(0);
    expect(await readFile(plainArtifact, "utf8")).toBe(
      "source ~/.config/zsh/secrets.zsh\n",
    );
    expect(await readFile(secretArtifact, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );
  });

  it("pushes only the platform-specific child artifact when a directory parent contains the source file", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const platformFile = join(zshDirectory, "platform.zsh");
    const otherFile = join(zshDirectory, "other.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(platformFile, "wsl platform\n");
    await writeFile(otherFile, "other\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: [],
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/platform.zsh" },
              repoPath: {
                default: ".config/zsh/platform.zsh",
                wsl: ".config/zsh/platform.wsl.zsh",
              },
              mode: { default: "ignore", wsl: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const repositoryZshDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
    );
    const defaultArtifact = join(repositoryZshDirectory, "platform.zsh");
    const wslArtifact = join(repositoryZshDirectory, "platform.wsl.zsh");
    const otherArtifact = join(repositoryZshDirectory, "other.zsh");

    await mkdir(repositoryZshDirectory, { recursive: true });
    await writeFile(defaultArtifact, "stale default artifact\n");

    platformSpy.mockReturnValue("wsl");
    const result = await pushChanges({ dryRun: false });

    expect(result.plainFileCount).toBe(2);
    expect(result.deletedArtifactCount).toBe(1);
    expect(await readFile(wslArtifact, "utf8")).toBe("wsl platform\n");
    expect(await readFile(otherArtifact, "utf8")).toBe("other\n");
    await expect(lstat(defaultArtifact)).rejects.toThrow();
  });

  it("pushes only the platform-specific child artifact when no default artifact exists yet", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const platformFile = join(zshDirectory, "platform.zsh");
    const otherFile = join(zshDirectory, "other.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(platformFile, "wsl platform\n");
    await writeFile(otherFile, "other\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/platform.zsh" },
              repoPath: {
                default: ".config/zsh/platform.zsh",
                wsl: ".config/zsh/platform.wsl.zsh",
              },
              mode: { default: "ignore", wsl: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("wsl");
    const result = await pushChanges({ dryRun: false });

    const repositoryZshDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
    );
    expect(result.plainFileCount).toBe(2);
    expect(result.deletedArtifactCount).toBe(0);
    expect(
      await readFile(join(repositoryZshDirectory, "platform.wsl.zsh"), "utf8"),
    ).toBe("wsl platform\n");
    expect(
      await readFile(join(repositoryZshDirectory, "other.zsh"), "utf8"),
    ).toBe("other\n");
    await expect(
      lstat(join(repositoryZshDirectory, "platform.zsh")),
    ).rejects.toThrow();
  });

  it("pushes only the platform-specific secret child artifact when a directory parent contains the source file", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const platformFile = join(zshDirectory, "platform.zsh");
    const otherFile = join(zshDirectory, "other.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(platformFile, "secret wsl platform\n");
    await writeFile(otherFile, "other\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/platform.zsh" },
              repoPath: {
                default: ".config/zsh/platform.zsh",
                wsl: ".config/zsh/platform.wsl.zsh",
              },
              mode: { default: "ignore", wsl: "secret" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const repositoryZshDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
    );
    const defaultPlainArtifact = join(repositoryZshDirectory, "platform.zsh");
    const defaultSecretArtifact = join(
      repositoryZshDirectory,
      "platform.zsh.dotweave.secret",
    );
    const wslSecretArtifact = join(
      repositoryZshDirectory,
      "platform.wsl.zsh.dotweave.secret",
    );

    await mkdir(repositoryZshDirectory, { recursive: true });
    await writeFile(defaultPlainArtifact, "stale plain\n");
    await writeFile(defaultSecretArtifact, "stale secret\n");

    platformSpy.mockReturnValue("wsl");
    const result = await pushChanges({ dryRun: false });

    expect(result.plainFileCount).toBe(1);
    expect(result.encryptedFileCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(2);
    expect(await readFile(wslSecretArtifact, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );
    expect(
      await readFile(join(repositoryZshDirectory, "other.zsh"), "utf8"),
    ).toBe("other\n");
    await expect(lstat(defaultPlainArtifact)).rejects.toThrow();
    await expect(lstat(defaultSecretArtifact)).rejects.toThrow();
  });

  it.skipIf(process.platform === "win32")(
    "pushes only the platform-specific symlink child artifact when a directory parent contains the link",
    async () => {
      const workspace = await createWorkspace();
      const homeDirectory = join(workspace, "home");
      const xdgConfigHome = join(workspace, "xdg");
      const zshDirectory = join(homeDirectory, ".config", "zsh");
      const platformFile = join(zshDirectory, "platform.zsh");
      const otherFile = join(zshDirectory, "other.zsh");
      const ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);
      const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await mkdir(zshDirectory, { recursive: true });
      await createSymlink(".platform-target", platformFile);
      await writeFile(otherFile, "other\n");

      await initializeSyncDirectory({
        identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
        recipients: [ageKeys.recipient],
      });

      await writeFile(
        join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
        JSON.stringify(
          {
            version: 8,
            age: { recipients: [ageKeys.recipient] },
            entries: [
              {
                kind: "directory",
                localPath: { default: "~/.config/zsh" },
                mode: { default: "normal" },
              },
              {
                kind: "file",
                localPath: { default: "~/.config/zsh/platform.zsh" },
                repoPath: {
                  default: ".config/zsh/platform.zsh",
                  wsl: ".config/zsh/platform.wsl.zsh",
                },
                mode: { default: "ignore", wsl: "normal" },
              },
            ],
          },
          null,
          2,
        ),
        "utf8",
      );

      const repositoryZshDirectory = join(
        xdgConfigHome,
        "dotweave",
        "repository",
        "profiles",
        "default",
        ".config",
        "zsh",
      );
      const defaultArtifact = join(repositoryZshDirectory, "platform.zsh");
      const wslArtifact = join(repositoryZshDirectory, "platform.wsl.zsh");

      await mkdir(repositoryZshDirectory, { recursive: true });
      await writeFile(defaultArtifact, "stale default artifact\n");

      platformSpy.mockReturnValue("wsl");
      const result = await pushChanges({ dryRun: false });

      expect(result.plainFileCount).toBe(1);
      expect(result.symlinkCount).toBe(1);
      expect(result.deletedArtifactCount).toBe(1);
      await expectSymlinkArtifact(wslArtifact, ".platform-target");
      await expect(lstat(defaultArtifact)).rejects.toThrow();
    },
  );

  it("reports platform-specific child artifact changes in status without adding the default-path artifact", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(join(zshDirectory, "platform.zsh"), "wsl platform\n");
    await writeFile(join(zshDirectory, "other.zsh"), "other\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/platform.zsh" },
              repoPath: {
                default: ".config/zsh/platform.zsh",
                wsl: ".config/zsh/platform.wsl.zsh",
              },
              mode: { default: "ignore", wsl: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const repositoryZshDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
    );
    await mkdir(repositoryZshDirectory, { recursive: true });
    await writeFile(join(repositoryZshDirectory, "platform.zsh"), "stale\n");

    platformSpy.mockReturnValue("wsl");
    const status = await getStatus();

    expect(status.push.changes.added).toContain(".config/zsh/platform.wsl.zsh");
    expect(status.push.changes.added).toContain(".config/zsh/other.zsh");
    expect(status.push.changes.added).not.toContain(".config/zsh/platform.zsh");
    expect(status.push.changes.deleted).toContain(
      "default/.config/zsh/platform.zsh",
    );
  });

  it("pull applies the platform-specific child artifact instead of the parent default-path artifact", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const platformFile = join(zshDirectory, "platform.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(platformFile, "local before\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/platform.zsh" },
              repoPath: {
                default: ".config/zsh/platform.zsh",
                wsl: ".config/zsh/platform.wsl.zsh",
              },
              mode: { default: "ignore", wsl: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const repositoryZshDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "zsh",
    );
    await mkdir(repositoryZshDirectory, { recursive: true });
    await writeFile(
      join(repositoryZshDirectory, "platform.zsh"),
      "default artifact\n",
    );
    await writeFile(
      join(repositoryZshDirectory, "platform.wsl.zsh"),
      "wsl artifact\n",
    );
    await writeFile(join(repositoryZshDirectory, "other.zsh"), "other\n");

    platformSpy.mockReturnValue("wsl");
    const result = await pullChanges({ dryRun: false });

    expect(result.plainFileCount).toBe(2);
    expect(await readFile(platformFile, "utf8")).toBe("wsl artifact\n");
    expect(await readFile(join(zshDirectory, "other.zsh"), "utf8")).toBe(
      "other\n",
    );
  });

  it("keeps a profiled platform-specific child out of the parent default-path artifact when pushing that profile", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshDirectory = join(homeDirectory, ".config", "zsh");
    const platformFile = join(zshDirectory, "platform.zsh");
    const otherFile = join(zshDirectory, "other.zsh");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(zshDirectory, { recursive: true });
    await writeFile(platformFile, "work platform\n");
    await writeFile(otherFile, "other\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/zsh" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
            {
              kind: "file",
              localPath: { default: "~/.config/zsh/platform.zsh" },
              repoPath: {
                default: ".config/zsh/platform.zsh",
                wsl: ".config/zsh/platform.wsl.zsh",
              },
              mode: { default: "ignore", wsl: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const workZshDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".config",
      "zsh",
    );
    const defaultArtifact = join(workZshDirectory, "platform.zsh");
    const wslArtifact = join(workZshDirectory, "platform.wsl.zsh");

    await mkdir(workZshDirectory, { recursive: true });
    await writeFile(defaultArtifact, "stale work default artifact\n");

    platformSpy.mockReturnValue("wsl");
    const result = await pushChanges({ dryRun: false, profile: "work" });

    expect(result.plainFileCount).toBe(2);
    expect(result.deletedArtifactCount).toBe(1);
    expect(await readFile(join(workZshDirectory, "other.zsh"), "utf8")).toBe(
      "other\n",
    );
    expect(await readFile(wslArtifact, "utf8")).toBe("work platform\n");
    await expect(lstat(defaultArtifact)).rejects.toThrow();
  });

  it("does not delete artifacts for platform-ignored entries with different repo paths", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "platform-app");
    const appFile = join(appDirectory, "settings.json");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(appFile, '{"theme":"dark"}\n');

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 7,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/platform-app",
                win: "~/AppData/Roaming/platform-app",
              },
              repoPath: {
                default: ".config/platform-app",
                win: "AppData/Roaming/platform-app",
              },
              mode: { default: "normal", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await pushChanges({ dryRun: false });

    const linuxArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "platform-app",
      "settings.json",
    );
    expect(await readFile(linuxArtifact, "utf8")).toBe('{"theme":"dark"}\n');

    platformSpy.mockReturnValue("win");
    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(0);
    expect(await readFile(linuxArtifact, "utf8")).toBe('{"theme":"dark"}\n');
  });

  it("deletes current platform artifacts for entries changed to platform-specific ignore", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const linuxAppDirectory = join(homeDirectory, ".config", "app");
    const winAppDirectory = join(homeDirectory, "AppData", "Roaming", "app");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(linuxAppDirectory, { recursive: true });
    await mkdir(winAppDirectory, { recursive: true });
    await writeFile(join(linuxAppDirectory, "settings.json"), "linux\n");
    await writeFile(join(winAppDirectory, "settings.json"), "windows\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    const writeManifest = async (mode: Record<string, string>) => {
      await writeFile(
        manifestPath,
        JSON.stringify(
          {
            version: 8,
            age: { recipients: [ageKeys.recipient] },
            entries: [
              {
                kind: "directory",
                localPath: {
                  default: "~/.config/app",
                  win: "~/AppData/Roaming/app",
                },
                repoPath: {
                  default: ".config/app",
                  win: "AppData/Roaming/app",
                },
                mode,
              },
            ],
          },
          null,
          2,
        ),
        "utf8",
      );
    };

    await writeManifest({ default: "normal" });

    platformSpy.mockReturnValue("linux");
    await pushChanges({ dryRun: false });
    platformSpy.mockReturnValue("win");
    await pushChanges({ dryRun: false });

    const linuxArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "settings.json",
    );
    const winArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "AppData",
      "Roaming",
      "app",
      "settings.json",
    );
    expect(await readFile(linuxArtifact, "utf8")).toBe("linux\n");
    expect(await readFile(winArtifact, "utf8")).toBe("windows\n");

    await writeManifest({ default: "normal", win: "ignore" });

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    expect(await readFile(linuxArtifact, "utf8")).toBe("linux\n");
    await expect(lstat(winArtifact)).rejects.toThrow();
  });

  it("deletes ignored child artifacts while preserving normal directory siblings", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "app");
    const publicFile = join(appDirectory, "public.json");
    const privateFile = join(appDirectory, "private.json");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(publicFile, '{"public":true}\n');
    await writeFile(privateFile, '{"private":true}\n');

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    const writeManifest = async (childMode: "ignore" | "normal") => {
      await writeFile(
        manifestPath,
        JSON.stringify(
          {
            version: 8,
            age: { recipients: [ageKeys.recipient] },
            entries: [
              {
                kind: "directory",
                localPath: { default: "~/.config/app" },
                mode: { default: "normal" },
              },
              {
                kind: "file",
                localPath: { default: "~/.config/app/private.json" },
                mode: { default: childMode },
              },
            ],
          },
          null,
          2,
        ),
        "utf8",
      );
    };

    await writeManifest("normal");
    await pushChanges({ dryRun: false });

    const publicArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "public.json",
    );
    const privateArtifact = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "private.json",
    );
    expect(await readFile(publicArtifact, "utf8")).toBe('{"public":true}\n');
    expect(await readFile(privateArtifact, "utf8")).toBe('{"private":true}\n');

    await writeFile(publicFile, '{"public":"updated"}\n');
    await writeManifest("ignore");

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    expect(await readFile(publicArtifact, "utf8")).toBe(
      '{"public":"updated"}\n',
    );
    await expect(lstat(privateArtifact)).rejects.toThrow();
  });

  it("prunes orphaned non-default-profile artifacts after the last profile entry is removed", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Work\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".gitconfig",
    );
    expect(await readFile(artifactPath, "utf8")).toBe(
      "[user]\n  name = Work\n",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false, profile: "work" });

    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("status reports the same non-default orphan deletion that push will apply", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Work\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus({ profile: "work" });

    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.preview).toContain("work/.gitconfig");
  });

  it("default-profile status preserves work-profile artifacts while the work entry exists", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Work\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    const status = await getStatus();

    expect(status.push.deletedArtifactCount).toBe(0);
    expect(status.push.preview).not.toContain("work/.gitconfig");
  });

  it("prunes orphaned secret artifacts after manifest entries are removed", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const secretFile = join(homeDirectory, ".ssh", "id_rsa");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(join(homeDirectory, ".ssh"), { recursive: true });
    await writeFile(secretFile, "fake-private-key\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.ssh/id_rsa" },
              mode: { default: "secret" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".ssh",
      "id_rsa.dotweave.secret",
    );
    expect(await readFile(artifactPath, "utf8")).toContain(
      "BEGIN AGE ENCRYPTED FILE",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("prunes orphaned symlink artifacts after manifest entries are removed", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshrc = join(homeDirectory, ".zshrc");
    const zshenv = join(homeDirectory, ".zshenv");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(zshrc, "export PATH=~/.local/bin:$PATH\n");
    await createSymlink(".zshrc", zshenv);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.zshenv" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".zshenv",
    );
    await expectSymlinkArtifact(artifactPath, ".zshrc");

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(symlinkArtifactPath(artifactPath))).rejects.toThrow();
  });

  it("preserves directory-owned nested artifacts after a child entry is removed", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "app");
    const settingsFile = join(appDirectory, "settings.json");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(settingsFile, '{"theme":"dark"}\n');

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/app" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/app/settings.json" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "settings.json",
    );
    expect(await readFile(artifactPath, "utf8")).toBe('{"theme":"dark"}\n');

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/app" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(0);
    expect(await readFile(artifactPath, "utf8")).toBe('{"theme":"dark"}\n');
  });

  it("does not let a file entry preserve nested artifacts", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              repoPath: { default: ".config/app" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const nestedArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "settings.json",
    );
    await mkdir(join(nestedArtifactPath, ".."), { recursive: true });
    await writeFile(nestedArtifactPath, '{"stale":true}\n');

    const result = await pushChanges({ dryRun: true });

    expect(result.deletedArtifactCount).toBe(1);
  });

  it("prunes stale empty child directories under an active parent directory entry", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "active-empty-child");
    const staleChildDirectory = join(appDirectory, "old-empty");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(staleChildDirectory, { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/active-empty-child" },
              repoPath: { default: ".config/active-empty-child" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: { default: "~/.config/active-empty-child/old-empty" },
              repoPath: { default: ".config/active-empty-child/old-empty" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "active-empty-child",
    );
    const childArtifactPath = join(artifactPath, "old-empty");
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);

    await rm(staleChildDirectory, { recursive: true });
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/active-empty-child" },
              repoPath: { default: ".config/active-empty-child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.changes.added).toEqual([]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([
      "default/.config/active-empty-child/old-empty/",
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(childArtifactPath)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
  });

  it("preserves child artifacts through a remaining parent directory entry", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "overlap-app");
    const childFile = join(appDirectory, "child.json");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(childFile, '{"child":true}\n');

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-app" },
              repoPath: { default: "apps/overlap" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/overlap-app/child.json" },
              repoPath: { default: "apps/overlap/child.json" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "apps",
      "overlap",
      "child.json",
    );
    expect(await readFile(artifactPath, "utf8")).toBe('{"child":true}\n');

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-app" },
              repoPath: { default: "apps/overlap" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(0);
    expect(await readFile(artifactPath, "utf8")).toBe('{"child":true}\n');
  });

  it("replaces a stale repository directory root with a file artifact during push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "transition-app");
    const childFile = join(appDirectory, "settings.json");
    const replacementFile = join(homeDirectory, ".transition-app-file");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(childFile, '{"stale":true}\n');
    await writeFile(replacementFile, "replacement file\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/transition-app" },
              repoPath: { default: ".config/transition-app" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "transition-app",
    );
    expect(await readFile(join(artifactPath, "settings.json"), "utf8")).toBe(
      '{"stale":true}\n',
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.transition-app-file" },
              repoPath: { default: ".config/transition-app" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    expect((await lstat(artifactPath)).isFile()).toBe(true);
    expect(await readFile(artifactPath, "utf8")).toBe("replacement file\n");
  });

  it("reports an empty repository directory root replacement consistently", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const emptyDirectory = join(homeDirectory, ".config", "empty-transition");
    const replacementFile = join(homeDirectory, ".empty-transition-file");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(emptyDirectory, { recursive: true });
    await writeFile(replacementFile, "replacement file\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/empty-transition" },
              repoPath: { default: ".config/empty-transition" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "empty-transition",
    );
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.empty-transition-file" },
              repoPath: { default: ".config/empty-transition" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const dryRunResult = await pushChanges({ dryRun: true });
    const status = await getStatus();
    const result = await pushChanges({ dryRun: false });

    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.changes.added).toEqual([".config/empty-transition"]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([
      "default/.config/empty-transition/",
    ]);
    expect(result.deletedArtifactCount).toBe(1);
    expect((await lstat(artifactPath)).isFile()).toBe(true);
    expect(await readFile(artifactPath, "utf8")).toBe("replacement file\n");
  });

  it("replaces a stale repository directory root with a symlink artifact during push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "transition-link");
    const childFile = join(appDirectory, "settings.json");
    const linkTarget = join(homeDirectory, ".transition-link-target");
    const replacementLink = join(homeDirectory, ".transition-link");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(childFile, '{"stale":true}\n');
    await writeFile(linkTarget, "replacement link target\n");
    await createSymlink(".transition-link-target", replacementLink);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/transition-link" },
              repoPath: { default: ".config/transition-link" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "transition-link",
    );
    expect(await readFile(join(artifactPath, "settings.json"), "utf8")).toBe(
      '{"stale":true}\n',
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.transition-link" },
              repoPath: { default: ".config/transition-link" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(1);
    await expectSymlinkArtifact(artifactPath, ".transition-link-target");
  });

  it("replaces a repository directory root containing only stale empty descendants with a file artifact", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "empty-child-file");
    const childDirectory = join(appDirectory, "child");
    const replacementFile = join(
      homeDirectory,
      ".empty-child-file-replacement",
    );
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(replacementFile, "replacement file\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/empty-child-file" },
              repoPath: { default: ".config/empty-child-file" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: { default: "~/.config/empty-child-file/child" },
              repoPath: { default: ".config/empty-child-file/child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "empty-child-file",
    );
    const childArtifactPath = join(artifactPath, "child");
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);

    await rm(appDirectory, { recursive: true });
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.empty-child-file-replacement" },
              repoPath: { default: ".config/empty-child-file" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.changes.added).toEqual([".config/empty-child-file"]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([
      "default/.config/empty-child-file/child/",
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    expect((await lstat(artifactPath)).isFile()).toBe(true);
    expect(await readFile(artifactPath, "utf8")).toBe("replacement file\n");
  });

  it("replaces a repository directory root containing only stale empty descendants with a symlink artifact", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "empty-child-link");
    const childDirectory = join(appDirectory, "child");
    const linkTarget = join(homeDirectory, ".empty-child-link-target");
    const replacementLink = join(
      homeDirectory,
      ".empty-child-link-replacement",
    );
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(linkTarget, "replacement target\n");
    await createSymlink(".empty-child-link-target", replacementLink);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/empty-child-link" },
              repoPath: { default: ".config/empty-child-link" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: { default: "~/.config/empty-child-link/child" },
              repoPath: { default: ".config/empty-child-link/child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "empty-child-link",
    );
    const childArtifactPath = join(artifactPath, "child");
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);

    await rm(appDirectory, { recursive: true });
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.empty-child-link-replacement" },
              repoPath: { default: ".config/empty-child-link" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.changes.added).toEqual([".config/empty-child-link"]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([
      "default/.config/empty-child-link/child/",
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expectSymlinkArtifact(artifactPath, ".empty-child-link-target");
  });

  it("replaces an existing symlink artifact with a file artifact without following the symlink target", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const symlinkSource = join(homeDirectory, ".link-replacement-source");
    const symlinkTarget = join(homeDirectory, ".link-replacement-target");
    const replacementFile = join(homeDirectory, ".link-replacement-file");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(symlinkTarget, "local target content\n");
    await writeFile(replacementFile, "replacement file\n");
    await createSymlink(symlinkTarget, symlinkSource);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.link-replacement-source" },
              repoPath: { default: ".config/link-replacement" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "link-replacement",
    );
    await expectSymlinkArtifact(artifactPath, symlinkTarget);

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.link-replacement-file" },
              repoPath: { default: ".config/link-replacement" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    // The symlink is stored as a separate `.dotweave.symlink` metadata file, so
    // switching the entry to a regular file adds the plain artifact and prunes
    // the stale symlink metadata file (rather than an in-place modify).
    expect(status.push.changes.added).toEqual([".config/link-replacement"]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([
      `default/.config/link-replacement${AppConstants.SYNC.SYMLINK_ARTIFACT_SUFFIX}`,
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    expect((await lstat(artifactPath)).isFile()).toBe(true);
    expect(await readFile(artifactPath, "utf8")).toBe("replacement file\n");
    expect(await readFile(symlinkTarget, "utf8")).toBe(
      "local target content\n",
    );
    await expect(lstat(symlinkArtifactPath(artifactPath))).rejects.toThrow();
  });

  it("preserves still-owned inactive nested directory artifacts from file replacement", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "inactive-child-file");
    const childDirectory = join(appDirectory, "child");
    const ageKeys = await createAgeKeyPair();
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/inactive-child-file" },
              repoPath: { default: ".config/inactive-child-file" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: {
                default: "~/.config/inactive-child-file/child",
                win: "~/AppData/Roaming/inactive-child-file/child",
              },
              repoPath: { default: ".config/inactive-child-file/child" },
              mode: { default: "normal", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "inactive-child-file",
    );
    const childArtifactPath = join(artifactPath, "child");
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);

    await rm(appDirectory, { recursive: true });
    await writeFile(appDirectory, "replacement file\n");
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/inactive-child-file/child",
                win: "~/AppData/Roaming/inactive-child-file/child",
              },
              repoPath: { default: ".config/inactive-child-file/child" },
              mode: { default: "normal", win: "ignore" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/inactive-child-file" },
              repoPath: { default: ".config/inactive-child-file" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("win");
    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.added).toEqual([]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([]);
    expect(dryRunResult.deletedArtifactCount).toBe(0);
    expect(result.deletedArtifactCount).toBe(0);
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);
    await expect(readFile(artifactPath, "utf8")).rejects.toThrow();
  });

  it("preserves still-owned inactive nested directory artifacts from symlink replacement", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "inactive-child-link");
    const childDirectory = join(appDirectory, "child");
    const linkTarget = join(homeDirectory, ".inactive-child-link-target");
    const ageKeys = await createAgeKeyPair();
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(linkTarget, "replacement target\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/inactive-child-link" },
              repoPath: { default: ".config/inactive-child-link" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: {
                default: "~/.config/inactive-child-link/child",
                win: "~/AppData/Roaming/inactive-child-link/child",
              },
              repoPath: { default: ".config/inactive-child-link/child" },
              mode: { default: "normal", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "inactive-child-link",
    );
    const childArtifactPath = join(artifactPath, "child");
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);

    await rm(appDirectory, { recursive: true });
    await createSymlink(".inactive-child-link-target", appDirectory);
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/inactive-child-link/child",
                win: "~/AppData/Roaming/inactive-child-link/child",
              },
              repoPath: { default: ".config/inactive-child-link/child" },
              mode: { default: "normal", win: "ignore" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/inactive-child-link" },
              repoPath: { default: ".config/inactive-child-link" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("win");
    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    // The symlink is stored as a separate `.dotweave.symlink` metadata file, so
    // it is simply added alongside the still-owned nested directory artifacts,
    // which are preserved untouched (no directory-root replacement occurs).
    expect(status.push.changes.added).toEqual([".config/inactive-child-link"]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([]);
    expect(dryRunResult.deletedArtifactCount).toBe(0);
    expect(result.deletedArtifactCount).toBe(0);
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);
    await expect(readlink(artifactPath)).rejects.toThrow();
    await expectSymlinkArtifact(artifactPath, ".inactive-child-link-target");
  });

  it("preserves inactive profile-owned nested artifacts during default parent replacements", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const parentDirectory = join(homeDirectory, ".config", "profile-ns");
    const childDirectory = join(parentDirectory, "profiles", "work", "state");
    const childFile = join(childDirectory, "settings.json");
    const linkTarget = join(homeDirectory, ".profile-ns-link-target");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(join(parentDirectory, "default.txt"), "default dir\n");
    await writeFile(childFile, '{"profile":"work"}\n');
    await writeFile(linkTarget, "replacement link target\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const manifestPath = join(syncDirectory, "manifest.jsonc");
    const writeProfileManifest = async (
      defaultEntry: Record<string, unknown>,
    ) => {
      await writeFile(
        manifestPath,
        JSON.stringify(
          {
            version: 8,
            age: { recipients: [ageKeys.recipient] },
            profiles: ["work"],
            entries: [
              defaultEntry,
              {
                kind: "directory",
                localPath: {
                  default: "~/.config/profile-ns/profiles/work/state",
                },
                repoPath: { default: "apps/profile-ns/profiles/work/state" },
                mode: { default: "normal" },
                profiles: ["work"],
              },
              {
                kind: "file",
                localPath: {
                  default:
                    "~/.config/profile-ns/profiles/work/state/settings.json",
                },
                repoPath: {
                  default: "apps/profile-ns/profiles/work/state/settings.json",
                },
                mode: { default: "normal" },
                profiles: ["work"],
              },
            ],
          },
          null,
          2,
        ),
        "utf8",
      );
    };

    await writeProfileManifest({
      kind: "directory",
      localPath: { default: "~/.config/profile-ns" },
      repoPath: { default: "apps/profile-ns" },
      mode: { default: "normal" },
      profiles: ["default"],
    });

    await pushChanges({ dryRun: false });
    await pushChanges({ dryRun: false, profile: "work" });

    const defaultArtifactPath = join(
      syncDirectory,
      "profiles",
      "default",
      "apps",
      "profile-ns",
    );
    const workChildArtifactPath = join(
      syncDirectory,
      "profiles",
      "work",
      "apps",
      "profile-ns",
      "profiles",
      "work",
      "state",
    );
    const workFileArtifactPath = join(workChildArtifactPath, "settings.json");
    expect(await readFile(workFileArtifactPath, "utf8")).toBe(
      '{"profile":"work"}\n',
    );

    await rm(parentDirectory, { recursive: true });
    await writeFile(parentDirectory, "replacement file\n");
    await writeProfileManifest({
      kind: "file",
      localPath: { default: "~/.config/profile-ns" },
      repoPath: { default: "apps/profile-ns" },
      mode: { default: "normal" },
      profiles: ["default"],
    });

    const fileStatus = await getStatus();
    const fileDryRunResult = await pushChanges({ dryRun: true });
    const fileResult = await pushChanges({ dryRun: false });

    expect(fileStatus.push.deletedArtifactCount).toBe(2);
    expect(fileStatus.push.changes.added).toEqual(["apps/profile-ns"]);
    expect(fileStatus.push.changes.modified).toEqual([]);
    expect(fileStatus.push.changes.deleted).toEqual([
      "default/apps/profile-ns/default.txt",
      "default/apps/profile-ns/profiles/work/state/settings.json",
    ]);
    expect(fileDryRunResult.deletedArtifactCount).toBe(2);
    expect(fileResult.deletedArtifactCount).toBe(2);
    expect((await lstat(defaultArtifactPath)).isFile()).toBe(true);
    expect(await readFile(defaultArtifactPath, "utf8")).toBe(
      "replacement file\n",
    );
    expect((await lstat(workChildArtifactPath)).isDirectory()).toBe(true);
    expect(await readFile(workFileArtifactPath, "utf8")).toBe(
      '{"profile":"work"}\n',
    );

    await rm(parentDirectory);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(childFile, '{"profile":"work","updated":true}\n');

    const explicitWorkResult = await pushChanges({
      dryRun: false,
      profile: "work",
    });

    expect(explicitWorkResult.deletedArtifactCount).toBe(0);
    expect(await readFile(workFileArtifactPath, "utf8")).toBe(
      '{"profile":"work","updated":true}\n',
    );

    await rm(parentDirectory, { recursive: true });
    await createSymlink(".profile-ns-link-target", parentDirectory);

    const linkStatus = await getStatus();
    const linkDryRunResult = await pushChanges({ dryRun: true });
    const linkResult = await pushChanges({ dryRun: false });

    // File -> symlink transition: the symlink metadata file is added and the
    // stale plain-file artifact is pruned (the work-owned nested artifacts under
    // the work profile stay untouched).
    expect(linkStatus.push.deletedArtifactCount).toBe(1);
    expect(linkStatus.push.changes.added).toEqual(["apps/profile-ns"]);
    expect(linkStatus.push.changes.modified).toEqual([]);
    expect(linkStatus.push.changes.deleted).toEqual([
      "default/apps/profile-ns",
    ]);
    expect(linkDryRunResult.deletedArtifactCount).toBe(1);
    expect(linkResult.deletedArtifactCount).toBe(1);
    await expectSymlinkArtifact(defaultArtifactPath, ".profile-ns-link-target");
    expect(await readFile(workFileArtifactPath, "utf8")).toBe(
      '{"profile":"work","updated":true}\n',
    );

    await rm(parentDirectory);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(childFile, '{"profile":"work","active":true}\n');
    await setActiveProfile("work");

    const activeWorkResult = await pushChanges({ dryRun: false });

    expect(activeWorkResult.deletedArtifactCount).toBe(0);
    expect(await readFile(workFileArtifactPath, "utf8")).toBe(
      '{"profile":"work","active":true}\n',
    );
  });

  it("reports and prunes stale empty directory roots now configured as missing file sources", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const emptyDirectory = join(homeDirectory, ".config", "missing-file-root");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(emptyDirectory, { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/missing-file-root" },
              repoPath: { default: ".config/missing-file-root" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "missing-file-root",
    );
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);

    await rm(emptyDirectory, { recursive: true });
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.missing-file-root" },
              repoPath: { default: ".config/missing-file-root" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toEqual([
      "default/.config/missing-file-root/",
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("preserves inactive profile artifacts when pushing the default profile", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Work\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".gitconfig",
    );
    expect(await readFile(artifactPath, "utf8")).toBe(
      "[user]\n  name = Work\n",
    );

    const result = await pushChanges({ dryRun: false });

    expect(result.deletedArtifactCount).toBe(0);
    expect(await readFile(artifactPath, "utf8")).toBe(
      "[user]\n  name = Work\n",
    );
  });

  it("preserves still-owned inactive empty directory roots", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const emptyDirectory = join(homeDirectory, ".config", "inactive-empty");
    const workFile = join(homeDirectory, ".work-profile-file");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(emptyDirectory, { recursive: true });
    await writeFile(workFile, "work profile\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/inactive-empty" },
              repoPath: { default: ".config/inactive-empty" },
              mode: { default: "normal" },
              profiles: ["default"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "inactive-empty",
    );
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/inactive-empty" },
              repoPath: { default: ".config/inactive-empty" },
              mode: { default: "normal" },
              profiles: ["default"],
            },
            {
              kind: "file",
              localPath: { default: "~/.work-profile-file" },
              repoPath: { default: ".work-profile-file" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const dryRunResult = await pushChanges({ dryRun: true, profile: "work" });
    const result = await pushChanges({ dryRun: false, profile: "work" });

    expect(dryRunResult.deletedArtifactCount).toBe(0);
    expect(result.deletedArtifactCount).toBe(0);
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
  });

  it("preserves inactive parent-owned empty child directories", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const parentDirectory = join(
      homeDirectory,
      ".config",
      "inactive-parent-empty-child",
    );
    const childDirectory = join(parentDirectory, "child");
    const workFile = join(homeDirectory, ".inactive-parent-work-file");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(workFile, "work profile\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/inactive-parent-empty-child" },
              repoPath: { default: ".config/inactive-parent-empty-child" },
              mode: { default: "normal" },
              profiles: ["default"],
            },
            {
              kind: "directory",
              localPath: {
                default: "~/.config/inactive-parent-empty-child/child",
              },
              repoPath: {
                default: ".config/inactive-parent-empty-child/child",
              },
              mode: { default: "normal" },
              profiles: ["default"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const childArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "inactive-parent-empty-child",
      "child",
    );
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/inactive-parent-empty-child" },
              repoPath: { default: ".config/inactive-parent-empty-child" },
              mode: { default: "normal" },
              profiles: ["default"],
            },
            {
              kind: "file",
              localPath: { default: "~/.inactive-parent-work-file" },
              repoPath: { default: ".inactive-parent-work-file" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus({ profile: "work" });
    const dryRunResult = await pushChanges({ dryRun: true, profile: "work" });
    const result = await pushChanges({ dryRun: false, profile: "work" });

    expect(status.push.deletedArtifactCount).toBe(0);
    expect(dryRunResult.deletedArtifactCount).toBe(0);
    expect(result.deletedArtifactCount).toBe(0);
    expect((await lstat(childArtifactPath)).isDirectory()).toBe(true);
  });

  it("reports and prunes orphaned empty directory artifact roots after entry removal", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const emptyDirectory = join(homeDirectory, ".config", "orphan-empty");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(emptyDirectory, { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/orphan-empty" },
              repoPath: { default: ".config/orphan-empty" },
              mode: { default: "normal" },
              profiles: ["default"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "orphan-empty",
    );
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toEqual([
      "default/.config/orphan-empty/",
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("preserves platform-variant-owned inactive empty directory roots during replacement push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const replacementFile = join(homeDirectory, ".config", "variant-empty");
    const ageKeys = await createAgeKeyPair();
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(join(homeDirectory, ".config"), { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/variant-empty",
                win: "~/AppData/Roaming/variant-empty",
              },
              repoPath: {
                default: ".config/variant-empty",
                win: "AppData/Roaming/variant-empty",
              },
              mode: { default: "normal", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await mkdir(replacementFile, { recursive: true });
    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "variant-empty",
    );
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);

    await rm(replacementFile, { recursive: true });
    await writeFile(replacementFile, "replacement\n");
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/variant-empty",
                win: "~/AppData/Roaming/variant-empty",
              },
              repoPath: {
                default: ".config/variant-empty",
                win: "AppData/Roaming/variant-empty",
              },
              mode: { default: "normal", win: "ignore" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/variant-empty" },
              repoPath: { default: ".config/variant-empty" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("win");
    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.preview).not.toContain(".config/variant-empty");
    expect(status.push.changes.added).toEqual([]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([]);
    expect(dryRunResult.deletedArtifactCount).toBe(0);
    expect(result.deletedArtifactCount).toBe(0);
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
    await expect(readFile(artifactPath, "utf8")).rejects.toThrow();
  });

  it("preserves platform-variant-owned inactive empty directory roots from symlink replacement artifacts", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const replacementPath = join(homeDirectory, ".config", "variant-link");
    const linkTarget = join(homeDirectory, "target.txt");
    const ageKeys = await createAgeKeyPair();
    const platformSpy = vi.spyOn(platformConfig, "detectCurrentPlatformKey");
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(join(homeDirectory, ".config"), { recursive: true });
    await writeFile(linkTarget, "target\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/variant-link",
                win: "~/AppData/Roaming/variant-link",
              },
              repoPath: {
                default: ".config/variant-link",
                win: "AppData/Roaming/variant-link",
              },
              mode: { default: "normal", win: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("linux");
    await mkdir(replacementPath, { recursive: true });
    await writeFile(join(replacementPath, "owned.txt"), "owned\n");
    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "variant-link",
    );
    const ownedArtifactPath = join(artifactPath, "owned.txt");
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
    await expect(readFile(ownedArtifactPath, "utf8")).resolves.toBe("owned\n");

    await rm(replacementPath, { recursive: true });
    await createSymlink(linkTarget, replacementPath);
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: {
                default: "~/.config/variant-link",
                win: "~/AppData/Roaming/variant-link",
              },
              repoPath: {
                default: ".config/variant-link",
                win: "AppData/Roaming/variant-link",
              },
              mode: { default: "normal", win: "ignore" },
            },
            {
              kind: "file",
              localPath: { default: "~/.config/variant-link" },
              repoPath: { default: ".config/variant-link" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    platformSpy.mockReturnValue("win");
    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    // The symlink is added as a separate `.dotweave.symlink` metadata file; the
    // platform-variant-owned inactive directory root is preserved untouched.
    expect(status.push.changes.added).toEqual([".config/variant-link"]);
    expect(status.push.changes.modified).toEqual([]);
    expect(status.push.changes.deleted).toEqual([]);
    expect(dryRunResult.deletedArtifactCount).toBe(0);
    expect(result.deletedArtifactCount).toBe(0);
    expect((await lstat(artifactPath)).isDirectory()).toBe(true);
    await expect(readFile(ownedArtifactPath, "utf8")).resolves.toBe("owned\n");
    await expect(readlink(artifactPath)).rejects.toThrow();
    await expectSymlinkArtifact(artifactPath, linkTarget);
  });

  it("prunes registered profile artifacts when no entries own them", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".gitconfig",
    );
    await mkdir(join(artifactPath, ".."), { recursive: true });
    await writeFile(artifactPath, "[user]\n  name = Stale\n");

    const result = await pushChanges({ dryRun: false, profile: "work" });

    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(artifactPath)).rejects.toThrow();
  });

  it("status and push prune artifacts from profile namespaces removed from the manifest", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const emptyDirectory = join(
      homeDirectory,
      ".config",
      "removed-profile-empty",
    );
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(emptyDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Removed\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
            {
              kind: "directory",
              localPath: { default: "~/.config/removed-profile-empty" },
              repoPath: { default: ".config/removed-profile-empty" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    const fileArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".gitconfig",
    );
    const emptyDirectoryArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".config",
      "removed-profile-empty",
    );
    expect(await readFile(fileArtifactPath, "utf8")).toBe(
      "[user]\n  name = Removed\n",
    );
    expect((await lstat(emptyDirectoryArtifactPath)).isDirectory()).toBe(true);

    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");

    await runGit(["add", "."], syncDirectory);
    await runGit(
      ["commit", "-m", "store work profile artifacts"],
      syncDirectory,
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: [],
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toEqual([
      "work/.config/removed-profile-empty/",
      "work/.gitconfig",
    ]);
    expect(status.push.deletedArtifactCount).toBe(2);
    expect(status.push.preview).toEqual([
      "work/.config/removed-profile-empty/",
      "work/.gitconfig",
    ]);
    expect(dryRunResult.deletedArtifactCount).toBe(2);
    expect(result.deletedArtifactCount).toBe(2);
    await expect(lstat(fileArtifactPath)).rejects.toThrow();
    await expect(lstat(emptyDirectoryArtifactPath)).rejects.toThrow();
  });

  it("ignores repository support directories when pruning removed profile namespaces", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Removed\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");

    await runGit(["add", "."], syncDirectory);
    await runGit(
      ["commit", "-m", "store work profile artifacts"],
      syncDirectory,
    );

    const workflowPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      ".github",
      "workflows",
      "ci.yml",
    );
    await mkdir(join(workflowPath, ".."), { recursive: true });
    await writeFile(workflowPath, "name: CI\n");

    const docsPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "docs",
      "index.md",
    );
    const scriptPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "scripts",
      "bootstrap.sh",
    );
    const removedProfileArtifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "work",
      ".gitconfig",
    );

    await mkdir(join(docsPath, ".."), { recursive: true });
    await mkdir(join(scriptPath, ".."), { recursive: true });
    await writeFile(docsPath, "# Docs\n");
    await writeFile(scriptPath, "#!/usr/bin/env sh\n");

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: [],
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toEqual(["work/.gitconfig"]);
    expect(status.push.changes.deleted).not.toContain("docs/index.md");
    expect(status.push.changes.deleted).not.toContain("scripts/bootstrap.sh");
    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.preview).toEqual(["work/.gitconfig"]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expect(readFile(workflowPath, "utf8")).resolves.toBe("name: CI\n");
    await expect(readFile(docsPath, "utf8")).resolves.toBe("# Docs\n");
    await expect(readFile(scriptPath, "utf8")).resolves.toBe(
      "#!/usr/bin/env sh\n",
    );
    await expect(lstat(removedProfileArtifactPath)).rejects.toThrow();
  });

  it("ignores invalid committed profile namespaces when pruning removed profile artifacts", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\n  name = Removed\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const manifestPath = join(syncDirectory, "manifest.jsonc");

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false, profile: "work" });

    const removedProfileArtifactPath = join(
      syncDirectory,
      "profiles",
      "work",
      ".gitconfig",
    );
    const outsideDocsPath = join(syncDirectory, "..", "docs", "index.md");
    const workflowPath = join(syncDirectory, ".github", "workflows", "ci.yml");

    await mkdir(join(outsideDocsPath, ".."), { recursive: true });
    await mkdir(join(workflowPath, ".."), { recursive: true });
    await writeFile(outsideDocsPath, "# Outside docs\n");
    await writeFile(workflowPath, "name: CI\n");
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: ["work", "..", "../docs", ".github"],
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.gitconfig" },
              mode: { default: "normal" },
              profiles: ["work"],
            },
            {
              kind: "file",
              localPath: { default: "~/.ignored" },
              mode: { default: "normal" },
              profiles: ["../docs"],
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await runGit(["add", "."], syncDirectory);
    await runGit(
      ["commit", "-m", "store invalid committed profiles"],
      syncDirectory,
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          profiles: [],
          entries: [],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toEqual(["work/.gitconfig"]);
    expect(status.push.deletedArtifactCount).toBe(1);
    expect(status.push.preview).toEqual(["work/.gitconfig"]);
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expect(lstat(removedProfileArtifactPath)).rejects.toThrow();
    await expect(readFile(outsideDocsPath, "utf8")).resolves.toBe(
      "# Outside docs\n",
    );
    await expect(readFile(workflowPath, "utf8")).resolves.toBe("name: CI\n");
  });

  it("replaces a stale child directory with a file while the parent directory remains configured", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const parentDirectory = join(homeDirectory, ".config", "overlap-file");
    const childDirectory = join(parentDirectory, "child");
    const replacementFile = join(homeDirectory, ".overlap-file-child");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(join(childDirectory, "settings.json"), '{"stale":true}\n');
    await writeFile(replacementFile, "replacement file\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-file" },
              repoPath: { default: "apps/overlap-file" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-file/child" },
              repoPath: { default: "apps/overlap-file/child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "apps",
      "overlap-file",
      "child",
    );
    expect(await readFile(join(artifactPath, "settings.json"), "utf8")).toBe(
      '{"stale":true}\n',
    );

    await rm(childDirectory, { recursive: true });
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-file" },
              repoPath: { default: "apps/overlap-file" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.overlap-file-child" },
              repoPath: { default: "apps/overlap-file/child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toContain(
      "default/apps/overlap-file/child/settings.json",
    );
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    expect((await lstat(artifactPath)).isFile()).toBe(true);
    expect(await readFile(artifactPath, "utf8")).toBe("replacement file\n");
  });

  it("replaces a stale child directory with a symlink while the parent directory remains configured", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const parentDirectory = join(homeDirectory, ".config", "overlap-link");
    const childDirectory = join(parentDirectory, "child");
    const linkTarget = join(homeDirectory, ".overlap-link-target");
    const replacementLink = join(homeDirectory, ".overlap-link-child");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(childDirectory, { recursive: true });
    await writeFile(join(childDirectory, "settings.json"), '{"stale":true}\n');
    await writeFile(linkTarget, "replacement link target\n");
    await createSymlink(".overlap-link-target", replacementLink);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );

    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-link" },
              repoPath: { default: "apps/overlap-link" },
              mode: { default: "normal" },
            },
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-link/child" },
              repoPath: { default: "apps/overlap-link/child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "apps",
      "overlap-link",
      "child",
    );
    expect(await readFile(join(artifactPath, "settings.json"), "utf8")).toBe(
      '{"stale":true}\n',
    );

    await rm(childDirectory, { recursive: true });
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 8,
          age: { recipients: [ageKeys.recipient] },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.config/overlap-link" },
              repoPath: { default: "apps/overlap-link" },
              mode: { default: "normal" },
            },
            {
              kind: "file",
              localPath: { default: "~/.overlap-link-child" },
              repoPath: { default: "apps/overlap-link/child" },
              mode: { default: "normal" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    const status = await getStatus();
    const dryRunResult = await pushChanges({ dryRun: true });
    const result = await pushChanges({ dryRun: false });

    expect(status.push.changes.deleted).toContain(
      "default/apps/overlap-link/child/settings.json",
    );
    expect(dryRunResult.deletedArtifactCount).toBe(1);
    expect(result.deletedArtifactCount).toBe(1);
    await expectSymlinkArtifact(artifactPath, ".overlap-link-target");
  });

  it("restores file permission from entry permission on pull", async () => {
    if (process.platform === "win32") {
      return;
    }

    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sshDirectory = join(homeDirectory, ".ssh");
    const keyFile = join(sshDirectory, "id_rsa");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(sshDirectory, { recursive: true });
    await writeFile(keyFile, "fake-private-key\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.ssh/id_rsa" },
              mode: { default: "secret" },
              permission: { default: "0600" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });
    await writeFile(keyFile, "modified-content\n");
    await pullChanges({ dryRun: false });

    expect(await readFile(keyFile, "utf8")).toBe("fake-private-key\n");
    const stats = await lstat(keyFile);
    expect(stats.mode & 0o777).toBe(0o600);
  });

  it("restores directory entry permission to child files and a searchable directory on pull", async () => {
    if (process.platform === "win32") {
      return;
    }

    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sshDirectory = join(homeDirectory, ".ssh");
    const keyFile = join(sshDirectory, "id_rsa");
    const configFile = join(sshDirectory, "config");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(sshDirectory, { recursive: true });
    await writeFile(keyFile, "fake-private-key\n");
    await writeFile(configFile, "Host *\n  AddKeysToAgent yes\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.ssh" },
              mode: { default: "normal" },
              permission: { default: "0600" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });
    await rm(sshDirectory, { force: true, recursive: true });
    await pullChanges({ dryRun: false });

    expect(await readFile(keyFile, "utf8")).toBe("fake-private-key\n");
    expect(await readFile(configFile, "utf8")).toBe(
      "Host *\n  AddKeysToAgent yes\n",
    );

    const directoryStats = await lstat(sshDirectory);
    expect(directoryStats.mode & 0o777).toBe(0o700);

    const keyStats = await lstat(keyFile);
    expect(keyStats.mode & 0o777).toBe(0o600);

    const configStats = await lstat(configFile);
    expect(configStats.mode & 0o777).toBe(0o600);
  });

  it("preserves ignored local files inside permissioned directories on pull", async () => {
    if (process.platform === "win32") {
      return;
    }

    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sshDirectory = join(homeDirectory, ".ssh");
    const keyFile = join(sshDirectory, "id_rsa");
    const ignoredFile = join(sshDirectory, "known_hosts.local");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(sshDirectory, { recursive: true });
    await writeFile(keyFile, "fake-private-key\n");
    await writeFile(ignoredFile, "initial-local-state\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "directory",
              localPath: { default: "~/.ssh" },
              mode: { default: "normal" },
              permission: { default: "0600" },
            },
            {
              kind: "file",
              localPath: { default: "~/.ssh/known_hosts.local" },
              mode: { default: "ignore" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });
    await writeFile(keyFile, "modified-content\n");
    await writeFile(ignoredFile, "preserved-local-state\n");
    await pullChanges({ dryRun: false });

    expect(await readFile(keyFile, "utf8")).toBe("fake-private-key\n");
    expect(await readFile(ignoredFile, "utf8")).toBe("preserved-local-state\n");

    const directoryStats = await lstat(sshDirectory);
    expect(directoryStats.mode & 0o777).toBe(0o700);

    const keyStats = await lstat(keyFile);
    expect(keyStats.mode & 0o777).toBe(0o600);
  });

  it("pull updates only changed files without replacing the tracked directory", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "myapp");
    const configFile = join(appDirectory, "config.json");
    const settingsFile = join(appDirectory, "settings.json");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(configFile, '{"version":1}\n', "utf8");
    await writeFile(settingsFile, '{"theme":"dark"}\n', "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget(
      {
        mode: "normal",
        target: appDirectory,
      },
      homeDirectory,
    );

    await pushChanges({ dryRun: false });

    const localDirectoryBefore = await lstat(appDirectory);
    const localConfigBefore = await lstat(configFile);
    const repoSettingsFile = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "myapp",
      "settings.json",
    );

    await writeFile(repoSettingsFile, '{"theme":"light"}\n', "utf8");
    await pullChanges({ dryRun: false });

    const localDirectoryAfter = await lstat(appDirectory);
    const localConfigAfter = await lstat(configFile);

    expect(localDirectoryAfter.ino).toBe(localDirectoryBefore.ino);
    expect(localConfigAfter.ino).toBe(localConfigBefore.ino);
    expect(await readFile(configFile, "utf8")).toBe('{"version":1}\n');
    expect(await readFile(settingsFile, "utf8")).toBe('{"theme":"light"}\n');
  });

  it("pull reconciles nested directories without recreating unchanged ancestors", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "myapp");
    const themesDirectory = join(appDirectory, "themes");
    const nestedThemeFile = join(themesDirectory, "dark.json");
    const siblingFile = join(appDirectory, "settings.json");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(themesDirectory, { recursive: true });
    await writeFile(nestedThemeFile, '{"accent":"blue"}\n', "utf8");
    await writeFile(siblingFile, '{"font":"mono"}\n', "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: appDirectory }, homeDirectory);

    await pushChanges({ dryRun: false });

    const appDirectoryBefore = await lstat(appDirectory);
    const themesDirectoryBefore = await lstat(themesDirectory);
    const siblingFileBefore = await lstat(siblingFile);
    const repoNestedThemeFile = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "myapp",
      "themes",
      "dark.json",
    );

    await writeFile(repoNestedThemeFile, '{"accent":"amber"}\n', "utf8");
    await pullChanges({ dryRun: false });

    const appDirectoryAfter = await lstat(appDirectory);
    const themesDirectoryAfter = await lstat(themesDirectory);
    const siblingFileAfter = await lstat(siblingFile);

    expect(appDirectoryAfter.ino).toBe(appDirectoryBefore.ino);
    expect(themesDirectoryAfter.ino).toBe(themesDirectoryBefore.ino);
    expect(siblingFileAfter.ino).toBe(siblingFileBefore.ino);
    expect(await readFile(nestedThemeFile, "utf8")).toBe(
      '{"accent":"amber"}\n',
    );
    expect(await readFile(siblingFile, "utf8")).toBe('{"font":"mono"}\n');
  });

  it("uses default executable mode when permission is not set", async () => {
    if (process.platform === "win32") {
      return;
    }

    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget({ mode: "normal", target: gitconfig }, homeDirectory);

    await pushChanges({ dryRun: false });
    await rm(gitconfig);
    await pullChanges({ dryRun: false });

    const stats = await lstat(gitconfig);
    expect(stats.mode & 0o777).toBe(0o644);
  });

  it("preserves permission field in config through round-trip", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const keyFile = join(homeDirectory, ".ssh", "id_rsa");
    const ageKeys = await createAgeKeyPair();
    setEnvironment(homeDirectory, xdgConfigHome);

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(join(homeDirectory, ".ssh"), { recursive: true });
    await writeFile(keyFile, "key-content\n");

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    const manifestPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "manifest.jsonc",
    );
    await writeFile(
      manifestPath,
      JSON.stringify(
        {
          version: 7,
          age: {
            recipients: [ageKeys.recipient],
          },
          entries: [
            {
              kind: "file",
              localPath: { default: "~/.ssh/id_rsa" },
              mode: { default: "secret" },
              permission: { default: "0600" },
            },
          ],
        },
        null,
        2,
      ),
      "utf8",
    );

    await pushChanges({ dryRun: false });

    const permissionEntries = parseManifestEntries(
      await readFile(manifestPath, "utf8"),
    );

    expect(permissionEntries[0]?.permission).toEqual({ default: "0600" });
  });

  it("assigns and unassigns profiles to entries", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n");

    setEnvironment(homeDirectory, xdgConfigHome);
    const cwd = homeDirectory;

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: gitconfig }, cwd);
    await addProfile("work");

    const assignResult = await assignProfiles(
      {
        target: gitconfig,
        profiles: ["default", "work"],
      },
      cwd,
    );

    expect(assignResult.action).toBe("assigned");
    expect(assignResult.profiles).toEqual(["default", "work"]);

    const profileEntries = parseManifestEntries(
      await readFile(
        join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
        "utf8",
      ),
    );

    expect(profileEntries[0]?.profiles).toEqual(["default", "work"]);

    const listResult = await listProfiles();

    expect(listResult.availableProfiles).toEqual(["default", "work"]);
    expect(listResult.assignments).toEqual([
      {
        entryLocalPath: gitconfig,
        entryRepoPath: ".gitconfig",
        profiles: ["default", "work"],
      },
    ]);

    const reassignResult = await assignProfiles(
      { target: gitconfig, profiles: ["default"] },
      cwd,
    );

    expect(reassignResult.action).toBe("assigned");
    expect(reassignResult.profiles).toEqual(["default"]);

    const clearResult = await assignProfiles(
      { target: gitconfig, profiles: [] },
      cwd,
    );

    expect(clearResult.action).toBe("assigned");
    expect(clearResult.profiles).toEqual([]);

    const profileEntriesAfter = parseManifestEntries(
      await readFile(
        join(xdgConfigHome, "dotweave", "repository", "manifest.jsonc"),
        "utf8",
      ),
    );

    expect(profileEntriesAfter[0]?.profiles).toBeUndefined();
  });

  it("deletes local files that were removed from repository during pull", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "myapp");
    const fileA = join(appDirectory, "config.json");
    const fileB = join(appDirectory, "settings.json");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(fileA, '{"key": "value"}\n', "utf8");
    await writeFile(fileB, '{"setting": "value"}\n', "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        target: appDirectory,
      },
      homeDirectory,
    );

    await pushChanges({ dryRun: false });

    const repoPathA = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "myapp",
      "config.json",
    );
    const repoPathB = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "myapp",
      "settings.json",
    );

    expect(await readFile(repoPathA, "utf8")).toContain('"key": "value"');
    expect(await readFile(repoPathB, "utf8")).toContain('"setting": "value"');

    await rm(repoPathB);

    await pullChanges({ dryRun: false });

    expect(await readFile(fileA, "utf8")).toContain('"key": "value"');
    await expect(readFile(fileB, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("deletes local files when entire tracked directory is removed from repository", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sshDirectory = join(homeDirectory, ".ssh");
    const keyFile = join(sshDirectory, "id_rsa");
    const configFile = join(sshDirectory, "config");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(sshDirectory, { recursive: true });
    await writeFile(keyFile, "fake-private-key\n", "utf8");
    await writeFile(configFile, "Host *\n  AddKeysToAgent yes\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        target: sshDirectory,
      },
      homeDirectory,
    );

    await pushChanges({ dryRun: false });

    const repoSshDir = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".ssh",
    );

    expect(await readFile(join(repoSshDir, "id_rsa"), "utf8")).toContain(
      "fake-private-key",
    );

    await rm(repoSshDir, { force: true, recursive: true });

    const result = await pullChanges({ dryRun: false });

    expect(result.deletedLocalCount).toBeGreaterThanOrEqual(1);
    await expect(readFile(keyFile, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(readFile(configFile, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("prunes stale empty managed directories during pull", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "bundle");
    const cacheDirectory = join(appDirectory, "cache");
    const cacheFile = join(cacheDirectory, "old.txt");
    const keepFile = join(appDirectory, "keep.txt");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(cacheDirectory, { recursive: true });
    await writeFile(cacheFile, "old\n", "utf8");
    await writeFile(keepFile, "keep\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: appDirectory }, homeDirectory);

    await pushChanges({ dryRun: false });

    const repoCacheFile = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "bundle",
      "cache",
      "old.txt",
    );
    const repoCacheDirectory = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "bundle",
      "cache",
    );
    await rm(repoCacheFile);
    await rm(repoCacheDirectory, { force: true, recursive: true });

    await pullChanges({ dryRun: false });

    await expect(readFile(cacheFile, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(lstat(cacheDirectory)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(await readFile(keepFile, "utf8")).toBe("keep\n");
  });

  it("pull replaces a tracked file with a directory when the repository type changes", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "app");
    const currentPath = join(appDirectory, "current");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(currentPath, "v1\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: appDirectory }, homeDirectory);

    await pushChanges({ dryRun: false });

    const repoCurrentPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "current",
    );

    await rm(repoCurrentPath);
    await mkdir(repoCurrentPath, { recursive: true });
    await writeFile(join(repoCurrentPath, "index.txt"), "v2\n", "utf8");

    await pullChanges({ dryRun: false });

    const currentStats = await lstat(currentPath);
    expect(currentStats.isDirectory()).toBe(true);
    expect(await readFile(join(currentPath, "index.txt"), "utf8")).toBe("v2\n");
  });

  it("pull replaces a tracked symlink with a file when the repository type changes", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const appDirectory = join(homeDirectory, ".config", "app");
    const targetFile = join(appDirectory, "target.txt");
    const currentPath = join(appDirectory, "current");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(appDirectory, { recursive: true });
    await writeFile(targetFile, "target\n", "utf8");
    await createSymlink("./target.txt", currentPath);

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: appDirectory }, homeDirectory);

    await pushChanges({ dryRun: false });

    const repoCurrentPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "app",
      "current",
    );

    // Simulate the repository changing the entry from a symlink to a regular
    // file: drop the `.dotweave.symlink` metadata file and add a plain file.
    await rm(symlinkArtifactPath(repoCurrentPath));
    await writeFile(repoCurrentPath, "plain\n", "utf8");

    await pullChanges({ dryRun: false });

    const currentStats = await lstat(currentPath);
    expect(currentStats.isFile()).toBe(true);
    expect(await readFile(currentPath, "utf8")).toBe("plain\n");
  });

  it("reports deleted local count in pull result", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const bundleDirectory = join(homeDirectory, ".config", "bundle");
    const file1 = join(bundleDirectory, "file1.txt");
    const file2 = join(bundleDirectory, "file2.txt");
    const file3 = join(bundleDirectory, "file3.txt");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(bundleDirectory, { recursive: true });
    await writeFile(file1, "content1\n", "utf8");
    await writeFile(file2, "content2\n", "utf8");
    await writeFile(file3, "content3\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });

    await trackTarget(
      {
        mode: "normal",
        target: bundleDirectory,
      },
      homeDirectory,
    );

    await pushChanges({ dryRun: false });

    const repoFile2 = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "bundle",
      "file2.txt",
    );
    const repoFile3 = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".config",
      "bundle",
      "file3.txt",
    );

    await rm(repoFile2);
    await rm(repoFile3);

    const result = await pullChanges({ dryRun: false });

    expect(result.deletedLocalCount).toBe(2);
    expect(await readFile(file1, "utf8")).toBe("content1\n");
    await expect(readFile(file2, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(readFile(file3, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("skips rewriting unchanged plain artifacts on push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const gitconfig = join(homeDirectory, ".gitconfig");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(gitconfig, "[user]\nname=test\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: gitconfig }, homeDirectory);

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".gitconfig",
    );
    const beforeStats = await lstat(artifactPath);

    await new Promise((resolve) => {
      setTimeout(resolve, 20);
    });
    await pushChanges({ dryRun: false });

    const afterStats = await lstat(artifactPath);

    expect(afterStats.mtimeMs).toBe(beforeStats.mtimeMs);
    expect(await readFile(artifactPath, "utf8")).toBe("[user]\nname=test\n");
  });

  it("skips recreating unchanged symlink artifacts on push", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const zshenv = join(homeDirectory, ".zshenv");
    const zshrc = join(homeDirectory, ".zshrc");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(zshrc, "export PATH=~/.local/bin:$PATH\n", "utf8");
    await createSymlink(".zshrc", zshenv);

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: zshenv }, homeDirectory);

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      ".zshenv",
    );
    const metaPath = symlinkArtifactPath(artifactPath);
    const beforeStats = await lstat(metaPath);

    await new Promise((resolve) => {
      setTimeout(resolve, 20);
    });
    await pushChanges({ dryRun: false });

    const afterStats = await lstat(metaPath);

    expect(afterStats.ino).toBe(beforeStats.ino);
    await expectSymlinkArtifact(artifactPath, ".zshrc");
  });

  it("updates repository artifacts when only the executable bit changes", async () => {
    if (process.platform === "win32") {
      return;
    }

    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const scriptPath = join(homeDirectory, "bin", "hello.sh");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(join(homeDirectory, "bin"), { recursive: true });
    await writeFile(scriptPath, "#!/bin/sh\necho hello\n", "utf8");
    await chmod(scriptPath, 0o644);

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
      recipients: [ageKeys.recipient],
    });
    await trackTarget({ mode: "normal", target: scriptPath }, homeDirectory);

    await pushChanges({ dryRun: false });

    const artifactPath = join(
      xdgConfigHome,
      "dotweave",
      "repository",
      "profiles",
      "default",
      "bin",
      "hello.sh",
    );

    expect((await lstat(artifactPath)).mode & 0o777).toBe(0o644);

    await chmod(scriptPath, 0o755);
    await pushChanges({ dryRun: false });

    expect((await lstat(artifactPath)).mode & 0o777).toBe(0o755);
    expect(await readFile(artifactPath, "utf8")).toBe(
      "#!/bin/sh\necho hello\n",
    );
  });
});
