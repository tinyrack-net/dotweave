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

  it("ships built-in locale messages for every configured locale", () => {
    const manifest = loadDocsManifest(config, { root });

    expect(manifest.locales["en"]?.messages.navigation).toBe("Documentation");
    expect(manifest.locales["en"]?.messages.search).toBe(
      "Search documentation",
    );
    expect(manifest.locales["ko"]?.messages.navigation).toBe("문서");
    expect(manifest.locales["ko"]?.messages.search).toBe("문서 검색");
    expect(manifest.locales["ko"]?.messages.useLightColorScheme).toBe(
      "밝은 색상 모드로 전환",
    );
    expect(manifest.locales["ja"]?.messages.navigation).toBe("ドキュメント");
    expect(manifest.locales["ja"]?.messages.search).toBe("ドキュメントを検索");
    expect(manifest.locales["ja"]?.messages.useLightColorScheme).toBe(
      "ライトカラースキームに切り替え",
    );

    for (const locale of ["en", "ko", "ja"] as const) {
      expect(manifest.locales[locale]?.messages.backToMainMenu).toBeTypeOf(
        "string",
      );
      expect(manifest.locales[locale]?.messages.siteNavigation).toBeTypeOf(
        "string",
      );
      expect(manifest.locales[locale]?.messages.useDarkColorScheme).toBeTypeOf(
        "string",
      );
    }
  });

  it("emits locale-aware section labels from the section configuration", () => {
    const manifest = loadDocsManifest(config, { root });

    const localized = (locale: string, id: string) =>
      manifest.pages.find(
        (page) => page.locale === locale && page.section === id,
      )?.sectionLabel;

    expect(localized("en", "overview")).toBe("Overview");
    expect(localized("ko", "overview")).toBe("시작하기");
    expect(localized("ja", "overview")).toBe("はじめに");
    expect(localized("en", "guides")).toBe("Guides");
    expect(localized("ko", "guides")).toBe("가이드");
    expect(localized("ja", "guides")).toBe("ガイド");
    expect(localized("en", "reference")).toBe("Command Reference");
    expect(localized("ko", "reference")).toBe("명령어 레퍼런스");
    expect(localized("ja", "reference")).toBe("コマンドリファレンス");
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
