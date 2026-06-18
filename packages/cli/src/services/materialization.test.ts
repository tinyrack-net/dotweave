import { chmod, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type {
  ResolvedSyncConfigEntry,
  SyncConfigEntryKind,
  SyncMode,
} from "#app/config/sync-schema.ts";
import { formatPermissionOctal } from "#app/lib/file-mode.ts";
import { createSymlink } from "#app/lib/filesystem.ts";
import { buildDirectoryKey } from "#app/lib/path.ts";
import type { FileLikeSnapshotNode } from "#app/services/local-snapshot.ts";
import {
  buildEntryMaterialization,
  collectChangedLocalPaths,
  countDeletedLocalNodes,
} from "#app/services/pull-apply.ts";
import type { EffectiveSyncConfig } from "#app/services/sync-context.ts";
import { createTemporaryDirectory } from "../test/helpers/sync-fixture.ts";

const temporaryDirectories: string[] = [];

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory(
    "dotweave-local-materialization-",
  );

  temporaryDirectories.push(directory);

  return directory;
};

const createEntry = (
  kind: SyncConfigEntryKind,
  localPath: string,
  repoPath: string,
  mode: SyncMode,
  permission?: number,
): ResolvedSyncConfigEntry => {
  return {
    configuredLocalPath: { default: localPath },
    configuredMode: { default: mode },
    ...(permission === undefined
      ? {}
      : {
          configuredPermission: { default: formatPermissionOctal(permission) },
        }),
    kind,
    localPath,
    mode,
    modeExplicit: true,
    ...(permission === undefined ? {} : { permission }),
    permissionExplicit: permission !== undefined,
    profiles: [],
    profilesExplicit: false,
    repoPath,
  };
};

const createConfig = (
  entries: readonly ResolvedSyncConfigEntry[],
): EffectiveSyncConfig => {
  return {
    age: {
      identityFile: "/tmp/keys.txt",
      recipients: [],
    },
    entries,
    version: 7,
  };
};

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

