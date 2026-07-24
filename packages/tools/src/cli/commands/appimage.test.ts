import { access } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { getRepoRoot } from "../../lib/git.ts";
import { getAppImageIconPath } from "./appimage.ts";

describe("getAppImageIconPath", () => {
  test("resolves the homepage logo from its public asset location", async () => {
    const repoRoot = await getRepoRoot(process.cwd());
    const iconPath = getAppImageIconPath(repoRoot);

    expect(iconPath).toBe(
      join(repoRoot, "packages/homepage/public/favicon.svg"),
    );
    await expect(access(iconPath)).resolves.toBeUndefined();
  });
});
