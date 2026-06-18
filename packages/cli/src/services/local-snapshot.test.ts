import { chmod, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type {
  ResolvedSyncConfigEntry,
  SyncConfigEntryKind,
  SyncMode,
} from "#app/config/sync-schema.ts";
import { formatPermissionOctal } from "#app/lib/file-mode.ts";
import { buildLocalSnapshot } from "#app/services/local-snapshot.ts";
import type { EffectiveSyncConfig } from "#app/services/sync-context.ts";
import { createTemporaryDirectory } from "../test/helpers/sync-fixture.ts";

const temporaryDirectories: string[] = [];

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory("dotweave-local-snapshot-");

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

describe("local snapshot", () => {
  it("does not recurse into ignored directory entries", async () => {
    const workspace = await createWorkspace();
    const opencodeDirectory = join(workspace, ".config", "opencode");
    const nodeModulesDirectory = join(opencodeDirectory, "node_modules");
    const nestedDirectory = join(nodeModulesDirectory, "pkg-a", "dist");
    const trackedFile = join(opencodeDirectory, "settings.json");
    const ignoredFile = join(nestedDirectory, "index.js");

    await mkdir(nestedDirectory, { recursive: true });
    await writeFile(trackedFile, "{\n}\n", "utf8");
    await writeFile(ignoredFile, "module.exports = {}\n", "utf8");

    const config = createConfig([
      createEntry("directory", opencodeDirectory, ".config/opencode", "normal"),
      createEntry(
        "directory",
        nodeModulesDirectory,
        ".config/opencode/node_modules",
        "ignore",
      ),
    ]);
    const snapshot = await buildLocalSnapshot(config);

    expect([...snapshot.keys()].sort()).toEqual([
      ".config/opencode",
      ".config/opencode/settings.json",
    ]);
  });

  it("does not collect a directory child through its default repo path when the child resolves to a platform-specific repo path", async () => {
    const workspace = await createWorkspace();
    const zshDirectory = join(workspace, ".config", "zsh");
    const platformFile = join(zshDirectory, "platform.zsh");
    const otherFile = join(zshDirectory, "other.zsh");

    await mkdir(zshDirectory, { recursive: true });
    await writeFile(platformFile, "wsl platform\n", "utf8");
    await writeFile(otherFile, "other\n", "utf8");

    const snapshot = await buildLocalSnapshot(
      createConfig([
        createEntry("directory", zshDirectory, ".config/zsh", "normal"),
        createEntry(
          "file",
          platformFile,
          ".config/zsh/platform.wsl.zsh",
          "normal",
        ),
      ]),
    );

    expect([...snapshot.keys()].sort()).toEqual([
      ".config/zsh",
      ".config/zsh/other.zsh",
      ".config/zsh/platform.wsl.zsh",
    ]);
  });

  it("still captures explicit child overrides under ignored directories", async () => {
    const workspace = await createWorkspace();
    const opencodeDirectory = join(workspace, ".config", "opencode");
    const nodeModulesDirectory = join(opencodeDirectory, "node_modules");
    const nestedDirectory = join(nodeModulesDirectory, "pkg-a");
    const ignoredFile = join(nestedDirectory, "index.js");
    const keepFile = join(nodeModulesDirectory, "keep.js");

    await mkdir(nestedDirectory, { recursive: true });
    await writeFile(ignoredFile, "module.exports = {}\n", "utf8");
    await writeFile(keepFile, "export const keep = true;\n", "utf8");

    const snapshot = await buildLocalSnapshot(
      createConfig([
        createEntry(
          "directory",
          opencodeDirectory,
          ".config/opencode",
          "normal",
        ),
        createEntry(
          "directory",
          nodeModulesDirectory,
          ".config/opencode/node_modules",
          "ignore",
        ),
        createEntry(
          "file",
          keepFile,
          ".config/opencode/node_modules/keep.js",
          "normal",
        ),
      ]),
    );

    expect(snapshot.has(".config/opencode")).toBe(true);
    expect(snapshot.has(".config/opencode/node_modules")).toBe(false);
    expect(snapshot.has(".config/opencode/node_modules/keep.js")).toBe(true);
    expect(snapshot.has(".config/opencode/node_modules/pkg-a/index.js")).toBe(
      false,
    );
  });

  it.skipIf(process.platform === "win32")(
    "derives executable metadata from explicit manifest permission",
    async () => {
      const workspace = await createWorkspace();
      const keyFile = join(workspace, ".ssh", "id_rsa");

      await mkdir(join(workspace, ".ssh"), { recursive: true });
      await writeFile(keyFile, "key\n", "utf8");
      await chmod(keyFile, 0o755);

      const snapshot = await buildLocalSnapshot(
        createConfig([
          createEntry("file", keyFile, ".ssh/id_rsa", "normal", 0o600),
        ]),
      );
      const node = snapshot.get(".ssh/id_rsa");

      expect(node).toMatchObject({
        executable: false,
        type: "file",
      });
    },
  );

  it.skipIf(process.platform === "win32")(
    "captures symlink entries in the snapshot",
    async () => {
      const workspace = await createWorkspace();
      const targetFile = join(workspace, "target.txt");
      const linkPath = join(workspace, "link.txt");

      await writeFile(targetFile, "target\n", "utf8");
      await symlink(targetFile, linkPath);

      const snapshot = await buildLocalSnapshot(
        createConfig([createEntry("file", linkPath, "link.txt", "normal")]),
      );

      expect(snapshot.get("link.txt")).toMatchObject({
        type: "symlink",
        linkTarget: targetFile,
      });
    },
  );

  it("skips absent local paths for normal-mode entries", async () => {
    const workspace = await createWorkspace();
    const absentPath = join(workspace, "does-not-exist.txt");

    const snapshot = await buildLocalSnapshot(
      createConfig([
        createEntry("file", absentPath, "does-not-exist.txt", "normal"),
      ]),
    );

    expect(snapshot.has("does-not-exist.txt")).toBe(false);
  });

  it("handles file-to-directory type change gracefully", async () => {
    const workspace = await createWorkspace();
    const filePath = join(workspace, "expected-dir");

    await writeFile(filePath, "not a directory\n", "utf8");

    await expect(
      buildLocalSnapshot(
        createConfig([
          createEntry("directory", filePath, "expected-dir", "normal"),
        ]),
      ),
    ).rejects.toThrow("expects a directory");
  });

  it.skipIf(process.platform === "win32")(
    "handles permission-only entries without explicit configured permission",
    async () => {
      const workspace = await createWorkspace();
      const scriptFile = join(workspace, "script.sh");

      await mkdir(join(workspace), { recursive: true });
      await writeFile(scriptFile, "#!/bin/sh\n", "utf8");
      await chmod(scriptFile, 0o755);

      const snapshot = await buildLocalSnapshot(
        createConfig([createEntry("file", scriptFile, "script.sh", "normal")]),
      );

      expect(snapshot.get("script.sh")).toMatchObject({
        type: "file",
        executable: true,
      });
    },
  );
});
