import { describe, expect, it } from "vitest";

import type {
  ResolvedSyncConfig,
  ResolvedSyncConfigEntry,
} from "#app/config/sync-schema.ts";
import {
  buildEffectiveSyncConfig,
  type RuntimeAgeConfig,
} from "./sync-context.ts";

const testAge: RuntimeAgeConfig = {
  identityFile: "/tmp/keys.txt",
  recipients: ["age1example"],
};

const createEntry = (
  repoPath: string,
  profiles: readonly string[] = [],
): ResolvedSyncConfigEntry => ({
  configuredMode: { default: "normal" },
  configuredLocalPath: { default: `~/${repoPath}` },
  kind: "file",
  localPath: `/tmp/home/${repoPath}`,
  profiles,
  profilesExplicit: profiles.length > 0,
  mode: "normal",
  modeExplicit: false,
  permissionExplicit: false,
  repoPath,
});

describe("sync runtime", () => {
  it("attaches activeProfile from selection to the effective config", () => {
    const config = {
      entries: [
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.config/zsh" },
          kind: "directory",
          localPath: "/tmp/home/.config/zsh",
          profiles: ["default", "work"],
          profilesExplicit: true,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".config/zsh",
        },
      ],
      profiles: ["work"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      {
        profile: "work",
        mode: "single",
      },
      testAge,
    );

    expect(effective.activeProfile).toBe("work");
    expect(effective.age).toEqual(testAge);
    expect(effective.entries).toHaveLength(1);
    expect(effective.entries[0]).toMatchObject({
      mode: "normal",
      repoPath: ".config/zsh",
    });
    expect(effective.entries[0]?.profiles).toEqual(["default", "work"]);
  });

  it("passes through all entries regardless of profile selection", () => {
    const config = {
      entries: [
        {
          configuredMode: { default: "secret" },
          configuredLocalPath: { default: "~/.gitconfig" },
          kind: "file",
          localPath: "/tmp/home/.gitconfig",
          profiles: ["default", "work"],
          profilesExplicit: true,
          mode: "secret",
          modeExplicit: true,
          permissionExplicit: false,
          repoPath: ".gitconfig",
        },
      ],
      profiles: ["work"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    expect(
      buildEffectiveSyncConfig(
        config,
        {
          mode: "none",
        },
        testAge,
      ).entries,
    ).toHaveLength(1);

    expect(
      buildEffectiveSyncConfig(
        config,
        {
          profile: "work",
          mode: "single",
        },
        testAge,
      ).entries,
    ).toHaveLength(1);
  });

  it("filters entries by active profile when entries have explicit profiles", () => {
    const config = {
      entries: [
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.config/work-app" },
          kind: "directory",
          localPath: "/tmp/home/.config/work-app",
          profiles: ["work"],
          profilesExplicit: true,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".config/work-app",
        },
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.config/personal-app" },
          kind: "directory",
          localPath: "/tmp/home/.config/personal-app",
          profiles: ["personal"],
          profilesExplicit: true,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".config/personal-app",
        },
      ],
      profiles: ["work", "personal"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      { profile: "work", mode: "single" },
      testAge,
    );

    expect(effective.entries).toHaveLength(1);
    expect(effective.entries[0]?.repoPath).toBe(".config/work-app");
  });

  it("includes entries with empty profiles array regardless of profile", () => {
    const config = {
      entries: [
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.bashrc" },
          kind: "file",
          localPath: "/tmp/home/.bashrc",
          profiles: [] as const,
          profilesExplicit: false,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".bashrc",
        },
      ],
      profiles: ["work"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      { profile: "work", mode: "single" },
      testAge,
    );

    expect(effective.entries).toHaveLength(1);
    expect(effective.entries[0]?.repoPath).toBe(".bashrc");
  });

  it("sets activeProfile to undefined when selection mode is 'none'", () => {
    const config = {
      entries: [],
      profiles: [],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      { mode: "none" },
      testAge,
    );

    expect(effective.activeProfile).toBeUndefined();
  });

  it("propagates age config through to the effective config", () => {
    const config = {
      entries: [],
      profiles: [],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const customAge: RuntimeAgeConfig = {
      identityFile: "/custom/identity",
      recipients: ["age1custom"],
    };

    const effective = buildEffectiveSyncConfig(
      config,
      { mode: "none" },
      customAge,
    );

    expect(effective.age).toEqual(customAge);
  });

  it("filters entries so only profile-matching or unprofiled entries remain", () => {
    const config = {
      entries: [
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.config/work-tool" },
          kind: "directory",
          localPath: "/tmp/home/.config/work-tool",
          profiles: ["work"],
          profilesExplicit: true,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".config/work-tool",
        },
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.vimrc" },
          kind: "file",
          localPath: "/tmp/home/.vimrc",
          profiles: [] as const,
          profilesExplicit: false,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".vimrc",
        },
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.config/personal-tool" },
          kind: "directory",
          localPath: "/tmp/home/.config/personal-tool",
          profiles: ["personal"],
          profilesExplicit: true,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".config/personal-tool",
        },
      ],
      profiles: ["work", "personal"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      { profile: "work", mode: "single" },
      testAge,
    );

    expect(effective.entries).toHaveLength(2);
    expect(effective.entries.map((e) => e.repoPath)).toEqual([
      ".config/work-tool",
      ".vimrc",
    ]);
  });

  it("normalizes explicit runtime profile selections before validation", () => {
    const config = {
      entries: [
        {
          configuredMode: { default: "normal" },
          configuredLocalPath: { default: "~/.config/work-tool" },
          kind: "directory",
          localPath: "/tmp/home/.config/work-tool",
          profiles: ["Work"],
          profilesExplicit: true,
          mode: "normal",
          modeExplicit: false,
          permissionExplicit: false,
          repoPath: ".config/work-tool",
        },
      ],
      profiles: ["Work"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      { profile: " Work ", mode: "single" },
      testAge,
    );

    expect(effective.activeProfile).toBe("Work");
    expect(effective.entries).toHaveLength(1);
  });

  it("rejects unknown runtime profile selections instead of silently dropping named entries", () => {
    const config = {
      entries: [createEntry(".vimrc"), createEntry(".config/work", ["work"])],
      profiles: ["work"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    expect(() => {
      buildEffectiveSyncConfig(
        config,
        { profile: "personal", mode: "single" },
        testAge,
      );
    }).toThrow("Unknown profile 'personal'.");
  });

  it("treats explicit default profile selection like the default layer", () => {
    const config = {
      entries: [
        createEntry(".bashrc"),
        createEntry(".profile", ["default"]),
        createEntry(".config/work", ["work"]),
      ],
      profiles: ["work"],
      version: 7 as const,
    } satisfies ResolvedSyncConfig;

    const effective = buildEffectiveSyncConfig(
      config,
      { profile: "default", mode: "single" },
      testAge,
    );

    expect(effective.activeProfile).toBe("default");
    expect(effective.entries.map((entry) => entry.repoPath)).toEqual([
      ".bashrc",
      ".profile",
    ]);
  });
});
