import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

const mockEnv = vi.hoisted(() => ({
  APPDATA: "",
  DOTWEAVE_HOME: "",
  HOME: "",
  LOCALAPPDATA: "",
  USERPROFILE: "",
  XDG_CONFIG_HOME: "",
}));

vi.mock("#app/lib/env.ts", () => ({
  ENV: mockEnv,
}));

import {
  createInitialSyncConfig,
  formatSyncConfig,
} from "#app/config/sync-schema.ts";
import { DotweaveError } from "#app/lib/error.ts";
import { initializeSyncDirectory } from "#app/services/init.ts";
import {
  createAgeKeyPair,
  createTemporaryDirectory,
  runGit,
  writeIdentityFile,
} from "../test/helpers/sync-fixture.ts";

const temporaryDirectories: string[] = [];

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory("dotweave-init-");

  temporaryDirectories.push(directory);

  return directory;
};

const setEnvironment = (homeDirectory: string, xdgConfigHome: string) => {
  mockEnv.APPDATA = xdgConfigHome;
  mockEnv.DOTWEAVE_HOME = "";
  mockEnv.HOME = homeDirectory;
  mockEnv.LOCALAPPDATA = join(homeDirectory, "AppData", "Local");
  mockEnv.USERPROFILE = homeDirectory;
  mockEnv.XDG_CONFIG_HOME = xdgConfigHome;
};

