import { readFile, stat } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { extname, join, normalize } from "node:path";

import { type Browser, chromium } from "playwright";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

// The CLI version comes from packages/cli/pubspec.yaml so the rendered
// "Dotweave v<version>" badge assertion tracks releases automatically.
import { cliVersion } from "../cli-version.ts";

const buildRoot = join(import.meta.dirname, "..", "build", "client");

let browser: Browser;
let origin: string;
let server: Server;
let simulateCloudflareBeacon = false;

const contentTypes: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

beforeAll(async () => {
  server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", "http://localhost");
      if (url.pathname === "/cdn-cgi/rum") {
        response.writeHead(204).end();
        return;
      }
      const requestPath = decodeURIComponent(url.pathname);
      const relativePath = requestPath.endsWith("/")
        ? `${requestPath.slice(1)}index.html`
        : requestPath.slice(1);
      const path = normalize(join(buildRoot, relativePath));
      if (!path.startsWith(normalize(buildRoot)))
        throw new Error("Invalid path");
      const file = (await stat(path)).isDirectory()
        ? join(path, "index.html")
        : path;
      let body = await readFile(file);
      if (extname(file) === ".html" && simulateCloudflareBeacon) {
        body = Buffer.from(
          body.toString("utf8").replace(
            "</body>",
            `<script defer src="https://static.cloudflareinsights.com/beacon.min.js/v4513226cdae34746b4dedf0b4dfa099e1781791509496" data-cf-beacon='{"version":"2024.11.0","token":"test-token","r":1}' crossorigin="anonymous"></script>
</body>`,
          ),
        );
      }
      response.writeHead(200, {
        "content-type":
          contentTypes[extname(file)] ?? "application/octet-stream",
      });
      response.end(body);
    } catch {
      response.writeHead(404).end("Not found");
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string")
    throw new Error("No server port");
  origin = `http://127.0.0.1:${address.port}`;
  browser = await chromium.launch();
});

afterAll(async () => {
  await browser?.close();
  await new Promise<void>((resolve, reject) =>
    server?.close((error) => (error ? reject(error) : resolve())),
  );
});

