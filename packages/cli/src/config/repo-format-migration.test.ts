import { describe, expect, it, vi } from "vitest";

import { DotweaveError } from "#app/lib/error.ts";
import {
  applyRepositoryFormatMigrations,
  assertRepositoryFormatSupported,
  type RepoFormatMigrationFn,
  type RepoFormatMigrationRegistry,
} from "./repo-format-migration.ts";
import type { ResolvedSyncConfig } from "./sync-schema.ts";

const configWithFormat = (
  repositoryFormat: number | undefined,
): ResolvedSyncConfig => ({
  entries: [],
  profiles: [],
  version: 8,
  ...(repositoryFormat === undefined ? {} : { repositoryFormat }),
});

const registry = (
  entries: [number, RepoFormatMigrationFn][],
): RepoFormatMigrationRegistry => new Map(entries);

describe("assertRepositoryFormatSupported", () => {
  it("passes when the format is within range", () => {
    expect(() => assertRepositoryFormatSupported(1, 1, 0, "ctx")).not.toThrow();
    expect(() => assertRepositoryFormatSupported(0, 1, 0, "ctx")).not.toThrow();
  });

  it("throws REPO_FORMAT_NEWER when the format is above the target", () => {
    expect(() => assertRepositoryFormatSupported(2, 1, 0, "ctx")).toThrowError(
      /newer than this CLI supports/,
    );
  });

  it("throws REPO_FORMAT_TOO_OLD when the format is below the floor", () => {
    expect(() => assertRepositoryFormatSupported(0, 2, 1, "ctx")).toThrowError(
      /older than this CLI supports/,
    );
  });
});

describe("applyRepositoryFormatMigrations", () => {
  it("treats an absent repositoryFormat as format 0", async () => {
    const step = vi.fn(async () => {});
    const result = await applyRepositoryFormatMigrations(
      "/repo",
      configWithFormat(undefined),
      registry([[0, step]]),
      1,
      0,
    );

    expect(result).toEqual({ fromFormat: 0, migrated: true });
    expect(step).toHaveBeenCalledOnce();
    expect(step).toHaveBeenCalledWith("/repo", expect.anything());
  });

  it("is a no-op when already at the target format", async () => {
    const step = vi.fn(async () => {});
    const result = await applyRepositoryFormatMigrations(
      "/repo",
      configWithFormat(1),
      registry([[0, step]]),
      1,
      0,
    );

    expect(result).toEqual({ fromFormat: 1, migrated: false });
    expect(step).not.toHaveBeenCalled();
  });

  it("runs each contiguous step in order up to the target", async () => {
    const calls: number[] = [];
    const result = await applyRepositoryFormatMigrations(
      "/repo",
      configWithFormat(0),
      registry([
        [0, async () => void calls.push(0)],
        [1, async () => void calls.push(1)],
      ]),
      2,
      0,
    );

    expect(result).toEqual({ fromFormat: 0, migrated: true });
    expect(calls).toEqual([0, 1]);
  });

  it("throws REPO_FORMAT_MIGRATION_NOT_FOUND for a missing step", async () => {
    await expect(
      applyRepositoryFormatMigrations(
        "/repo",
        configWithFormat(0),
        registry([]),
        1,
        0,
      ),
    ).rejects.toThrowError(/No repository format migration found for 0/);
  });

  it("throws REPO_FORMAT_NEWER when the repository is newer than the target", async () => {
    await expect(
      applyRepositoryFormatMigrations(
        "/repo",
        configWithFormat(5),
        registry([]),
        1,
        0,
      ),
    ).rejects.toThrowError(/newer than this CLI supports/);
  });

  it("wraps a DotweaveError from a step with migration context", async () => {
    const failing = registry([
      [
        0,
        async () => {
          throw new DotweaveError("boom", { code: "X" });
        },
      ],
    ]);

    await expect(
      applyRepositoryFormatMigrations(
        "/repo",
        configWithFormat(0),
        failing,
        1,
        0,
      ),
    ).rejects.toThrowError("boom");
  });

  it("wraps a non-DotweaveError from a step as REPO_FORMAT_MIGRATION_FAILED", async () => {
    const failing = registry([
      [
        0,
        async () => {
          throw new Error("raw failure");
        },
      ],
    ]);

    await expect(
      applyRepositoryFormatMigrations(
        "/repo",
        configWithFormat(0),
        failing,
        1,
        0,
      ),
    ).rejects.toThrowError(/Failed to migrate repository format 0/);
  });
});