describe("local materialization", () => {
  it("does not scan ignored child directory descendants while planning pull", async () => {
    const workspace = await createWorkspace();
    const opencodeDirectory = join(workspace, ".config", "opencode");
    const nodeModulesDirectory = join(opencodeDirectory, "node_modules");
    const nestedDirectory = join(nodeModulesDirectory, "pkg-a", "dist");
    const trackedFile = join(opencodeDirectory, "settings.json");
    const ignoredFile = join(nestedDirectory, "index.js");

    await mkdir(nestedDirectory, { recursive: true });
    await writeFile(trackedFile, "{\n}\n", "utf8");
    await writeFile(ignoredFile, "module.exports = {}\n", "utf8");

    const rootEntry = createEntry(
      "directory",
      opencodeDirectory,
      ".config/opencode",
      "normal",
    );
    const config = createConfig([
      rootEntry,
      createEntry(
        "directory",
        nodeModulesDirectory,
        ".config/opencode/node_modules",
        "ignore",
      ),
    ]);
    const existingKeys = new Set<string>();

    const deletedLocalCount = await countDeletedLocalNodes(
      rootEntry,
      new Set([
        buildDirectoryKey(".config/opencode"),
        ".config/opencode/settings.json",
      ]),
      config,
      existingKeys,
    );

    expect(deletedLocalCount).toBe(0);
    expect(existingKeys).toEqual(
      new Set([
        buildDirectoryKey(".config/opencode"),
        ".config/opencode/settings.json",
      ]),
    );
  });

  it("skips ignored directory entries entirely while planning pull", async () => {
    const workspace = await createWorkspace();
    const opencodeDirectory = join(workspace, ".config", "opencode");
    const nodeModulesDirectory = join(opencodeDirectory, "node_modules");
    const nestedDirectory = join(nodeModulesDirectory, "pkg-a", "dist");
    const ignoredFile = join(nestedDirectory, "index.js");

    await mkdir(nestedDirectory, { recursive: true });
    await writeFile(ignoredFile, "module.exports = {}\n", "utf8");

    const ignoredEntry = createEntry(
      "directory",
      nodeModulesDirectory,
      ".config/opencode/node_modules",
      "ignore",
    );
    const existingKeys = new Set<string>();

    const deletedLocalCount = await countDeletedLocalNodes(
      ignoredEntry,
      new Set<string>(),
      createConfig([
        createEntry(
          "directory",
          opencodeDirectory,
          ".config/opencode",
          "normal",
        ),
        ignoredEntry,
      ]),
      existingKeys,
    );

    expect(deletedLocalCount).toBe(0);
    expect(existingKeys.size).toBe(0);
  });

  it("records deleted local paths while planning pull", async () => {
    const workspace = await createWorkspace();
    const appDirectory = join(workspace, ".config", "app");
    const configFile = join(appDirectory, "config.json");
    const cacheFile = join(appDirectory, "cache.json");

    await mkdir(appDirectory, { recursive: true });
    await writeFile(configFile, "{}\n", "utf8");
    await writeFile(cacheFile, "{}\n", "utf8");

    const existingKeys = new Set<string>();
    const keyToLocalPath = new Map<string, string>();
    const entry = createEntry(
      "directory",
      appDirectory,
      ".config/app",
      "normal",
    );

    const deletedLocalCount = await countDeletedLocalNodes(
      entry,
      new Set([buildDirectoryKey(".config/app"), ".config/app/config.json"]),
      createConfig([entry]),
      existingKeys,
      keyToLocalPath,
    );

    expect(deletedLocalCount).toBe(1);
    expect(keyToLocalPath.get(".config/app/cache.json")).toBe(cacheFile);
  });

  it("collects only changed local paths for a materialized directory", async () => {
    const workspace = await createWorkspace();
    const appDirectory = join(workspace, ".config", "app");
    const configFile = join(appDirectory, "config.json");
    const linkPath = join(appDirectory, "current");

    await mkdir(appDirectory, { recursive: true });
    await writeFile(configFile, '{"version":1}\n', "utf8");
    await writeFile(join(appDirectory, "v1"), "", "utf8");
    await createSymlink("./v1", linkPath, "file");

    const entry = createEntry(
      "directory",
      appDirectory,
      ".config/app",
      "normal",
    );

    await writeFile(join(appDirectory, "stale.txt"), "old\n", "utf8");

    expect(
      await collectChangedLocalPaths(entry, {
        desiredKeys: new Set([
          buildDirectoryKey(".config/app"),
          ".config/app/config.json",
          ".config/app/current",
          ".config/app/missing.txt",
        ]),
        nodes: new Map([
          [
            "config.json",
            {
              contents: Buffer.from('{"version":1}\n'),
              executable: false,
              secret: false,
              type: "file",
            },
          ],
          [
            "current",
            {
              linkTarget: "./v1",
              type: "symlink",
            },
          ],
          [
            "missing.txt",
            {
              contents: Buffer.from("new\n"),
              executable: false,
              secret: false,
              type: "file",
            },
          ],
        ]),
        type: "directory",
      }),
    ).toEqual([join(appDirectory, "missing.txt")]);
  });

  it.skipIf(process.platform === "win32")(
    "ignores non-executable file permission drift without explicit permission",
    async () => {
      const workspace = await createWorkspace();
      const configFile = join(workspace, ".config", "app", "config.json");

      await mkdir(join(workspace, ".config", "app"), { recursive: true });
      await writeFile(configFile, '{"version":1}\n', "utf8");
      await chmod(configFile, 0o600);

      const entry = createEntry(
        "file",
        configFile,
        ".config/app/config.json",
        "normal",
      );

      expect(
        await collectChangedLocalPaths(entry, {
          desiredKeys: new Set([".config/app/config.json"]),
          node: {
            contents: Buffer.from('{"version":1}\n'),
            executable: false,
            secret: false,
            type: "file",
          },
          type: "file",
        }),
      ).toEqual([]);
    },
  );

  it.skipIf(process.platform === "win32")(
    "reports executable-bit drift without explicit permission",
    async () => {
      const workspace = await createWorkspace();
      const scriptFile = join(workspace, ".local", "bin", "tool");

      await mkdir(join(workspace, ".local", "bin"), { recursive: true });
      await writeFile(scriptFile, "#!/bin/sh\n", "utf8");
      await chmod(scriptFile, 0o644);

      const entry = createEntry(
        "file",
        scriptFile,
        ".local/bin/tool",
        "normal",
      );

      expect(
        await collectChangedLocalPaths(entry, {
          desiredKeys: new Set([".local/bin/tool"]),
          node: {
            contents: Buffer.from("#!/bin/sh\n"),
            executable: true,
            secret: false,
            type: "file",
          },
          type: "file",
        }),
      ).toEqual([scriptFile]);
    },
  );

  it.skipIf(process.platform === "win32")(
    "reports explicit file permission drift",
    async () => {
      const workspace = await createWorkspace();
      const keyFile = join(workspace, ".ssh", "id_rsa");

      await mkdir(join(workspace, ".ssh"), { recursive: true });
      await writeFile(keyFile, "key\n", "utf8");
      await chmod(keyFile, 0o644);

      const entry = createEntry(
        "file",
        keyFile,
        ".ssh/id_rsa",
        "normal",
        0o600,
      );

      expect(
        await collectChangedLocalPaths(entry, {
          desiredKeys: new Set([".ssh/id_rsa"]),
          node: {
            contents: Buffer.from("key\n"),
            executable: false,
            secret: false,
            type: "file",
          },
          type: "file",
        }),
      ).toEqual([keyFile]);
    },
  );

  it.skipIf(process.platform === "win32")(
    "ignores directory permission drift without explicit permission",
    async () => {
      const workspace = await createWorkspace();
      const appDirectory = join(workspace, ".config", "app");

      await mkdir(appDirectory, { recursive: true });
      await chmod(appDirectory, 0o700);

      const entry = createEntry(
        "directory",
        appDirectory,
        ".config/app",
        "normal",
      );

      expect(
        await collectChangedLocalPaths(entry, {
          desiredKeys: new Set([buildDirectoryKey(".config/app")]),
          nodes: new Map(),
          type: "directory",
        }),
      ).toEqual([]);
    },
  );

  it.skipIf(process.platform === "win32")(
    "reports explicit directory permission drift",
    async () => {
      const workspace = await createWorkspace();
      const sshDirectory = join(workspace, ".ssh");

      await mkdir(sshDirectory, { recursive: true });
      await chmod(sshDirectory, 0o755);

      const entry = createEntry(
        "directory",
        sshDirectory,
        ".ssh",
        "normal",
        0o600,
      );

      expect(
        await collectChangedLocalPaths(entry, {
          desiredKeys: new Set([buildDirectoryKey(".ssh")]),
          nodes: new Map(),
          type: "directory",
        }),
      ).toEqual([sshDirectory]);
    },
  );

  it("includes stale local paths for incremental directory updates", async () => {
    const workspace = await createWorkspace();
    const appDirectory = join(workspace, ".config", "app");
    const configFile = join(appDirectory, "config.json");
    const staleFile = join(appDirectory, "stale.txt");

    await mkdir(appDirectory, { recursive: true });
    await writeFile(configFile, '{"version":1}\n', "utf8");
    await writeFile(staleFile, "old\n", "utf8");

    const entry = createEntry(
      "directory",
      appDirectory,
      ".config/app",
      "normal",
    );

    expect(
      await collectChangedLocalPaths(
        entry,
        {
          desiredKeys: new Set([
            buildDirectoryKey(".config/app"),
            ".config/app/config.json",
          ]),
          nodes: new Map([
            [
              "config.json",
              {
                contents: Buffer.from('{"version":1}\n'),
                executable: false,
                secret: false,
                type: "file",
              },
            ],
          ]),
          type: "directory",
        },
        createConfig([entry]),
      ),
    ).toEqual([staleFile]);
  });

  it("does not materialize a parent default-path artifact for a platform-specific child repo path", () => {
    const rootEntry = createEntry(
      "directory",
      "/home/user/.config/zsh",
      ".config/zsh",
      "normal",
    );
    const childEntry = createEntry(
      "file",
      "/home/user/.config/zsh/platform.zsh",
      ".config/zsh/platform.wsl.zsh",
      "normal",
    );
    const materialization = buildEntryMaterialization(
      rootEntry,
      new Map([
        [buildDirectoryKey(".config/zsh"), { type: "directory" }],
        [
          ".config/zsh/platform.zsh",
          {
            contents: Buffer.from("default artifact\n"),
            executable: false,
            secret: false,
            type: "file",
          },
        ],
        [
          ".config/zsh/platform.wsl.zsh",
          {
            contents: Buffer.from("wsl artifact\n"),
            executable: false,
            secret: false,
            type: "file",
          },
        ],
        [
          ".config/zsh/other.zsh",
          {
            contents: Buffer.from("other\n"),
            executable: false,
            secret: false,
            type: "file",
          },
        ],
      ]),
      createConfig([rootEntry, childEntry]),
    );

    expect(materialization).toMatchObject({ type: "directory" });
    expect(materialization.desiredKeys).toEqual(
      new Set([buildDirectoryKey(".config/zsh"), ".config/zsh/other.zsh"]),
    );
    expect(
      materialization.type === "directory"
        ? [...materialization.nodes.keys()]
        : [],
    ).toEqual(["other.zsh"]);
  });

  it("does not count explicit child entry paths as stale parent paths", async () => {
    const workspace = await createWorkspace();
    const rootDirectory = join(workspace, ".config", "zsh");
    const childDirectory = join(rootDirectory, "plugins");
    const parentFile = join(rootDirectory, ".zshrc");
    const childFile = join(childDirectory, "plugin.zsh");

    await mkdir(childDirectory, { recursive: true });
    await writeFile(parentFile, "source ~/.zsh/plugins/plugin.zsh\n", "utf8");
    await writeFile(childFile, "echo plugin\n", "utf8");

    const rootEntry = createEntry(
      "directory",
      rootDirectory,
      ".config/zsh",
      "normal",
    );
    const childEntry = createEntry(
      "directory",
      childDirectory,
      ".config/zsh/plugins",
      "normal",
    );
    const existingKeys = new Set<string>();
    const keyToLocalPath = new Map<string, string>();

    const deletedLocalCount = await countDeletedLocalNodes(
      rootEntry,
      new Set([buildDirectoryKey(".config/zsh"), ".config/zsh/.zshrc"]),
      createConfig([rootEntry, childEntry]),
      existingKeys,
      keyToLocalPath,
    );

    expect(deletedLocalCount).toBe(0);
    expect(existingKeys).toEqual(
      new Set([buildDirectoryKey(".config/zsh"), ".config/zsh/.zshrc"]),
    );
    expect(keyToLocalPath.has(".config/zsh/plugins/plugin.zsh")).toBe(false);
  });

  it("does not count a platform-specific child local file as a stale parent path", async () => {
    const workspace = await createWorkspace();
    const rootDirectory = join(workspace, ".config", "zsh");
    const platformFile = join(rootDirectory, "platform.zsh");
    const otherFile = join(rootDirectory, "other.zsh");

    await mkdir(rootDirectory, { recursive: true });
    await writeFile(platformFile, "local platform\n", "utf8");
    await writeFile(otherFile, "other\n", "utf8");

    const rootEntry = createEntry(
      "directory",
      rootDirectory,
      ".config/zsh",
      "normal",
    );
    const childEntry = createEntry(
      "file",
      platformFile,
      ".config/zsh/platform.wsl.zsh",
      "normal",
    );
    const existingKeys = new Set<string>();
    const keyToLocalPath = new Map<string, string>();

    const deletedLocalCount = await countDeletedLocalNodes(
      rootEntry,
      new Set([
        buildDirectoryKey(".config/zsh"),
        ".config/zsh/other.zsh",
        ".config/zsh/platform.wsl.zsh",
      ]),
      createConfig([rootEntry, childEntry]),
      existingKeys,
      keyToLocalPath,
    );

    expect(deletedLocalCount).toBe(0);
    expect(existingKeys).toEqual(
      new Set([buildDirectoryKey(".config/zsh"), ".config/zsh/other.zsh"]),
    );
    expect(keyToLocalPath.has(".config/zsh/platform.zsh")).toBe(false);
  });

  it("should not throw EINVAL when a symlink node in snapshot exists as a directory locally", async () => {
    const workspace = await createWorkspace();
    const appDirectory = join(workspace, ".claude");
    const skillsPath = join(appDirectory, "skills");

    await mkdir(skillsPath, { recursive: true });

    const entry = createEntry("directory", appDirectory, ".claude", "normal");

    const snapshot = {
      desiredKeys: new Set([".claude/skills"]),
      nodes: new Map<string, FileLikeSnapshotNode>([
        [
          "skills",
          {
            linkTarget: "/some/target",
            type: "symlink",
          },
        ],
      ]),
      type: "directory" as const,
    };

    const changedPaths = await collectChangedLocalPaths(entry, snapshot);

    expect(changedPaths).toContain(skillsPath);
  });
});