describe("Dotweave built documentation", () => {
  it("protects hydration from Cloudflare analytics injection", async () => {
    const page = await browser.newPage();
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("pageerror", (error) => errors.push(error.message));

    simulateCloudflareBeacon = true;
    try {
      const response = await page.goto(
        `${origin}/en/concepts/repository-layout/`,
      );
      expect(await response?.text()).toContain("data-cf-beacon");
      await page.locator('html[data-hydrated="true"]').waitFor();

      await expect(
        page.locator("script[data-cf-beacon]").count(),
      ).resolves.toBe(1);
      expect(errors).toEqual([]);
    } finally {
      simulateCloudflareBeacon = false;
      await page.close();
    }
  });

  it("renders the English landing and guide in desktop light mode", async () => {
    const page = await browser.newPage({ colorScheme: "light" });
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    await page.addInitScript(() =>
      localStorage.setItem("tinyrack-theme", "tinyrack-light"),
    );

    await page.goto(`${origin}/en/`);
    await page.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      page.getByRole("heading", { name: "Your config, anywhere." }).isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByText(`Dotweave v${cliVersion}`).first().isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByText("Cross-OS profiles").first().isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByRole("tab", { name: "Windows" }).isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.getByText("winget install tinyrack.dotweave").first().isVisible(),
    ).resolves.toBe(true);
    expect(await page.locator("html").getAttribute("data-theme")).toBe(
      "tinyrack-light",
    );

    await page.goto(`${origin}/en/concepts/repository-layout/`);
    await page.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      page
        .getByRole("heading", { name: "Directory and repository layout" })
        .isVisible(),
    ).resolves.toBe(true);
    await expect(
      page
        .locator(
          'ul.tr-file-tree[aria-label="Dotweave configuration directory layout"]',
        )
        .getByText("repository/")
        .first()
        .isVisible(),
    ).resolves.toBe(true);
    await expect(
      page.locator('meta[property="og:site_name"]').count(),
    ).resolves.toBe(1);
    await expect(
      page.locator('meta[name="twitter:card"]').getAttribute("content"),
    ).resolves.toBe("summary_large_image");
    expect(errors).toEqual([]);
    await page.close();
  });

  // Playwright's isVisible() ignores opacity, so only a computed-style check
  // catches a staggered step that never finishes revealing.
  it("shows the full terminal transcript when motion is reduced", async () => {
    const page = await browser.newPage({ reducedMotion: "reduce" });
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("pageerror", (error) => errors.push(error.message));

    await page.goto(`${origin}/en/`);
    await page.locator('html[data-hydrated="true"]').waitFor();

    const steps = page.locator(".dotweave-terminal-step");
    const stepCount = await steps.count();
    expect(stepCount).toBe(3);
    for (let index = 0; index < stepCount; index += 1) {
      await expect(
        steps.nth(index).evaluate((node) => getComputedStyle(node).opacity),
      ).resolves.toBe("1");
    }
    expect(errors).toEqual([]);
    await page.close();
  });

  it("keeps the desktop globe larger than the terminal backdrop", async () => {
    const page = await browser.newPage({
      reducedMotion: "reduce",
      viewport: { height: 900, width: 1440 },
    });

    await page.goto(`${origin}/en/`);
    await page.locator('html[data-hydrated="true"]').waitFor();

    const geometry = await page.evaluate(() => {
      const globe = document.querySelector<HTMLElement>(".dotweave-globe");
      const terminal =
        document.querySelector<HTMLElement>(".dotweave-terminal");
      const canvas = document.querySelector<HTMLCanvasElement>(
        ".dotweave-globe canvas",
      );
      if (globe === null || terminal === null || canvas === null)
        throw new Error("Hero globe geometry is missing");
      return {
        globeWidth: globe.getBoundingClientRect().width,
        terminalWidth: terminal.getBoundingClientRect().width,
        canvasWidth: canvas.getBoundingClientRect().width,
      };
    });

    expect(geometry.globeWidth).toBeGreaterThan(geometry.terminalWidth * 1.4);
    expect(geometry.canvasWidth).toBe(geometry.globeWidth);
    await page.close();
  });

  it("renders localized interactive docs in mobile dark mode", async () => {
    const page = await browser.newPage({
      colorScheme: "dark",
      reducedMotion: "reduce",
      viewport: { height: 844, width: 390 },
    });
    await page.addInitScript(() =>
      localStorage.setItem("tinyrack-theme", "tinyrack-dark"),
    );
    await page.goto(`${origin}/ko/getting-started/`);
    await page.locator('html[data-hydrated="true"]').waitFor();

    await expect(
      page
        .getByRole("heading", { exact: true, name: "첫 동기화 설정" })
        .isVisible(),
    ).resolves.toBe(true);

    // The install tabs live on their own page since the overview split.
    await page.goto(`${origin}/ko/install/`);
    await page.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      page.getByRole("tab", { name: "Windows" }).isVisible(),
    ).resolves.toBe(true);
    expect(await page.locator("html").getAttribute("data-theme")).toBe(
      "tinyrack-dark",
    );
    await page.close();
  });

  it("renders an accessible file tree with nested files for the repository layout page", async () => {
    const page = await browser.newPage();
    await page.goto(`${origin}/en/concepts/repository-layout/`);
    await page.locator('html[data-hydrated="true"]').waitFor();

    const tree = page.locator(
      'ul.tr-file-tree[aria-label="Dotweave configuration directory layout"]',
    );
    await expect(tree.isVisible()).resolves.toBe(true);
    await expect(
      tree.getByText("<dotweave-home>/").first().isVisible(),
    ).resolves.toBe(true);
    await expect(
      tree.getByText("manifest.jsonc").first().isVisible(),
    ).resolves.toBe(true);
    await expect(
      tree.getByText("settings.jsonc").first().isVisible(),
    ).resolves.toBe(true);
    await expect(tree.getByText("keys.txt").first().isVisible()).resolves.toBe(
      true,
    );
    await expect(
      tree.getByText("config.dotweave.secret").first().isVisible(),
    ).resolves.toBe(true);
    await page.close();
  });

  it("exposes the localized accessibility name in Korean and Japanese", async () => {
    const korean = await browser.newPage();
    await korean.goto(`${origin}/ko/concepts/repository-layout/`);
    await korean.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      korean
        .locator('ul.tr-file-tree[aria-label="dotweave 설정 디렉터리 구조"]')
        .isVisible(),
    ).resolves.toBe(true);
    await expect(
      korean
        .locator('ul.tr-file-tree[aria-label="dotweave 설정 디렉터리 구조"]')
        .getByText("manifest.jsonc")
        .first()
        .isVisible(),
    ).resolves.toBe(true);
    await korean.close();

    const japanese = await browser.newPage();
    await japanese.goto(`${origin}/ja/concepts/repository-layout/`);
    await japanese.locator('html[data-hydrated="true"]').waitFor();
    await expect(
      japanese
        .locator('ul.tr-file-tree[aria-label="dotweaveの設定ディレクトリ構造"]')
        .isVisible(),
    ).resolves.toBe(true);
    await expect(
      japanese
        .locator('ul.tr-file-tree[aria-label="dotweaveの設定ディレクトリ構造"]')
        .getByText("manifest.jsonc")
        .first()
        .isVisible(),
    ).resolves.toBe(true);
    await japanese.close();
  });

  it("keeps the root redirect", async () => {
    const page = await browser.newPage();
    await page.goto(`${origin}/`);
    await page.waitForURL(`${origin}/en/`);
    await page.close();
  });
});
