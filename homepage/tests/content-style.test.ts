import { readdir, readFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");
const contentRoot = join(root, "app", "content");
const locales = ["en", "ko", "ja"] as const;

type Locale = (typeof locales)[number];

async function pageKeys(locale: Locale): Promise<string[]> {
  const localeRoot = join(contentRoot, locale);

  async function walk(directory: string): Promise<string[]> {
    const entries = await readdir(directory, { withFileTypes: true });
    return (
      await Promise.all(
        entries.map((entry) => {
          const path = join(directory, entry.name);
          if (entry.isDirectory()) return walk(path);
          if (!entry.name.endsWith(".mdx")) return Promise.resolve([]);
          return Promise.resolve([
            relative(localeRoot, path).replaceAll("\\", "/").slice(0, -4),
          ]);
        }),
      )
    ).flat();
  }

  return (await walk(localeRoot)).sort();
}

function read(locale: Locale, key: string): Promise<string> {
  return readFile(join(contentRoot, locale, `${key}.mdx`), "utf8");
}

/**
 * Prose only: frontmatter and fenced code are reproduced verbatim, not authored.
 * Blanked in place so reported line numbers still match the file.
 */
function prose(source: string): string {
  const blank = (match: string) => "\n".repeat(match.split("\n").length - 1);
  return source
    .replace(/^---\n[\s\S]*?\n---\n/u, blank)
    .replace(/^ {0,3}(```|~~~)[^\n]*\n[\s\S]*?^ {0,3}\1[^\n]*$/gmu, blank);
}

function frontmatter(source: string): Record<string, string> {
  const block = /^---\n([\s\S]*?)\n---/u.exec(source)?.[1];
  if (block === undefined) return {};
  const fields: Record<string, string> = {};
  for (const line of block.split("\n")) {
    const field = /^([A-Za-z][A-Za-z0-9_]*):\s*(.*)$/u.exec(line);
    if (field?.[1] === undefined) continue;
    fields[field[1]] = (field[2] ?? "").trim().replace(/^"(.*)"$/u, "$1");
  }
  return fields;
}

function headings(source: string): string[] {
  return Array.from(prose(source).matchAll(/^## +(.+?)\s*$/gmu), (match) =>
    (match[1] ?? "").trim(),
  );
}

/** `## 3. Push the files` -> `3`; an unnumbered heading -> `null`. */
function headingShape(source: string): (string | null)[] {
  return headings(source).map(
    (heading) => /^(\d+)\.\s/u.exec(heading)?.[1] ?? null,
  );
}

describe("Dotweave documentation style", () => {
  it("ships every page in all three locales", async () => {
    const [en, ko, ja] = await Promise.all(locales.map(pageKeys));

    expect(ko).toEqual(en);
    expect(ja).toEqual(en);
  });

  it("keeps frontmatter complete on every page", async () => {
    const violations: string[] = [];

    for (const locale of locales) {
      for (const key of await pageKeys(locale)) {
        const fields = frontmatter(await read(locale, key));
        const page = `${locale}/${key}`;

        for (const field of ["title", "description", "section"]) {
          if (!fields[field]) violations.push(`${page}: missing ${field}`);
        }
        if (!/^\d+$/u.test(fields["order"] ?? "")) {
          violations.push(`${page}: order must be a non-negative integer`);
        }

        const isSplash = key === "index";
        if (isSplash !== (fields["layout"] === "splash")) {
          violations.push(`${page}: only index may set layout: splash`);
        }
        if (isSplash !== (fields["navigation"] === "false")) {
          violations.push(`${page}: only index may set navigation: false`);
        }
      }
    }

    expect(violations).toEqual([]);
  });

  it("uses a flat heading structure with no H1 or H3", async () => {
    const violations: string[] = [];

    for (const locale of locales) {
      for (const key of await pageKeys(locale)) {
        const body = prose(await read(locale, key));
        const page = `${locale}/${key}`;

        if (/^# /mu.test(body)) {
          violations.push(
            `${page}: the title comes from frontmatter, not an H1`,
          );
        }
        if (/^#{3,} /mu.test(body)) {
          violations.push(`${page}: use H2 only`);
        }
        if (key !== "index" && headings(body).length === 0) {
          violations.push(`${page}: needs at least one H2`);
        }
      }
    }

    expect(violations).toEqual([]);
  });

  it("aligns heading structure across locales", async () => {
    const violations: string[] = [];

    for (const key of await pageKeys("en")) {
      const english = await read("en", key);
      const expected = headingShape(english);

      for (const locale of ["ko", "ja"] as const) {
        const actual = headingShape(await read(locale, key));
        if (actual.length !== expected.length) {
          violations.push(
            `${locale}/${key}: ${actual.length} headings, en has ${expected.length}`,
          );
          continue;
        }
        if (actual.join(",") !== expected.join(",")) {
          violations.push(
            `${locale}/${key}: step numbering [${actual.join(",")}] does not match en [${expected.join(",")}]`,
          );
        }
      }
    }

    expect(violations).toEqual([]);
  });

  it("writes Korean prose in haeyoche", async () => {
    const prohibited = /니다|십시오|(?:했|됐|됨|함)(?=[.!?。<\n"'])/gu;
    const violations: string[] = [];

    for (const key of await pageKeys("ko")) {
      const body = prose(await read("ko", key));
      for (const match of body.matchAll(prohibited)) {
        violations.push(
          `ko/${key}:${body.slice(0, match.index).split("\n").length} "${match[0]}"`,
        );
      }
    }

    expect(violations).toEqual([]);
  });

  it("writes Japanese prose in desu-masu", async () => {
    // Sentence-final plain form only. `〜であること` is valid inside desu-masu prose.
    const prohibited = /である[。、]|だ[。、]|しろ。|すべし。/gu;
    const violations: string[] = [];

    for (const key of await pageKeys("ja")) {
      const body = prose(await read("ja", key));
      for (const match of body.matchAll(prohibited)) {
        violations.push(
          `ja/${key}:${body.slice(0, match.index).split("\n").length} "${match[0]}"`,
        );
      }
    }

    expect(violations).toEqual([]);
  });
});