afterEach(async () => {
  mockEnv.APPDATA = "";
  mockEnv.DOTWEAVE_HOME = "";
  mockEnv.HOME = "";
  mockEnv.LOCALAPPDATA = "";
  mockEnv.USERPROFILE = "";
  mockEnv.XDG_CONFIG_HOME = "";

  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

describe("init service", () => {
  it("writes a supplied age private key during initialization", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const ageKeys = await createAgeKeyPair();
    const extraRecipient = await createAgeKeyPair();

    await runGit(["init", "-b", "main", sourceRepository], workspace);

    setEnvironment(homeDirectory, xdgConfigHome);
    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const result = await initializeSyncDirectory({
      ageIdentity: `  ${ageKeys.identity}  `,
      recipients: [ageKeys.recipient, extraRecipient.recipient],
      repository: sourceRepository,
    });

    expect(result.generatedIdentity).toBe(false);
    expect(
      await readFile(join(xdgConfigHome, "dotweave", "keys.txt"), "utf8"),
    ).toBe(`${ageKeys.identity}\n`);
    expect(
      JSON.parse(await readFile(join(syncDirectory, "manifest.jsonc"), "utf8")),
    ).toMatchObject({
      age: {
        recipients: expect.arrayContaining([
          ageKeys.recipient,
          extraRecipient.recipient,
        ]),
      },
    });
  });

  it("uses DOTWEAVE_HOME for initialization storage", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const dotweaveHome = join(workspace, "custom-dotweave");
    const ageKeys = await createAgeKeyPair();

    setEnvironment(homeDirectory, xdgConfigHome);
    mockEnv.DOTWEAVE_HOME = dotweaveHome;

    await initializeSyncDirectory({
      ageIdentity: ageKeys.identity,
      recipients: [ageKeys.recipient],
    });

    await expect(
      readFile(join(dotweaveHome, "keys.txt"), "utf8"),
    ).resolves.toBe(`${ageKeys.identity}\n`);
    await expect(
      readFile(join(dotweaveHome, "settings.jsonc"), "utf8"),
    ).resolves.toContain('"version": 3');
    await expect(
      readFile(join(dotweaveHome, "repository", "manifest.jsonc"), "utf8"),
    ).resolves.toContain('"version": 8');
    await expect(
      readFile(join(xdgConfigHome, "dotweave", "settings.jsonc"), "utf8"),
    ).rejects.toThrow();
  });

  it("rejects an invalid supplied age private key", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");

    setEnvironment(homeDirectory, xdgConfigHome);
    await expect(
      initializeSyncDirectory({
        ageIdentity: "not-a-key",
        recipients: [],
      }),
    ).rejects.toThrowError(/Invalid age private key/u);
  });

  it("reports a missing git executable during local initialization", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    setEnvironment(homeDirectory, xdgConfigHome);

    try {
      vi.stubEnv("PATH", "");

      await expect(
        initializeSyncDirectory({
          recipients: [ageKeys.recipient],
        }),
      ).rejects.toMatchObject({
        code: "SYNC_INIT_GIT_FAILED",
        hint: expect.stringContaining("Git"),
        message: "Failed to initialize the sync directory.",
      });
      await expect(
        initializeSyncDirectory({
          recipients: [ageKeys.recipient],
        }),
      ).rejects.toMatchObject({
        details: expect.arrayContaining([
          expect.stringContaining("not installed or not on PATH"),
        ]),
        hint: expect.stringContaining("PATH"),
      });
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("reports a missing git executable during repository cloning", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    setEnvironment(homeDirectory, xdgConfigHome);

    try {
      vi.stubEnv("PATH", "");

      await expect(
        initializeSyncDirectory({
          recipients: [ageKeys.recipient],
          repository: "https://example.invalid/dotfiles.git",
        }),
      ).rejects.toMatchObject({
        code: "SYNC_CLONE_FAILED",
        details: expect.arrayContaining([
          expect.stringContaining("not installed or not on PATH"),
        ]),
        hint: expect.not.stringContaining("repository source is reachable"),
        message: "Failed to clone the sync directory.",
      });
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("clones a configured repository source during initialization", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await runGit(["init", "-b", "main", sourceRepository], workspace);

    setEnvironment(homeDirectory, xdgConfigHome);
    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const result = await initializeSyncDirectory({
      recipients: [ageKeys.recipient],
      repository: sourceRepository,
    });

    expect(result.gitAction).toBe("cloned");
    expect(result.gitSource).toBe(sourceRepository);
    expect(
      await readFile(join(syncDirectory, "manifest.jsonc"), "utf8"),
    ).toContain('"version": 8');
    expect(
      await readFile(join(syncDirectory, "manifest.jsonc"), "utf8"),
    ).not.toContain("identityFile");
    expect(await readFile(join(syncDirectory, ".gitattributes"), "utf8")).toBe(
      "* -text\n",
    );
  });

  it("rejects an existing initialized repo by default", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      recipients: [ageKeys.recipient],
    });

    await expect(
      initializeSyncDirectory({
        recipients: [ageKeys.recipient],
      }),
    ).rejects.toMatchObject({
      code: "INIT_ALREADY_INITIALIZED",
      message: "Sync directory is already initialized.",
    });
  });

  it("rejects non-empty sync directories that are not git repositories", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(syncDirectory, { recursive: true });
    await writeFile(join(syncDirectory, "placeholder.txt"), "keep\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);
    await expect(
      initializeSyncDirectory({
        recipients: [ageKeys.recipient],
      }),
    ).rejects.toThrowError(DotweaveError);
    await expect(
      initializeSyncDirectory({
        recipients: [ageKeys.recipient],
      }),
    ).rejects.toThrowError(/Sync directory already exists and is not empty/u);
    await expect(
      initializeSyncDirectory({
        identityFile: "$XDG_CONFIG_HOME/dotweave/keys.txt",
        recipients: [ageKeys.recipient],
      }),
    ).rejects.toMatchObject({
      details: expect.arrayContaining([`Sync directory: ${syncDirectory}`]),
    });
  });

  it("force removes existing local init state and clones a supplied repository", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const oldAgeKeys = await createAgeKeyPair();
    const newAgeKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, oldAgeKeys.identity);
    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      recipients: [oldAgeKeys.recipient],
    });
    await writeFile(
      join(xdgConfigHome, "dotweave", "settings.jsonc"),
      `${JSON.stringify({ activeProfile: "old-profile", version: 3 }, null, 2)}\n`,
      "utf8",
    );
    await writeFile(
      join(syncDirectory, "local-only.txt"),
      "remove me\n",
      "utf8",
    );

    await runGit(["init", "-b", "main", sourceRepository], workspace);
    await writeFile(
      join(sourceRepository, "remote-only.txt"),
      "cloned\n",
      "utf8",
    );
    await runGit(["add", "remote-only.txt"], sourceRepository);
    await runGit(["commit", "-m", "add remote marker"], sourceRepository);

    const result = await initializeSyncDirectory({
      ageIdentity: newAgeKeys.identity,
      force: true,
      recipients: [],
      repository: sourceRepository,
    });

    expect(result.gitAction).toBe("cloned");
    expect(result.gitSource).toBe(sourceRepository);
    const remoteOnly = await readFile(
      join(syncDirectory, "remote-only.txt"),
      "utf8",
    );
    expect(remoteOnly.replace(/\r\n/gu, "\n")).toBe("cloned\n");
    await expect(
      readFile(join(syncDirectory, "local-only.txt"), "utf8"),
    ).rejects.toThrow();
    await expect(
      readFile(join(xdgConfigHome, "dotweave", "keys.txt"), "utf8"),
    ).resolves.toBe(`${newAgeKeys.identity}\n`);
    await expect(
      readFile(join(xdgConfigHome, "dotweave", "keys.txt"), "utf8"),
    ).resolves.not.toContain(oldAgeKeys.identity);
    await expect(
      JSON.parse(
        await readFile(
          join(xdgConfigHome, "dotweave", "settings.jsonc"),
          "utf8",
        ),
      ),
    ).toMatchObject({
      activeProfile: "default",
      version: 3,
    });
  });

  it("force rejects importing a repository without a new age identity after removing the old identity", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const oldAgeKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, oldAgeKeys.identity);
    await runGit(["init", "-b", "main", sourceRepository], workspace);

    setEnvironment(homeDirectory, xdgConfigHome);
    await expect(
      initializeSyncDirectory({
        force: true,
        recipients: [],
        repository: sourceRepository,
      }),
    ).rejects.toMatchObject({
      code: "INIT_AGE_IDENTITY_REQUIRED",
      hint: expect.stringContaining("--key-file"),
      message: "Existing repository setup requires an age private key.",
    });
  });

  it("force replaces an old identity and rewrites settings for local initialization", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const oldAgeKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, oldAgeKeys.identity);
    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      recipients: [oldAgeKeys.recipient],
    });
    await writeFile(
      join(xdgConfigHome, "dotweave", "settings.jsonc"),
      `${JSON.stringify({ activeProfile: "old-profile", version: 3 }, null, 2)}\n`,
      "utf8",
    );

    const result = await initializeSyncDirectory({
      force: true,
      recipients: [],
    });

    expect(result.generatedIdentity).toBe(true);
    expect(result.gitAction).toBe("initialized");
    await expect(
      readFile(join(syncDirectory, "manifest.jsonc"), "utf8"),
    ).resolves.toContain('"version": 8');

    const newIdentity = await readFile(
      join(xdgConfigHome, "dotweave", "keys.txt"),
      "utf8",
    );
    expect(newIdentity).toContain("AGE-SECRET-KEY-");
    expect(newIdentity).not.toContain(oldAgeKeys.identity);
    expect(
      JSON.parse(
        await readFile(
          join(xdgConfigHome, "dotweave", "settings.jsonc"),
          "utf8",
        ),
      ),
    ).toMatchObject({
      activeProfile: "default",
      version: 3,
    });
  });

  it("force removes a non-git non-empty sync directory and initializes", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const syncDirectory = join(xdgConfigHome, "dotweave", "repository");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);
    await mkdir(syncDirectory, { recursive: true });
    await writeFile(join(syncDirectory, "placeholder.txt"), "remove\n", "utf8");

    setEnvironment(homeDirectory, xdgConfigHome);
    const result = await initializeSyncDirectory({
      force: true,
      recipients: [ageKeys.recipient],
    });

    expect(result.gitAction).toBe("initialized");
    await expect(
      readFile(join(syncDirectory, "manifest.jsonc"), "utf8"),
    ).resolves.toContain('"version": 8');
    await expect(
      readFile(join(syncDirectory, "placeholder.txt"), "utf8"),
    ).rejects.toThrow();
  });

  it("rejects repeated init before checking recipient mismatches", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const ageKeys = await createAgeKeyPair();

    await writeIdentityFile(xdgConfigHome, ageKeys.identity);

    setEnvironment(homeDirectory, xdgConfigHome);

    await initializeSyncDirectory({
      recipients: [ageKeys.recipient],
    });

    await expect(
      initializeSyncDirectory({
        recipients: ["age1differentrecipient"],
      }),
    ).rejects.toMatchObject({
      code: "INIT_ALREADY_INITIALIZED",
      message: "Sync directory is already initialized.",
    });
  });

  it("writes a supplied age private key when cloning a repo that already has manifest.jsonc", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const ageKeys = await createAgeKeyPair();

    await runGit(["init", "-b", "main", sourceRepository], workspace);

    const initialConfig = createInitialSyncConfig({
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(sourceRepository, "manifest.jsonc"),
      formatSyncConfig(initialConfig),
      "utf8",
    );
    await runGit(["add", "manifest.jsonc"], sourceRepository);
    await runGit(
      ["commit", "-m", "initial config", "--author", "test <test@test.com>"],
      sourceRepository,
    );

    setEnvironment(homeDirectory, xdgConfigHome);
    const result = await initializeSyncDirectory({
      ageIdentity: ageKeys.identity,
      recipients: [],
      repository: sourceRepository,
    });

    expect(result.alreadyInitialized).toBe(false);
    expect(result.generatedIdentity).toBe(false);
    expect(
      await readFile(join(xdgConfigHome, "dotweave", "keys.txt"), "utf8"),
    ).toBe(`${ageKeys.identity}\n`);
    expect(
      JSON.parse(
        await readFile(
          join(xdgConfigHome, "dotweave", "settings.jsonc"),
          "utf8",
        ),
      ),
    ).toMatchObject({
      activeProfile: "default",
      version: 3,
    });
  });

  it("rejects cloning a repo with manifest.jsonc when no key or identity file is available", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const ageKeys = await createAgeKeyPair();

    await runGit(["init", "-b", "main", sourceRepository], workspace);

    const initialConfig = createInitialSyncConfig({
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(sourceRepository, "manifest.jsonc"),
      formatSyncConfig(initialConfig),
      "utf8",
    );
    await runGit(["add", "manifest.jsonc"], sourceRepository);
    await runGit(
      ["commit", "-m", "initial config", "--author", "test <test@test.com>"],
      sourceRepository,
    );

    setEnvironment(homeDirectory, xdgConfigHome);
    await expect(
      initializeSyncDirectory({
        generateAgeIdentity: true,
        recipients: [],
        repository: sourceRepository,
      }),
    ).rejects.toThrowError(
      /Existing repository setup requires an age private key/u,
    );
  });

  it("rejects cloning a repo with manifest.json", async () => {
    const workspace = await createWorkspace();
    const homeDirectory = join(workspace, "home");
    const xdgConfigHome = join(workspace, "xdg");
    const sourceRepository = join(workspace, "remote-sync");
    const ageKeys = await createAgeKeyPair();

    await runGit(["init", "-b", "main", sourceRepository], workspace);

    const initialConfig = createInitialSyncConfig({
      recipients: [ageKeys.recipient],
    });

    await writeFile(
      join(sourceRepository, "manifest.json"),
      formatSyncConfig(initialConfig),
      "utf8",
    );
    await runGit(["add", "manifest.json"], sourceRepository);
    await runGit(
      ["commit", "-m", "legacy config", "--author", "test <test@test.com>"],
      sourceRepository,
    );

    setEnvironment(homeDirectory, xdgConfigHome);
    await expect(
      initializeSyncDirectory({
        ageIdentity: ageKeys.identity,
        recipients: [],
        repository: sourceRepository,
      }),
    ).rejects.toMatchObject({
      code: "CONFIG_JSON_UNSUPPORTED",
      details: expect.arrayContaining([
        expect.stringMatching(/Unsupported config file: .*manifest\.json/u),
      ]),
      message: "Unsupported dotweave config file.",
    });
  });
});
