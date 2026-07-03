import { readdir, readFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

import { describe, expect, it } from "vitest";

const workspaceRoot = resolve(import.meta.dirname, "../../..");
const docsRoot = join(
  workspaceRoot,
  "packages",
  "homepage",
  "src",
  "content",
  "docs",
);

const collectContentFiles = async (directory: string): Promise<string[]> => {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(
    entries.map(async (entry) => {
      const fullPath = join(directory, entry.name);

      if (entry.isDirectory()) {
        return collectContentFiles(fullPath);
      }

      return entry.isFile() && /\.(md|mdx)$/u.test(entry.name)
        ? [fullPath]
        : [];
    }),
  );

  return files.flat();
};

const unsupportedInitFlags = [
  {
    name: "--key",
    pattern: /(^|[\s`])--key(?![-\w])/u,
  },
  {
    name: "--promptKey",
    pattern: /--promptKey/u,
  },
  {
    name: "--url",
    pattern: /--url\b/u,
  },
] as const;

const staleSecretArtifactFragments = [
  {
    name: "`.age` secret artifact suffix",
    pattern: /`\.age`/u,
  },
  {
    name: ".age secret artifact example",
    pattern: /\b(?:config|credentials|work-key)\.age\b/u,
  },
] as const;

describe("documentation CLI drift", () => {
  it("does not document removed init credential flags", async () => {
    const files = [
      join(workspaceRoot, "README.md"),
      ...(await collectContentFiles(docsRoot)),
    ];
    const violations: string[] = [];

    for (const file of files) {
      const text = await readFile(file, "utf8");
      const lines = text.split(/\r?\n/u);

      for (const [index, line] of lines.entries()) {
        for (const flag of unsupportedInitFlags) {
          if (flag.pattern.test(line)) {
            violations.push(
              `${relative(workspaceRoot, file)}:${index + 1} uses ${flag.name}`,
            );
          }
        }
      }
    }

    expect(violations).toEqual([]);
  });

  it("does not document the legacy .age secret artifact suffix", async () => {
    const files = await collectContentFiles(docsRoot);
    const violations: string[] = [];

    for (const file of files) {
      const text = await readFile(file, "utf8");
      const lines = text.split(/\r?\n/u);

      for (const [index, line] of lines.entries()) {
        for (const fragment of staleSecretArtifactFragments) {
          if (fragment.pattern.test(line)) {
            violations.push(
              `${relative(workspaceRoot, file)}:${index + 1} uses ${fragment.name}`,
            );
          }
        }
      }
    }

    expect(violations).toEqual([]);
  });
});
