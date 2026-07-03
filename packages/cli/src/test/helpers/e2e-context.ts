import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { execa } from "execa";

import { cliNodeOptions } from "./cli-entry.ts";
import {
  createAgeKeyPair,
  gitTestEnvironment,
  writeIdentityFile,
} from "./sync-fixture.ts";

export interface RunCliOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  input?: string;
  reject?: boolean;
}

export const createMachineEnv = (
  workspace: string,
  name: string,
  baseEnv: NodeJS.ProcessEnv,
) => {
  const homeDir = join(workspace, `home-${name}`);
  const xdgDir = join(workspace, `xdg-${name}`);
  const localAppDataDir = join(workspace, `local-appdata-${name}`);

  return {
    env: {
      ...baseEnv,
      APPDATA: xdgDir,
      HOME: homeDir,
      LOCALAPPDATA: localAppDataDir,
      USERPROFILE: homeDir,
      XDG_CONFIG_HOME: xdgDir,
    },
    homeDir,
    localAppDataDir,
    xdgDir,
  };
};

export const readRepositoryArtifact = (
  xdgDir: string,
  profile: string,
  repoPath: string,
) => {
  return readFile(
    join(
      xdgDir,
      "dotweave",
      "repository",
      "profiles",
      profile,
      ...repoPath.split("/"),
    ),
    "utf8",
  );
};

export const createSyncE2EContext = async () => {
  const workspace = await mkdtemp(join(tmpdir(), "dotweave-e2e-"));
  const homeDir = join(workspace, "home");
  const xdgDir = join(workspace, "xdg");
  const localAppDataDir = join(workspace, "local-appdata");

  await mkdir(homeDir, { recursive: true });

  const baseEnv: NodeJS.ProcessEnv = {
    APPDATA: xdgDir,
    FORCE_COLOR: "0",
    HOME: homeDir,
    LOCALAPPDATA: localAppDataDir,
    NODE_NO_WARNINGS: "1",
    NO_COLOR: "1",
    USERPROFILE: homeDir,
    XDG_CONFIG_HOME: xdgDir,
    ...gitTestEnvironment,
  };

  const runCli = async (args: readonly string[], opts?: RunCliOptions) => {
    return execa(process.execPath, [...cliNodeOptions, ...args], {
      cwd: opts?.cwd,
      env: opts?.env !== undefined ? { ...baseEnv, ...opts.env } : baseEnv,
      input: opts?.input,
      reject: opts?.reject ?? true,
    });
  };

  const runGit = async (args: readonly string[], cwd?: string) => {
    return execa("git", [...args], {
      cwd,
      env: { ...gitTestEnvironment },
    });
  };

  const contextWriteIdentityFile = (identity: string) => {
    return writeIdentityFile(xdgDir, identity);
  };

  const cleanup = async () => {
    await rm(workspace, { force: true, recursive: true });
  };

  return {
    workspace,
    homeDir,
    xdgDir,
    localAppDataDir,
    baseEnv,
    runCli,
    runGit,
    createAgeKeyPair,
    writeIdentityFile: contextWriteIdentityFile,
    cleanup,
  };
};

export type SyncE2EContext = Awaited<ReturnType<typeof createSyncE2EContext>>;
