import { readdir, readFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

import { loadDocsManifest } from "@tinyrack/docs/config";
import { describe, expect, it } from "vitest";

import config from "../docs.config.ts";

const root = resolve(import.meta.dirname, "..");
const contentRoot = join(root, "app", "content");

async function contentFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  return (
    await Promise.all(
      entries.map((entry) => {
        const path = join(directory, entry.name);
        return entry.isDirectory()
          ? contentFiles(path)
          : Promise.resolve(entry.name.endsWith(".mdx") ? [path] : []);
      }),
    )
  ).flat();
}

describe("Dotweave documentation contract", () => {
  it("builds 66 localized routes with stable locale alternates", () => {
    const manifest = loadDocsManifest(config, { root });

    expect(manifest.pages).toHaveLength(66);
    expect(manifest.redirects).toEqual({ "/": "/en/" });
    expect(manifest.header?.version).toBe("0.52.0");

    for (const locale of ["en", "ko", "ja"]) {
      const pages = manifest.pages.filter((page) => page.locale === locale);
      expect(pages).toHaveLength(22);
      expect(pages.find((page) => page.path === `/${locale}`)?.layout).toBe(
        "splash",
      );
      expect(pages.every((page) => page.alternates.length === 3)).toBe(true);
    }
  });

  it("uses only public Tinyrack MDX components", async () => {
    const files = await contentFiles(contentRoot);
    const violations: string[] = [];

    for (const file of files) {
      const source = await readFile(file, "utf8");
      if (
        /\b@astrojs\/|<(?:Aside|TabItem|Steps|FileTree|Tabs)>/u.test(source)
      ) {
        violations.push(relative(root, file));
      }
    }

    expect(violations).toEqual([]);
  });

  it("keeps every localized internal content link valid", async () => {
    const manifest = loadDocsManifest(config, { root });
    const routes = new Set(manifest.pages.map((page) => page.path));
    const files = await contentFiles(contentRoot);
    const violations: string[] = [];

    for (const file of files) {
      const source = await readFile(file, "utf8");
      for (const match of source.matchAll(
        /\]\((\/[^)#?]*)(?:[?#][^)]*)?\)/gu,
      )) {
        const link = match[1];
        if (link === undefined) continue;
        const normalized = link.replace(/\/+$/u, "") || "/";
        if (!routes.has(normalized)) {
          violations.push(`${relative(root, file)} -> ${link}`);
        }
      }
    }

    expect(violations).toEqual([]);
  });
});
